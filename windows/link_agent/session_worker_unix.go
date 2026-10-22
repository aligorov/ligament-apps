//go:build darwin || linux

package linkagent

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

const (
	unixWorkerFrameLimit = 512 * 1024
	unixWorkerStartLimit = 20 * time.Second
)

// UnixSessionWorkerLauncher runs the interactive Flutter worker as the same
// logged-in user as the agent. Install the agent next to the Flutter binary;
// the service must be a per-user systemd/launchd job, not a root daemon.
type UnixSessionWorkerLauncher struct{}

func NewNativeSessionWorkerLauncher() SessionWorkerLauncher {
	return NewUnixSessionWorkerLauncher()
}

func NewUnixSessionWorkerLauncher() *UnixSessionWorkerLauncher {
	return &UnixSessionWorkerLauncher{}
}

func (*UnixSessionWorkerLauncher) Launch(ctx context.Context, _ SessionOffer, offerFrame []byte) (SessionWorkerProcess, error) {
	if len(offerFrame) == 0 || len(offerFrame) > unixWorkerFrameLimit {
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerUnavailable,
			Err:    errors.New("link agent: invalid initial worker frame size"),
		}
	}
	base, err := os.MkdirTemp("/tmp", "ligament-link-")
	if err != nil {
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: create private worker directory: %w", err),
		}
	}
	if err := os.Chmod(base, 0700); err != nil {
		_ = os.RemoveAll(base)
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: protect worker directory: %w", err),
		}
	}
	socketPath := filepath.Join(base, "worker.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err != nil {
		_ = os.RemoveAll(base)
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: create worker socket: %w", err),
		}
	}
	if err := os.Chmod(socketPath, 0600); err != nil {
		_ = listener.Close()
		_ = os.RemoveAll(base)
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: protect worker socket: %w", err),
		}
	}
	executable, err := os.Executable()
	if err != nil {
		_ = listener.Close()
		_ = os.RemoveAll(base)
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: locate agent executable: %w", err),
		}
	}
	appPath := filepath.Join(filepath.Dir(executable), "ligament_authenticator")
	if info, err := os.Stat(appPath); err != nil || info.IsDir() || info.Mode()&0111 == 0 {
		_ = listener.Close()
		_ = os.RemoveAll(base)
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerNotInstalled,
			Err:    errors.New("link agent: interactive Flutter host is not installed beside the agent"),
		}
	}
	cmd := exec.Command(appPath, "--link-host=unix:"+socketPath)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Dir = filepath.Dir(appPath)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, os.Stdout, os.Stderr
	if err := cmd.Start(); err != nil {
		_ = listener.Close()
		_ = os.RemoveAll(base)
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: start interactive Flutter host: %w", err),
		}
	}
	process := &unixSessionWorkerProcess{
		cmd: cmd, base: base, done: make(chan error, 1), closed: make(chan struct{}),
	}
	go func() { process.done <- cmd.Wait() }()
	acceptCtx, cancelAccept := context.WithTimeout(ctx, unixWorkerStartLimit)
	conn, err := acceptUnixWorker(acceptCtx, listener, process.done)
	cancelAccept()
	_ = listener.Close()
	if err != nil {
		_ = process.Close()
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    err,
		}
	}
	process.conn = conn
	if err := process.Send(ctx, offerFrame); err != nil {
		_ = process.Close()
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: send offer to Unix worker: %w", err),
		}
	}
	go func() {
		select {
		case <-ctx.Done():
			_ = process.Close()
		case <-process.closed:
		}
	}()
	return process, nil
}

func acceptUnixWorker(ctx context.Context, listener *net.UnixListener, done <-chan error) (net.Conn, error) {
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		_ = listener.SetDeadline(time.Now().Add(100 * time.Millisecond))
		conn, err := listener.AcceptUnix()
		if err == nil {
			return conn, nil
		}
		if ne, ok := err.(net.Error); !ok || !ne.Timeout() {
			return nil, fmt.Errorf("link agent: accept Unix worker: %w", err)
		}
		select {
		case err := <-done:
			if err == nil {
				err = errors.New("worker exited before connecting")
			}
			return nil, fmt.Errorf("link agent: Flutter worker exited before socket connection: %w", err)
		default:
		}
	}
}

type unixSessionWorkerProcess struct {
	cmd    *exec.Cmd
	conn   net.Conn
	base   string
	done   chan error
	closed chan struct{}
	close  sync.Once
	sendMu sync.Mutex
}

func (p *unixSessionWorkerProcess) Send(ctx context.Context, frame []byte) error {
	if len(frame) == 0 || len(frame) > unixWorkerFrameLimit {
		return errors.New("link agent: worker IPC frame exceeds size limit")
	}
	p.sendMu.Lock()
	defer p.sendMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	conn := p.conn
	if conn == nil {
		return errors.New("link agent: Unix worker socket not connected")
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetWriteDeadline(deadline)
	} else {
		_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(frame)))
	if err := writeUnixWorkerBytes(conn, header[:]); err != nil {
		return fmt.Errorf("link agent: write worker frame header: %w", err)
	}
	if err := writeUnixWorkerBytes(conn, frame); err != nil {
		return fmt.Errorf("link agent: write worker frame: %w", err)
	}
	return nil
}

func writeUnixWorkerBytes(writer io.Writer, payload []byte) error {
	for len(payload) > 0 {
		written, err := writer.Write(payload)
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
		payload = payload[written:]
	}
	return nil
}

func (p *unixSessionWorkerProcess) Receive(ctx context.Context) ([]byte, error) {
	conn := p.conn
	if conn == nil {
		return nil, errors.New("link agent: Unix worker socket not connected")
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetReadDeadline(deadline)
	} else {
		_ = conn.SetReadDeadline(time.Time{})
	}
	var header [4]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		return nil, fmt.Errorf("link agent: read worker frame header: %w", err)
	}
	length := binary.BigEndian.Uint32(header[:])
	if length == 0 || length > unixWorkerFrameLimit {
		return nil, errors.New("link agent: worker IPC frame length is invalid")
	}
	frame := make([]byte, int(length))
	if _, err := io.ReadFull(conn, frame); err != nil {
		clear(frame)
		return nil, fmt.Errorf("link agent: read worker frame: %w", err)
	}
	return frame, nil
}

func (p *unixSessionWorkerProcess) Close() error {
	var closeErr error
	p.close.Do(func() {
		close(p.closed)
		if p.conn != nil {
			closeErr = p.conn.Close()
		}
		if p.cmd != nil && p.cmd.Process != nil {
			// Kill the whole worker process group so child helpers cannot
			// outlive a revoked/closed remote session.
			if err := syscall.Kill(-p.cmd.Process.Pid, syscall.SIGKILL); err != nil {
				_ = p.cmd.Process.Kill()
			}
		}
		if p.base != "" {
			_ = os.RemoveAll(p.base)
		}
	})
	return closeErr
}
