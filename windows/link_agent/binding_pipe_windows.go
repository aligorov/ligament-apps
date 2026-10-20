//go:build windows

package linkagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	bindingPipeSDDL       = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)"
	bindingPipeBufferSize = 4096
	bindingPipeWait       = 50 * time.Millisecond
	bindingPipeIOTimeout  = 30 * time.Second
)

// EnrollAndStoreIdentity enrolls this host with an app-issued one-time token
// and persists the accepted identity before returning success to the caller.
func EnrollAndStoreIdentity(ctx context.Context, config AgentWSConfig, token string) (string, error) {
	if err := ValidateAgentWSMetadata(config); err != nil {
		return "", err
	}
	if _, err := LoadIdentity(); err == nil {
		return "", errors.New("link agent: this host is already enrolled")
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", fmt.Errorf("link agent: check existing identity: %w", err)
	}
	identity, err := EnrollAgent(ctx, config.ServerURL, token, EnrollmentMetadata{
		Hostname: config.Hostname, OSFamily: config.OSFamily, OSVersion: config.OSVersion,
		AgentVersion: config.AgentVersion, Capabilities: config.Capabilities,
	}, nil)
	if err != nil {
		return "", err
	}
	defer clearIdentity(identity)
	if err := SaveIdentity(identity); err != nil {
		return "", fmt.Errorf("link agent: persist enrolled identity: %w", err)
	}
	return identity.Fingerprint, nil
}

// ServeOneBindingPipe accepts local interactive-session requests until one
// enrollment succeeds. The pipe ACL excludes anonymous clients; session zero
// and remote clients are rejected independently of the ACL.
func ServeOneBindingPipe(ctx context.Context, bind func(context.Context, BindingRequest) (string, error), reportError func(error)) error {
	if bind == nil {
		return errors.New("link agent: nil binding handler")
	}
	name, err := windows.UTF16PtrFromString(BindingPipeName)
	if err != nil {
		return fmt.Errorf("link agent: encode binding pipe name: %w", err)
	}
	sd, err := windows.SecurityDescriptorFromString(bindingPipeSDDL)
	if err != nil {
		return fmt.Errorf("link agent: build binding pipe security descriptor: %w", err)
	}
	absoluteSD, err := sd.ToAbsolute()
	if err != nil {
		return fmt.Errorf("link agent: convert binding pipe security descriptor: %w", err)
	}
	security := windows.SecurityAttributes{
		Length:             uint32(unsafe.Sizeof(windows.SecurityAttributes{})),
		SecurityDescriptor: absoluteSD,
	}

	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		pipe, err := windows.CreateNamedPipe(
			name,
			windows.PIPE_ACCESS_DUPLEX,
			windows.PIPE_TYPE_MESSAGE|windows.PIPE_READMODE_MESSAGE|windows.PIPE_NOWAIT|windows.PIPE_REJECT_REMOTE_CLIENTS,
			1, bindingPipeBufferSize, bindingPipeBufferSize, 0, &security,
		)
		if err != nil {
			return fmt.Errorf("link agent: create binding pipe: %w", err)
		}
		request, clientSession, err := receiveBindingRequest(ctx, pipe)
		if err == nil && clientSession == 0 {
			err = errors.New("link agent: binding request must come from an interactive Windows session")
		}
		if err == nil {
			fingerprint, bindErr := bind(ctx, request)
			err = bindErr
			if err == nil {
				_ = writeBindingResponse(pipe, BindingResponse{OK: true, Fingerprint: fingerprint})
				_ = windows.DisconnectNamedPipe(pipe)
				_ = windows.CloseHandle(pipe)
				return nil
			}
		}
		if err != nil {
			if reportError != nil && !errors.Is(err, context.Canceled) {
				reportError(err)
			}
			_ = writeBindingResponse(pipe, BindingResponse{OK: false, Error: "binding_failed"})
		}
		_ = windows.DisconnectNamedPipe(pipe)
		_ = windows.CloseHandle(pipe)
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
}

func receiveBindingRequest(ctx context.Context, pipe windows.Handle) (BindingRequest, uint32, error) {
	deadline := time.Now().Add(bindingPipeIOTimeout)
	connected := false
	for time.Now().Before(deadline) {
		if err := ctx.Err(); err != nil {
			return BindingRequest{}, 0, err
		}
		if !connected {
			err := windows.ConnectNamedPipe(pipe, nil)
			switch {
			case err == nil, errors.Is(err, windows.ERROR_PIPE_CONNECTED):
				connected = true
			case errors.Is(err, windows.ERROR_PIPE_LISTENING):
				time.Sleep(bindingPipeWait)
				continue
			default:
				return BindingRequest{}, 0, fmt.Errorf("link agent: accept binding pipe client: %w", err)
			}
		}
		var processID uint32
		if err := windows.GetNamedPipeClientProcessId(pipe, &processID); err != nil {
			return BindingRequest{}, 0, fmt.Errorf("link agent: identify binding pipe client: %w", err)
		}
		var sessionID uint32
		if err := windows.ProcessIdToSessionId(processID, &sessionID); err != nil {
			return BindingRequest{}, 0, fmt.Errorf("link agent: identify binding pipe session: %w", err)
		}
		buffer := make([]byte, bindingPipeBufferSize)
		var read uint32
		err := windows.ReadFile(pipe, buffer, &read, nil)
		if err == nil {
			request, decodeErr := DecodeBindingRequest(buffer[:read])
			clear(buffer)
			return request, sessionID, decodeErr
		}
		clear(buffer)
		if errors.Is(err, windows.ERROR_NO_DATA) || errors.Is(err, windows.ERROR_PIPE_LISTENING) {
			time.Sleep(bindingPipeWait)
			continue
		}
		if errors.Is(err, windows.ERROR_MORE_DATA) {
			return BindingRequest{}, 0, errors.New("link agent: binding request exceeds pipe message limit")
		}
		return BindingRequest{}, 0, fmt.Errorf("link agent: read binding pipe request: %w", err)
	}
	return BindingRequest{}, 0, errors.New("link agent: binding pipe request timed out")
}

func writeBindingResponse(pipe windows.Handle, response BindingResponse) error {
	encoded, err := json.Marshal(response)
	if err != nil {
		return err
	}
	defer clear(encoded)
	var written uint32
	if err := windows.WriteFile(pipe, encoded, &written, nil); err != nil {
		return fmt.Errorf("link agent: write binding pipe response: %w", err)
	}
	if written != uint32(len(encoded)) {
		return errors.New("link agent: incomplete binding pipe response")
	}
	return nil
}
