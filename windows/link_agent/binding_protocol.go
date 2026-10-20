package linkagent

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strings"
)

const BindingPipeName = `\\.\pipe\ligament-agent-bind`

const bindingMessageLimit = 4096

type BindingRequest struct {
	Version         int    `json:"version"`
	ServerURL       string `json:"server_url"`
	EnrollmentToken string `json:"enrollment_token"`
}

type BindingResponse struct {
	OK          bool   `json:"ok"`
	Fingerprint string `json:"fingerprint,omitempty"`
	Error       string `json:"error,omitempty"`
}

// DecodeBindingRequest validates the bounded, versioned local IPC message.
func DecodeBindingRequest(data []byte) (BindingRequest, error) {
	if len(data) == 0 || len(data) > bindingMessageLimit {
		return BindingRequest{}, errors.New("link agent: invalid binding message size")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var request BindingRequest
	if err := decoder.Decode(&request); err != nil {
		return BindingRequest{}, errors.New("link agent: invalid binding request")
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return BindingRequest{}, errors.New("link agent: trailing binding request data")
	}
	if request.Version != 1 || !validBindingToken(request.EnrollmentToken) {
		return BindingRequest{}, errors.New("link agent: invalid binding request")
	}
	if _, err := enrollmentEndpoint(request.ServerURL); err != nil {
		return BindingRequest{}, errors.New("link agent: invalid binding server URL")
	}
	return request, nil
}

func validBindingToken(token string) bool {
	if len(token) != 64 || strings.TrimSpace(token) != token {
		return false
	}
	decoded, err := hex.DecodeString(token)
	clear(decoded)
	return err == nil && len(decoded) == 32
}
