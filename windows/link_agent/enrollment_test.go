package linkagent

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const enrollmentTestToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func TestEnrollAgentMatchesServerContractAndReturnsIdentity(t *testing.T) {
	var requestBody struct {
		EnrollmentToken string `json:"enrollment_token"`
		PublicKey       string `json:"public_key"`
		EnrollmentMetadata
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/link/agents/enroll" {
			t.Errorf("unexpected enrollment request: %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("missing JSON content type")
		}
		if err := json.NewDecoder(r.Body).Decode(&requestBody); err != nil {
			t.Errorf("decode request: %v", err)
		}
		publicKey, _ := hex.DecodeString(requestBody.PublicKey)
		fingerprint := sha256.Sum256(publicKey)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"agent_id":    "10000000-0000-4000-8000-000000000001",
			"fingerprint": hex.EncodeToString(fingerprint[:]), "status": "enrolled",
			"server_time": time.Now().Unix(),
		})
	}))
	defer server.Close()

	identity, err := EnrollAgent(context.Background(), server.URL, enrollmentTestToken, EnrollmentMetadata{
		Hostname: "WS-01", OSFamily: "windows", OSVersion: "11", AgentVersion: "0.1.0",
		Capabilities: map[string]any{"desktop_capture": true},
	}, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	if requestBody.EnrollmentToken != enrollmentTestToken || requestBody.Hostname != "WS-01" || requestBody.OSFamily != "windows" {
		t.Fatalf("unexpected enrollment payload: %+v", requestBody)
	}
	publicKey, err := hex.DecodeString(requestBody.PublicKey)
	if err != nil || len(publicKey) != ed25519.PublicKeySize || string(publicKey) != string(identity.PublicKey) {
		t.Fatalf("request public key does not match returned identity: %v", err)
	}
	if len(identity.PrivateKey) != ed25519.PrivateKeySize || identity.AgentID != "10000000-0000-4000-8000-000000000001" || identity.Fingerprint == "" {
		t.Fatalf("incomplete identity result: %+v", identity)
	}
}

func TestEnrollAgentNeverFollowsRedirect(t *testing.T) {
	redirectTargetCalled := false
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/capture") {
			redirectTargetCalled = true
			return
		}
		http.Redirect(w, r, "/capture", http.StatusTemporaryRedirect)
	}))
	defer server.Close()

	_, err := EnrollAgent(context.Background(), server.URL, enrollmentTestToken, EnrollmentMetadata{
		Hostname: "WS-01", OSFamily: "windows", AgentVersion: "0.1.0",
	}, server.Client())
	if err == nil || !strings.Contains(err.Error(), "307") {
		t.Fatalf("expected redirect to be rejected, got %v", err)
	}
	if redirectTargetCalled {
		t.Fatal("enrollment token request body was forwarded to redirect target")
	}
}

func TestEnrollAgentRejectsServerFingerprintMismatch(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"agent_id":"10000000-0000-4000-8000-000000000001","fingerprint":"00","status":"enrolled","server_time":1800000000}`))
	}))
	defer server.Close()
	_, err := EnrollAgent(context.Background(), server.URL, enrollmentTestToken, EnrollmentMetadata{
		Hostname: "WS-01", OSFamily: "windows", AgentVersion: "0.1.0",
	}, server.Client())
	if err == nil || !strings.Contains(err.Error(), "incomplete enrollment response") {
		t.Fatalf("expected fingerprint mismatch to be rejected, got %v", err)
	}
}

func TestEnrollAgentRejectsInsecureURLAndInvalidToken(t *testing.T) {
	metadata := EnrollmentMetadata{Hostname: "WS-01", OSFamily: "windows", AgentVersion: "0.1.0"}
	if _, err := EnrollAgent(context.Background(), "http://localhost", enrollmentTestToken, metadata, nil); err == nil {
		t.Fatal("expected cleartext server URL to be rejected")
	}
	if _, err := EnrollAgent(context.Background(), "https://example.invalid", "not-a-token", metadata, nil); err == nil {
		t.Fatal("expected malformed enrollment token to be rejected")
	}
}

func TestResolveBindingServerURL(t *testing.T) {
	tests := []struct {
		name       string
		configured string
		requested  string
		want       string
		persist    bool
		wantErr    bool
	}{
		{name: "uses app URL when machine URL is empty", requested: "https://core.example.test/", want: "https://core.example.test", persist: true},
		{name: "keeps matching machine URL", configured: "https://core.example.test/", requested: "https://core.example.test", want: "https://core.example.test"},
		{name: "rejects a different server", configured: "https://core.example.test", requested: "https://other.example.test", wantErr: true},
		{name: "rejects insecure app URL", requested: "http://core.example.test", wantErr: true},
		{name: "rejects case-different path", configured: "https://core.example.test/Case", requested: "https://core.example.test/case", wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, persist, err := ResolveBindingServerURL(tt.configured, tt.requested)
			if (err != nil) != tt.wantErr {
				t.Fatalf("ResolveBindingServerURL() error = %v, wantErr %v", err, tt.wantErr)
			}
			if err == nil && (got != tt.want || persist != tt.persist) {
				t.Fatalf("ResolveBindingServerURL() = (%q, %v), want (%q, %v)", got, persist, tt.want, tt.persist)
			}
		})
	}
}
