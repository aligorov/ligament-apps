//go:build darwin || linux

package linkagent

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

func TestServeOneBindingUnixEnrollsOverPrivateSocket(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "link-bind-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	socketPath := directory + "/bind.sock"
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	serverDone := make(chan error, 1)
	serverCalled := make(chan BindingRequest, 1)
	fingerprint := strings.Repeat("a", 64)
	go func() {
		serverDone <- serveOneBindingUnix(ctx, socketPath, func(_ context.Context, request BindingRequest) (string, error) {
			serverCalled <- request
			return fingerprint, nil
		}, nil)
	}()

	var client *net.UnixConn
	for ctx.Err() == nil {
		client, err = net.DialUnix("unix", nil, &net.UnixAddr{Name: socketPath, Net: "unix"})
		if err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if client == nil {
		t.Fatalf("connect binding socket: %v", err)
	}
	defer client.Close()
	request := BindingRequest{
		Version: 1, ServerURL: "https://core.example.test",
		EnrollmentToken: strings.Repeat("b", 64),
	}
	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeUnixWorkerFrame(client, encoded); err != nil {
		t.Fatal(err)
	}
	frame, err := readUnixWorkerFrame(client)
	if err != nil {
		t.Fatal(err)
	}
	var response BindingResponse
	if err := json.Unmarshal(frame, &response); err != nil {
		t.Fatal(err)
	}
	if !response.OK || response.Fingerprint != fingerprint {
		t.Fatalf("unexpected binding response: %+v", response)
	}
	select {
	case got := <-serverCalled:
		if got != request {
			t.Fatalf("server received %+v, want %+v", got, request)
		}
	case <-ctx.Done():
		t.Fatal("server did not process the binding request")
	}
	if err := <-serverDone; err != nil {
		t.Fatalf("binding server returned error: %v", err)
	}
	if _, err := os.Lstat(socketPath); !os.IsNotExist(err) {
		t.Fatalf("binding socket was not removed: %v", err)
	}
}

func TestUnixBindingRejectsUnsafeSocketDirectory(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "link-bind-unsafe-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(directory)
	if err := os.Chmod(directory, 0755); err != nil {
		t.Fatal(err)
	}
	err = serveOneBindingUnix(context.Background(), fmt.Sprintf("%s/bind.sock", directory), func(context.Context, BindingRequest) (string, error) {
		return "", nil
	}, nil)
	if err == nil {
		t.Fatal("unsafe socket directory was accepted")
	}
}
