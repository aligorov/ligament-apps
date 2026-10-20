package linkagent

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestDecodeBindingRequest(t *testing.T) {
	token := strings.Repeat("a1", 32)
	request, err := DecodeBindingRequest([]byte(`{"version":1,"server_url":"https://core.example.test","enrollment_token":"` + token + `"}`))
	if err != nil || request.Version != 1 || request.ServerURL != "https://core.example.test" || request.EnrollmentToken != token {
		t.Fatalf("DecodeBindingRequest() = %+v, %v", request, err)
	}
}

func TestBindingSuccessResponseWireOrder(t *testing.T) {
	fingerprint := strings.Repeat("cd", 32)
	encoded, err := json.Marshal(BindingResponse{OK: true, Fingerprint: fingerprint})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"ok":true,"fingerprint":"` + fingerprint + `"}`
	if string(encoded) != want {
		t.Fatalf("response=%s, want %s", encoded, want)
	}
}

func TestDecodeBindingRequestRejectsMalformedInput(t *testing.T) {
	tests := []string{
		`{"version":2,"enrollment_token":"` + strings.Repeat("a1", 32) + `"}`,
		`{"version":1,"enrollment_token":"` + strings.Repeat("a1", 32) + `"}`,
		`{"version":1,"server_url":"http://core.example.test","enrollment_token":"` + strings.Repeat("a1", 32) + `"}`,
		`{"version":1,"server_url":"https://user@core.example.test","enrollment_token":"` + strings.Repeat("a1", 32) + `"}`,
		`{"version":1,"server_url":"https://core.example.test?redirect=1","enrollment_token":"` + strings.Repeat("a1", 32) + `"}`,
		`{"version":1,"enrollment_token":"short"}`,
		`{"version":1,"enrollment_token":"` + strings.Repeat("gg", 32) + `"}`,
		`{"version":1,"enrollment_token":"` + strings.Repeat("a1", 32) + `","extra":true}`,
		`{"version":1,"enrollment_token":"` + strings.Repeat("a1", 32) + `"} {}`,
	}
	for _, input := range tests {
		if _, err := DecodeBindingRequest([]byte(input)); err == nil {
			t.Errorf("DecodeBindingRequest(%q) unexpectedly succeeded", input)
		}
	}
	if _, err := DecodeBindingRequest(make([]byte, bindingMessageLimit+1)); err == nil {
		t.Fatal("oversized binding request unexpectedly succeeded")
	}
}
