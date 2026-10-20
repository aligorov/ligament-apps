package linkagent

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/gorilla/websocket"
)

// IdentityLoader loads an already-enrolled identity from a protected store.
// Implementations must not obtain private keys from process arguments or
// environment variables.
type IdentityLoader func() (*Identity, error)

// RunStoredAgent loads the identity once, owns its private-key memory for the
// connection lifecycle, and clears it when the agent stops. Windows service
// code can pass LoadIdentity as the loader; tests and other hosts can inject a
// protected store implementation. The loader must return memory owned by the
// caller because this function clears both key buffers before returning.
func RunStoredAgent(
	ctx context.Context,
	config AgentWSConfig,
	load IdentityLoader,
	dialer *websocket.Dialer,
	handler AgentMessageHandler,
	reportError func(error),
) error {
	if load == nil {
		return errors.New("link agent: nil identity loader")
	}
	identity, err := load()
	if err != nil {
		return fmt.Errorf("link agent: load enrolled identity: %w", err)
	}
	if identity == nil {
		return errors.New("link agent: identity loader returned nil")
	}
	defer clearIdentity(identity)
	config.Identity = identity
	return RunAgent(ctx, config, dialer, handler, reportError)
}

// ValidateAgentWSMetadata verifies registry/configuration data without requiring
// identity to be loaded first.
func ValidateAgentWSMetadata(config AgentWSConfig) error {
	if _, err := agentWebSocketEndpoint(config.ServerURL); err != nil {
		return err
	}
	return ValidateAgentHostMetadata(config)
}

// ValidateAgentHostMetadata checks host identity metadata independently of
// server configuration so a not-yet-enrolled service can wait for L1 binding.
func ValidateAgentHostMetadata(config AgentWSConfig) error {
	if strings.TrimSpace(config.Hostname) == "" || strings.TrimSpace(config.AgentVersion) == "" {
		return errors.New("link agent: hostname and agent version are required")
	}
	switch strings.ToLower(strings.TrimSpace(config.OSFamily)) {
	case "windows", "linux", "macos":
		return nil
	default:
		return errors.New("link agent: unsupported OS family")
	}
}

// RejectUnavailableSessionWorker is a fail-closed handler for service builds
// that do not yet have a desktop capture/input worker. It declines valid offers
// using the server's session_answer contract rather than leaving sessions open.
func RejectUnavailableSessionWorker(_ context.Context, message []byte, send func(any) error) error {
	var envelope Envelope
	if err := json.Unmarshal(message, &envelope); err != nil {
		return fmt.Errorf("link agent: decode server message: %w", err)
	}
	if envelope.Type != "session_offer" {
		return nil
	}
	offer, err := DecodeOffer(message)
	if err != nil {
		return err
	}
	answer, err := MarshalSessionAnswer(offer.SessionID, false, "host_worker_unavailable", "")
	if err != nil {
		return err
	}
	return send(json.RawMessage(answer))
}

// StoredAgentConfig returns host metadata from explicit service configuration;
// identity is deliberately loaded separately from the protected store.
func StoredAgentConfig(serverURL, hostname, osVersion, agentVersion string, capabilities map[string]any) AgentWSConfig {
	return AgentConfig(serverURL, hostname, "windows", osVersion, agentVersion, capabilities)
}

func AgentConfig(serverURL, hostname, osFamily, osVersion, agentVersion string, capabilities map[string]any) AgentWSConfig {
	return AgentWSConfig{
		ServerURL: serverURL, Hostname: hostname, OSFamily: osFamily,
		OSVersion: osVersion, AgentVersion: agentVersion, Capabilities: capabilities,
	}
}

func validatePersistedIdentity(identity *Identity) error {
	if identity == nil || !validUUID(identity.AgentID) || len(identity.PublicKey) != ed25519.PublicKeySize || len(identity.PrivateKey) != ed25519.PrivateKeySize {
		return errors.New("link agent: invalid identity record")
	}
	if !bytes.Equal(identity.PrivateKey[ed25519.SeedSize:], identity.PublicKey) {
		return errors.New("link agent: persisted key pair does not match")
	}
	fingerprint := sha256.Sum256(identity.PublicKey)
	if identity.Fingerprint != hex.EncodeToString(fingerprint[:]) {
		return errors.New("link agent: persisted identity fingerprint mismatch")
	}
	return nil
}

func clearIdentity(identity *Identity) {
	if identity == nil {
		return
	}
	clear(identity.PrivateKey)
	identity.PrivateKey = nil
	clear(identity.PublicKey)
	identity.PublicKey = nil
}

// ClearIdentity zeros private identity material held in caller-owned memory.
func ClearIdentity(identity *Identity) {
	clearIdentity(identity)
}
