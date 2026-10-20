//go:build darwin || linux

package linkagent

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
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
