package linkagent

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"testing"
	"time"
)

func TestNewHelloMatchesServerSignatureContract(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	hello, err := NewHello("01234567-89ab-cdef-0123-456789abcdef", "WS-01", "windows", "11", "0.1.0", map[string]any{"desktop": true}, privateKey, time.Unix(1_800_000_000, 0))
	if err != nil {
		t.Fatal(err)
	}
	if !VerifyHello(hello, publicKey) {
		t.Fatal("server-compatible Ed25519 signature did not verify")
	}

	encoded, err := MarshalHello(hello)
	if err != nil {
		t.Fatal(err)
	}
	var decoded Hello
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if !VerifyHello(decoded, publicKey) {
		t.Fatal("JSON handshake changed the signature payload")
	}
	decoded.Nonce += "x"
	if VerifyHello(decoded, publicKey) {
		t.Fatal("modified nonce unexpectedly verified")
	}
}

func TestNewHelloRejectsInvalidIdentityAndKey(t *testing.T) {
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := NewHello("bad-id", "WS-01", "windows", "11", "0.1.0", nil, privateKey, time.Now()); err == nil {
		t.Fatal("expected invalid UUID rejection")
	}
	if _, err := NewHello("01234567-89ab-cdef-0123-456789abcdef", "WS-01", "windows", "11", "0.1.0", nil, privateKey[:10], time.Now()); err == nil {
		t.Fatal("expected invalid key rejection")
	}
}
