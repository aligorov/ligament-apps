//go:build darwin || linux

package linkagent

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

const (
	unixBindingFrameLimit = bindingMessageLimit
	unixBindingPollPeriod = 50 * time.Millisecond
	unixBindingIOTimeout  = 30 * time.Second
)

// DefaultUnixBindingSocketPath uses a private per-UID directory under /tmp so
// the Flutter app can derive the rendezvous without service configuration or
// environment variables. The socket itself is mode 0600.
func DefaultUnixBindingSocketPath() (string, error) {
	return filepath.Join(fmt.Sprintf("/tmp/ligament-agent-%d", os.Getuid()), "bind.sock"), nil
}

// ServeOneBindingUnix accepts same-user enrollment requests until one succeeds.
// It rejects pre-existing untrusted paths and leaves no socket after shutdown.
func ServeOneBindingUnix(ctx context.Context, bind func(context.Context, BindingRequest) (string, error), reportError func(error)) error {
	if bind == nil {
		return errors.New("link agent: nil Unix binding handler")
	}
	path, err := DefaultUnixBindingSocketPath()
	if err != nil {
		return err
	}
	return serveOneBindingUnix(ctx, path, bind, reportError)
}

func serveOneBindingUnix(ctx context.Context, path string, bind func(context.Context, BindingRequest) (string, error), reportError func(error)) error {
	if bind == nil {
		return errors.New("link agent: nil Unix binding handler")
	}
	directory := filepath.Dir(path)
	if err := ensureUnixBindingDirectory(directory); err != nil {
		return err
	}
	if err := removeStaleUnixBindingSocket(path); err != nil {
		return err
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return fmt.Errorf("link agent: listen on Unix binding socket: %w", err)
	}
	defer func() {
		_ = listener.Close()
		_ = os.Remove(path)
	}()
	if err := os.Chmod(path, 0600); err != nil {
		return fmt.Errorf("link agent: protect Unix binding socket: %w", err)
	}
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		_ = listener.SetDeadline(time.Now().Add(unixBindingPollPeriod))
		conn, err := listener.AcceptUnix()
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return fmt.Errorf("link agent: accept Unix binding client: %w", err)
		}
		request, requestErr := receiveUnixBindingRequest(ctx, conn)
		if requestErr == nil {
			fingerprint, bindErr := bind(ctx, request)
			if bindErr == nil {
				requestErr = writeUnixBindingResponse(conn, BindingResponse{OK: true, Fingerprint: fingerprint})
				_ = conn.Close()
				if requestErr != nil {
					return requestErr
				}
				return nil
			}
			requestErr = bindErr
		}
		if requestErr != nil && reportError != nil && !errors.Is(requestErr, context.Canceled) {
			reportError(requestErr)
		}
		_ = writeUnixBindingResponse(conn, BindingResponse{OK: false, Error: "binding_failed"})
		_ = conn.Close()
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
}

func ensureUnixBindingDirectory(path string) error {
	if err := os.Mkdir(path, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return fmt.Errorf("link agent: create private binding directory: %w", err)
	}
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("link agent: inspect private binding directory: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 ||
		info.Mode().Perm()&0700 != 0700 || info.Mode().Perm()&0077 != 0 {
		return errors.New("link agent: unsafe Unix binding directory")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return errors.New("link agent: Unix binding directory is not owned by current user")
	}
	return nil
}

func removeStaleUnixBindingSocket(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("link agent: inspect existing Unix binding socket: %w", err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || info.Mode()&os.ModeSocket == 0 || stat.Uid != uint32(os.Getuid()) {
		return errors.New("link agent: refusing to replace unsafe Unix binding path")
	}
	conn, dialErr := net.DialTimeout("unix", path, 100*time.Millisecond)
	if dialErr == nil {
		_ = conn.Close()
		return errors.New("link agent: Unix binding service is already listening")
	}
	if err := os.Remove(path); err != nil {
		return fmt.Errorf("link agent: remove stale Unix binding socket: %w", err)
	}
	return nil
}

func receiveUnixBindingRequest(ctx context.Context, conn *net.UnixConn) (BindingRequest, error) {
	stopClose := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-stopClose:
		}
	}()
	defer close(stopClose)
	if err := conn.SetReadDeadline(time.Now().Add(unixBindingIOTimeout)); err != nil {
		return BindingRequest{}, err
	}
	var header [4]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		return BindingRequest{}, fmt.Errorf("link agent: read Unix binding frame header: %w", err)
	}
	length := binary.BigEndian.Uint32(header[:])
	if length == 0 || length > unixBindingFrameLimit {
		return BindingRequest{}, errors.New("link agent: invalid Unix binding frame length")
	}
	frame := make([]byte, int(length))
	if _, err := io.ReadFull(conn, frame); err != nil {
		clear(frame)
		return BindingRequest{}, fmt.Errorf("link agent: read Unix binding request: %w", err)
	}
	defer clear(frame)
	if err := ctx.Err(); err != nil {
		return BindingRequest{}, err
	}
	return DecodeBindingRequest(frame)
}

func writeUnixBindingResponse(conn *net.UnixConn, response BindingResponse) error {
	frame, err := json.Marshal(response)
	if err != nil {
		return fmt.Errorf("link agent: encode Unix binding response: %w", err)
	}
	defer clear(frame)
	if len(frame) == 0 || len(frame) > unixBindingFrameLimit {
		return errors.New("link agent: Unix binding response exceeds size limit")
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(frame)))
	if err := writeUnixWorkerBytes(conn, header[:]); err != nil {
		return fmt.Errorf("link agent: write Unix binding response header: %w", err)
	}
	if err := writeUnixWorkerBytes(conn, frame); err != nil {
		return fmt.Errorf("link agent: write Unix binding response: %w", err)
	}
	return nil
}
