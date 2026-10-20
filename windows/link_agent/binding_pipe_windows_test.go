//go:build windows

package linkagent

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func TestServeOneBindingPipeInteractiveClient(t *testing.T) {
	var currentSession uint32
	if err := windows.ProcessIdToSessionId(uint32(windows.GetCurrentProcessId()), &currentSession); err != nil {
		t.Fatal(err)
	}
	if currentSession == 0 {
		t.Skip("named-pipe binding test requires an interactive Windows session")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	token := strings.Repeat("ab", 32)
	fingerprint := strings.Repeat("cd", 32)
	serverDone := make(chan error, 1)
	go func() {
		serverDone <- ServeOneBindingPipe(ctx, func(_ context.Context, got BindingRequest) (string, error) {
			if got.EnrollmentToken != token || got.ServerURL != "https://core.example.test" {
				return "", context.DeadlineExceeded
			}
			return fingerprint, nil
		}, nil)
	}()

	name, err := windows.UTF16PtrFromString(BindingPipeName)
	if err != nil {
		t.Fatal(err)
	}
	var pipe windows.Handle
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		pipe, err = windows.CreateFile(name, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil,
			windows.OPEN_EXISTING, windows.SECURITY_SQOS_PRESENT|windows.SECURITY_IDENTIFICATION, 0)
		if err == nil {
			break
		}
		if ctx.Err() != nil {
			t.Fatalf("open binding pipe: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("open binding pipe: %v", err)
	}
	defer windows.CloseHandle(pipe)
	request, err := json.Marshal(BindingRequest{Version: 1, ServerURL: "https://core.example.test", EnrollmentToken: token})
	if err != nil {
		t.Fatal(err)
	}
	var written uint32
	if err := windows.WriteFile(pipe, request, &written, nil); err != nil || int(written) != len(request) {
		t.Fatalf("write binding request: written=%d err=%v", written, err)
	}
	clear(request)
	responseBuffer := make([]byte, 512)
	var read uint32
	if err := windows.ReadFile(pipe, responseBuffer, &read, nil); err != nil {
		t.Fatalf("read binding response: %v", err)
	}
	var response BindingResponse
	if err := json.Unmarshal(responseBuffer[:read], &response); err != nil {
		t.Fatal(err)
	}
	if !response.OK || response.Fingerprint != fingerprint {
		t.Fatalf("binding response=%+v", response)
	}
	if err := <-serverDone; err != nil {
		t.Fatalf("binding server: %v", err)
	}
}
