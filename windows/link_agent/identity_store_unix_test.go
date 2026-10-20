//go:build darwin || linux

package linkagent

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/go-keyring/keyring"
)

type memoryCredentialVault struct {
	secret []byte
	err    error
}

func (v *memoryCredentialVault) Get(_, _ string) ([]byte, error) {
	if v.err != nil {
		return nil, v.err
	}
	if v.secret == nil {
		return nil, keyring.ErrNotFound
	}
	return append([]byte(nil), v.secret...), nil
}

func (v *memoryCredentialVault) Set(_, _ string, secret []byte) error {
	if v.err != nil {
		return v.err
	}
	v.secret = append([]byte(nil), secret...)
	return nil
}

func (v *memoryCredentialVault) Delete(_, _ string) error {
	v.secret = nil
	return nil
}

func useMemoryVault(t *testing.T) *memoryCredentialVault {
	t.Helper()
	previous := unixIdentityVault
	vault := &memoryCredentialVault{}
	unixIdentityVault = vault
	t.Cleanup(func() { unixIdentityVault = previous })
	return vault
}

func TestUnixIdentityStoreUsesCredentialVaultAndRoundTrips(t *testing.T) {
	vault := useMemoryVault(t)
	identity := testAgentIdentity(t)
	identity.ServerTimeOffset = 31 * time.Second
	serverURL := "https://core.example.test/prefix"
	if err := SaveAgentIdentity(identity, serverURL); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(vault.secret, identity.PrivateKey) {
		t.Fatal("native vault payload contains an unencoded private key byte sequence")
	}
	restored, gotURL, err := LoadAgentIdentity()
	if err != nil {
		t.Fatal(err)
	}
	defer clearIdentity(restored)
	if gotURL != serverURL || restored.AgentID != identity.AgentID ||
		restored.Fingerprint != identity.Fingerprint ||
		restored.ServerTimeOffset != identity.ServerTimeOffset ||
		!bytes.Equal(restored.PrivateKey, identity.PrivateKey) {
		t.Fatal("native credential store round-trip changed identity/configuration")
	}
}

func TestUnixIdentityStoreFailsClosedForMissingOrUnavailableVault(t *testing.T) {
	vault := useMemoryVault(t)
	if _, _, err := LoadAgentIdentity(); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("missing identity error = %v, want os.ErrNotExist", err)
	}
	vault.err = keyring.ErrUnavailable
	if _, _, err := LoadAgentIdentity(); !errors.Is(err, keyring.ErrUnavailable) {
		t.Fatalf("unavailable vault error = %v, want ErrUnavailable", err)
	}
	if err := SaveAgentIdentity(testAgentIdentity(t), "https://core.example.test"); !errors.Is(err, keyring.ErrUnavailable) {
		t.Fatalf("save error = %v, want ErrUnavailable", err)
	}
}

func TestUnixIdentityStoreRejectsTamperedRecordAndInvalidURL(t *testing.T) {
	vault := useMemoryVault(t)
	identity := testAgentIdentity(t)
	if err := SaveAgentIdentity(identity, "https://core.example.test"); err != nil {
		t.Fatal(err)
	}
	var record unixIdentityRecord
	if err := json.Unmarshal(vault.secret, &record); err != nil {
		t.Fatal(err)
	}
	record.ServerURL = "http://core.example.test"
	vault.secret, _ = json.Marshal(record)
	clear(record.PrivateKey)
	if _, _, err := LoadAgentIdentity(); err == nil {
		t.Fatal("invalid pinned server URL was accepted")
	}
	if err := SaveAgentIdentity(identity, "http://core.example.test"); err == nil {
		t.Fatal("non-HTTPS server URL was stored")
	}
}
