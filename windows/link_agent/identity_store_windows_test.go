//go:build windows

package linkagent

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestProtectedIdentityStoreRoundTripAndTamperRejection(t *testing.T) {
	identity := testAgentIdentity(t)
	identity.ServerTimeOffset = 37 * time.Second
	path := filepath.Join(t.TempDir(), "Ligament", "Link", "identity.bin")
	if err := saveIdentityAt(path, identity); err != nil {
		t.Fatal(err)
	}
	sealed, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(sealed, identity.PrivateKey) {
		t.Fatal("identity file contains the plaintext private key")
	}
	restored, err := loadIdentityAt(path)
	if err != nil {
		t.Fatal(err)
	}
	if restored.AgentID != identity.AgentID || restored.Fingerprint != identity.Fingerprint || restored.ServerTimeOffset != identity.ServerTimeOffset || !bytes.Equal(restored.PrivateKey, identity.PrivateKey) {
		t.Fatal("identity store round-trip changed enrolled identity")
	}
	clear(restored.PrivateKey)

	sealed[len(sealed)/2] ^= 0x40
	if err := os.WriteFile(path, sealed, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadIdentityAt(path); err == nil {
		t.Fatal("tampered identity file unexpectedly decrypted")
	}
}

func TestSaveIdentityRejectsMismatchedKeyPair(t *testing.T) {
	identity := testAgentIdentity(t)
	other := testAgentIdentity(t)
	identity.PrivateKey = other.PrivateKey
	path := filepath.Join(t.TempDir(), "identity.bin")
	if err := saveIdentityAt(path, identity); err == nil {
		t.Fatal("expected mismatched identity keypair to be rejected")
	}
}
