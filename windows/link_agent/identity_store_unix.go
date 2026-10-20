//go:build darwin || linux

package linkagent

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/go-keyring/keyring"
)

const (
	unixIdentityService = "com.ligament.link-agent"
	unixIdentityAccount = "identity-v1"
	unixIdentityLimit   = 128 * 1024
)

type unixIdentityRecord struct {
	Version          int    `json:"version"`
	ServerURL        string `json:"server_url"`
	AgentID          string `json:"agent_id"`
	PublicKey        []byte `json:"public_key"`
	PrivateKey       []byte `json:"private_key"`
	Fingerprint      string `json:"fingerprint"`
	ServerTimeOffset int64  `json:"server_time_offset_ns"`
}

type unixCredentialVault interface {
	Get(service, account string) ([]byte, error)
	Set(service, account string, secret []byte) error
	Delete(service, account string) error
}

type nativeUnixCredentialVault struct{}

func (nativeUnixCredentialVault) Get(service, account string) ([]byte, error) {
	return keyring.Get(service, account)
}

func (nativeUnixCredentialVault) Set(service, account string, secret []byte) error {
	return keyring.Set(service, account, secret)
}

func (nativeUnixCredentialVault) Delete(service, account string) error {
	return keyring.Delete(service, account)
}

var unixIdentityVault unixCredentialVault = nativeUnixCredentialVault{}

// SaveAgentIdentity stores the private identity and pinned server URL together
// in macOS Keychain or the Linux Secret Service. It deliberately has no file or
// environment-variable fallback; unavailable native vaults fail closed.
func SaveAgentIdentity(identity *Identity, serverURL string) error {
	if err := validatePersistedIdentity(identity); err != nil {
		return err
	}
	if _, err := enrollmentEndpoint(serverURL); err != nil {
		return fmt.Errorf("link agent: invalid identity server URL: %w", err)
	}
	record := unixIdentityRecord{
		Version: 1, ServerURL: serverURL,
		AgentID: identity.AgentID, PublicKey: append([]byte(nil), identity.PublicKey...),
		PrivateKey:  append([]byte(nil), identity.PrivateKey...),
		Fingerprint: identity.Fingerprint, ServerTimeOffset: int64(identity.ServerTimeOffset),
	}
	payload, err := json.Marshal(record)
	clear(record.PrivateKey)
	if err != nil {
		return fmt.Errorf("link agent: encode native identity: %w", err)
	}
	defer clear(payload)
	if len(payload) == 0 || len(payload) > unixIdentityLimit {
		return errors.New("link agent: native identity exceeds storage limit")
	}
	if err := unixIdentityVault.Set(unixIdentityService, unixIdentityAccount, payload); err != nil {
		return fmt.Errorf("link agent: save identity to native credential store: %w", err)
	}
	return nil
}

// LoadAgentIdentity returns the enrolled identity and its pinned HTTPS URL.
// A missing identity is reported as os.ErrNotExist; an unavailable keyring is
// returned as an error and is never treated as an unenrolled host.
func LoadAgentIdentity() (*Identity, string, error) {
	payload, err := unixIdentityVault.Get(unixIdentityService, unixIdentityAccount)
	if errors.Is(err, keyring.ErrNotFound) {
		return nil, "", os.ErrNotExist
	}
	if err != nil {
		return nil, "", fmt.Errorf("link agent: load identity from native credential store: %w", err)
	}
	defer clear(payload)
	if len(payload) == 0 || len(payload) > unixIdentityLimit {
		return nil, "", errors.New("link agent: invalid native identity size")
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	var record unixIdentityRecord
	if err := decoder.Decode(&record); err != nil {
		return nil, "", fmt.Errorf("link agent: decode native identity: %w", err)
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		clear(record.PrivateKey)
		return nil, "", errors.New("link agent: trailing native identity data")
	}
	identity := &Identity{
		AgentID:          record.AgentID,
		PublicKey:        append(ed25519.PublicKey(nil), record.PublicKey...),
		PrivateKey:       append(ed25519.PrivateKey(nil), record.PrivateKey...),
		Fingerprint:      record.Fingerprint,
		ServerTimeOffset: time.Duration(record.ServerTimeOffset),
	}
	clear(record.PrivateKey)
	if record.Version != 1 {
		clearIdentity(identity)
		return nil, "", errors.New("link agent: unsupported native identity version")
	}
	if err := validatePersistedIdentity(identity); err != nil {
		clearIdentity(identity)
		return nil, "", err
	}
	if _, err := enrollmentEndpoint(record.ServerURL); err != nil {
		clearIdentity(identity)
		return nil, "", errors.New("link agent: native identity has an invalid server URL")
	}
	return identity, record.ServerURL, nil
}

func DeleteAgentIdentity() error {
	return unixIdentityVault.Delete(unixIdentityService, unixIdentityAccount)
}
