//go:build darwin || linux

package linkagent

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
	"testing"
	"time"
)

func TestUnixWorkerFramesRoundTrip(t *testing.T) {
	agent, worker := net.Pipe()
	defer agent.Close()
	defer worker.Close()
	process := &unixSessionWorkerProcess{conn: agent, closed: make(chan struct{})}

	outbound := []byte(`{"type":"session_answer","session_id":"session-1"}`)
	writeDone := make(chan error, 1)
	go func() { writeDone <- process.Send(context.Background(), outbound) }()
	readFrame := func(conn net.Conn) ([]byte, error) {
		var header [4]byte
		if _, err := io.ReadFull(conn, header[:]); err != nil {
			return nil, err
		}
		frame := make([]byte, binary.BigEndian.Uint32(header[:]))
		_, err := io.ReadFull(conn, frame)
		return frame, err
	}
	frame, err := readFrame(worker)
	if err != nil || string(frame) != string(outbound) {
		t.Fatalf("send frame=%q err=%v", frame, err)
	}
	if err := <-writeDone; err != nil {
		t.Fatalf("send returned error: %v", err)
	}

	inbound := []byte(`{"type":"signal","session_id":"session-1"}`)
	readDone := make(chan struct {
		frame []byte
		err   error
	}, 1)
	go func() {
		frame, err := process.Receive(context.Background())
		readDone <- struct {
			frame []byte
			err   error
		}{frame, err}
	}()
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(inbound)))
	if err := writeUnixWorkerBytes(worker, header[:]); err != nil {
		t.Fatal(err)
	}
	if err := writeUnixWorkerBytes(worker, inbound); err != nil {
		t.Fatal(err)
	}
	result := <-readDone
	if result.err != nil || string(result.frame) != string(inbound) {
		t.Fatalf("receive frame=%q err=%v", result.frame, result.err)
	}
}

func TestUnixWorkerSocketHandshake(t *testing.T) {
	base, err := os.MkdirTemp("/tmp", "link-socket-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(base)
	socketPath := base + "/worker.sock"
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	accepted := make(chan net.Conn, 1)
	acceptErr := make(chan error, 1)
	go func() {
		conn, err := acceptUnixWorker(ctx, listener, make(chan error))
		if err != nil {
			acceptErr <- err
			return
		}
		accepted <- conn
	}()
	client, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	var conn net.Conn
	select {
	case conn = <-accepted:
	case err := <-acceptErr:
		t.Fatal(err)
	case <-ctx.Done():
		t.Fatal("worker socket accept timed out")
	}
	defer conn.Close()

	offer := []byte(`{"type":"session_offer"}`)
	if err := writeUnixWorkerFrame(client, offer); err != nil {
		t.Fatal(err)
	}
	worker := &unixSessionWorkerProcess{conn: conn, closed: make(chan struct{})}
	frame, err := worker.Receive(ctx)
	if err != nil || string(frame) != string(offer) {
		t.Fatalf("offer frame=%q err=%v", frame, err)
	}
	answer := []byte(`{"type":"session_answer"}`)
	if err := worker.Send(ctx, answer); err != nil {
		t.Fatal(err)
	}
	frame, err = readUnixWorkerFrame(client)
	if err != nil || string(frame) != string(answer) {
		t.Fatalf("answer frame=%q err=%v", frame, err)
	}
}

func writeUnixWorkerFrame(writer io.Writer, payload []byte) error {
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(payload)))
	if err := writeUnixWorkerBytes(writer, header[:]); err != nil {
		return err
	}
	return writeUnixWorkerBytes(writer, payload)
}

func readUnixWorkerFrame(reader io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(header[:])
	if length == 0 || length > unixWorkerFrameLimit {
		return nil, errors.New("test frame length invalid")
	}
	payload := make([]byte, int(length))
	_, err := io.ReadFull(reader, payload)
	return payload, err
}

func TestUnixWorkerRejectsInvalidFrameLength(t *testing.T) {
	agent, worker := net.Pipe()
	defer agent.Close()
	defer worker.Close()
	process := &unixSessionWorkerProcess{conn: agent, closed: make(chan struct{})}
	go func() {
		var header [4]byte
		binary.BigEndian.PutUint32(header[:], uint32(unixWorkerFrameLimit+1))
		_ = writeUnixWorkerBytes(worker, header[:])
	}()
	_, err := process.Receive(context.Background())
	if err == nil {
		t.Fatal("expected oversized frame rejection")
	}
}

func TestUnixWorkerHonorsReadDeadline(t *testing.T) {
	agent, worker := net.Pipe()
	defer agent.Close()
	defer worker.Close()
	process := &unixSessionWorkerProcess{conn: agent, closed: make(chan struct{})}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, err := process.Receive(ctx); err == nil {
		t.Fatal("expected deadline error")
	}
}

func TestUnixWorkerCloseKillsChildAndRemovesPrivateDirectory(t *testing.T) {
	base, err := os.MkdirTemp("/tmp", "link-worker-test-")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("sleep", "30")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		_ = os.RemoveAll(base)
		t.Skipf("sleep helper unavailable: %v", err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	agent, child := net.Pipe()
	defer child.Close()
	process := &unixSessionWorkerProcess{
		cmd: cmd, conn: agent, base: base, done: done, closed: make(chan struct{}),
	}
	if err := process.Close(); err != nil {
		t.Fatalf("close worker: %v", err)
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("worker process did not exit after close")
	}
	if _, err := os.Stat(base); !os.IsNotExist(err) {
		t.Fatalf("private worker directory still exists: %v", err)
	}
}

func TestResolveUnixWorkerExecutable(t *testing.T) {
	dir := t.TempDir()
	agentPath := dir + "/link-agent"

	if runtime.GOOS == "darwin" {
		// 1. Prefer native helper if present
		nativeHelper := dir + "/link-worker-darwin"
		if err := os.WriteFile(nativeHelper, []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
			t.Fatal(err)
		}
		if got := resolveUnixWorkerExecutable(agentPath); got != nativeHelper {
			t.Fatalf("expected native helper %q, got %q", nativeHelper, got)
		}

		// 2. Fall back to bundle binary "Ligament 2FA"
		_ = os.Remove(nativeHelper)
		bundleBinary := dir + "/Ligament 2FA"
		if err := os.WriteFile(bundleBinary, []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
			t.Fatal(err)
		}
		if got := resolveUnixWorkerExecutable(agentPath); got != bundleBinary {
			t.Fatalf("expected bundle binary %q, got %q", bundleBinary, got)
		}

		// 3. Helpers directory candidate
		_ = os.Remove(bundleBinary)
		helpersDir := dir + "/../Helpers"
		_ = os.MkdirAll(helpersDir, 0755)
		helperInHelpers := filepath.Clean(helpersDir + "/link-worker-darwin")
		if err := os.WriteFile(helperInHelpers, []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
			t.Fatal(err)
		}
		defer os.RemoveAll(helpersDir)
		if got := resolveUnixWorkerExecutable(agentPath); got != helperInHelpers {
			t.Fatalf("expected helper in Helpers %q, got %q", helperInHelpers, got)
		}
	} else {
		expected := dir + "/ligament_authenticator"
		if got := resolveUnixWorkerExecutable(agentPath); got != expected {
			t.Fatalf("expected linux binary %q, got %q", expected, got)
		}
	}
}

func TestNativeDarwinWorkerSpawnAndHandshake(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("darwin only")
	}
	workerPath := filepath.Clean("../../macos/link_worker/.build/release/link-worker-darwin")
	if fi, err := os.Stat(workerPath); err != nil || fi.IsDir() {
		t.Skip("link-worker-darwin release binary not built, skipping integration test")
	}

	base, err := os.MkdirTemp("/tmp", "link-handshake-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(base)

	socketPath := filepath.Join(base, "worker.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	cmd := exec.Command(workerPath, "--link-host=unix:"+socketPath)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatalf("failed to start worker: %v", err)
	}
	defer func() {
		if cmd.Process != nil {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
	}()

	_ = listener.SetDeadline(time.Now().Add(5 * time.Second))
	conn, err := listener.AcceptUnix()
	if err != nil {
		t.Fatalf("failed to accept worker connection: %v", err)
	}
	defer conn.Close()

	offerJSON := []byte(`{
		"type":"session_offer",
		"session_id":"test-session-123",
		"payload":{
			"session_id":"test-session-123",
			"sdp":"v=0\r\no=- 123 456 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n",
			"access_mode":"control"
		}
	}`)
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(offerJSON)))
	if _, err := conn.Write(header[:]); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Write(offerJSON); err != nil {
		t.Fatal(err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	var respHeader [4]byte
	if _, err := io.ReadFull(conn, respHeader[:]); err != nil {
		t.Fatalf("read response header: %v", err)
	}
	respLen := binary.BigEndian.Uint32(respHeader[:])
	respBuf := make([]byte, respLen)
	if _, err := io.ReadFull(conn, respBuf); err != nil {
		t.Fatalf("read response frame: %v", err)
	}

	var answer struct {
		Type      string `json:"type"`
		SessionID string `json:"session_id"`
		Payload   struct {
			SessionID string `json:"session_id"`
			Accepted  bool   `json:"accepted"`
			SDP       string `json:"sdp"`
			Reason    string `json:"reason"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(respBuf, &answer); err != nil {
		t.Fatalf("unmarshal response JSON %q: %v", string(respBuf), err)
	}
	if answer.Type != "session_answer" {
		t.Fatalf("expected type session_answer, got %q", answer.Type)
	}
	if answer.SessionID != "test-session-123" || answer.Payload.SessionID != "test-session-123" {
		t.Fatalf("session_id mismatch: %q / %q", answer.SessionID, answer.Payload.SessionID)
	}
	t.Logf("Worker answered: accepted=%v sdp_len=%d reason=%q", answer.Payload.Accepted, len(answer.Payload.SDP), answer.Payload.Reason)
}


