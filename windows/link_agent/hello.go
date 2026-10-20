// Package linkagent implements the authenticated Link agent wire handshake.
package linkagent

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

const (
	PublicKeySize  = ed25519.PublicKeySize
	PrivateKeySize = ed25519.PrivateKeySize
	SignatureSize  = ed25519.SignatureSize
)

// Hello is the first JSON message sent by an enrolled agent over its WSS
// connection. Signature is encoded as base64 by encoding/json, matching Go's
// encoding of the server-side []byte field.
type Hello struct {
	AgentID      string         `json:"agent_id"`
	Hostname     string         `json:"hostname"`
	OSFamily     string         `json:"os_family"`
	OSVersion    string         `json:"os_version"`
	AgentVersion string         `json:"agent_version"`
	Capabilities map[string]any `json:"capabilities"`
	Timestamp    int64          `json:"timestamp"`
	Nonce        string         `json:"nonce"`
	Signature    []byte         `json:"signature"`
}

// NewHello creates a nonce and signs the exact digest verified by 2fa's
// internal/link.VerifyAgentHello implementation.
func NewHello(agentID, hostname, osFamily, osVersion, agentVersion string, capabilities map[string]any, privateKey ed25519.PrivateKey, now time.Time) (Hello, error) {
	var hello Hello
	if len(privateKey) != PrivateKeySize {
		return hello, errors.New("link agent: invalid Ed25519 private key")
	}
	if !validUUID(agentID) {
		return hello, errors.New("link agent: invalid agent UUID")
	}
	if hostname == "" || osFamily == "" || agentVersion == "" {
		return hello, errors.New("link agent: hostname, OS family, and agent version are required")
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return hello, fmt.Errorf("link agent: create nonce: %w", err)
	}
	hello = Hello{
		AgentID: agentID, Hostname: hostname, OSFamily: osFamily,
		OSVersion: osVersion, AgentVersion: agentVersion,
		Capabilities: capabilities, Timestamp: now.Unix(),
		Nonce: hex.EncodeToString(nonce),
	}
	digest, err := helloDigest(agentID, hello.Nonce, hello.Timestamp)
	if err != nil {
		return Hello{}, err
	}
	hello.Signature = ed25519.Sign(privateKey, digest)
	return hello, nil
}

// MarshalHello returns the JSON handshake payload.
func MarshalHello(hello Hello) ([]byte, error) {
	return json.Marshal(hello)
}

// VerifyHello is intended for protocol tests and local diagnostics.
func VerifyHello(hello Hello, publicKey ed25519.PublicKey) bool {
	digest, err := helloDigest(hello.AgentID, hello.Nonce, hello.Timestamp)
	return err == nil && len(publicKey) == PublicKeySize && len(hello.Signature) == SignatureSize && ed25519.Verify(publicKey, digest, hello.Signature)
}

func helloDigest(agentID, nonce string, timestamp int64) ([]byte, error) {
	if !validUUID(agentID) || nonce == "" {
		return nil, errors.New("link agent: invalid handshake identity or nonce")
	}
	uuidBytes, _ := hex.DecodeString(agentID[0:8] + agentID[9:13] + agentID[14:18] + agentID[19:23] + agentID[24:36])
	digest := make([]byte, 16+len(nonce)+8)
	copy(digest, uuidBytes)
	copy(digest[16:], nonce)
	binary.BigEndian.PutUint64(digest[16+len(nonce):], uint64(timestamp))
	return digest, nil
}

func validUUID(value string) bool {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return false
	}
	_, err := hex.DecodeString(value[0:8] + value[9:13] + value[14:18] + value[19:23] + value[24:36])
	return err == nil
}
