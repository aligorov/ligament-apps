package linkagent

import (
	"encoding/json"
	"errors"
	"fmt"
)

const (
	maxSessionSDPBytes       = 256 * 1024
	maxSessionICEServersSize = 64 * 1024
	maxSessionDLPSize        = 16 * 1024
	maxSessionRecordingSize  = 16 * 1024
	maxRelayTokenBytes       = 4 * 1024
)

// Envelope is a server-to-agent message. Payload and Signal remain raw JSON so
// protocol additions do not cause lossy round-trips in older agents.
type Envelope struct {
	Type      string          `json:"type"`
	SessionID string          `json:"session_id,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`
	Signal    json.RawMessage `json:"signal,omitempty"`
}

// SessionOffer is the subset of the server offer consumed by the host runtime.
type SessionOffer struct {
	SessionID    string          `json:"session_id"`
	OperatorID   string          `json:"operator_id"`
	OperatorName string          `json:"operator_name,omitempty"`
	SessionKind  string          `json:"session_kind,omitempty"`
	AccessType   string          `json:"access_type"`
	DesktopScope string          `json:"desktop_scope,omitempty"`
	AccessMode   string          `json:"access_mode"`
	SDP          string          `json:"sdp,omitempty"`
	ICEServers   json.RawMessage `json:"ice_servers,omitempty"`
	RelayURL     string          `json:"relay_url,omitempty"`
	RelayToken   string          `json:"relay_token,omitempty"`
	DLP          json.RawMessage `json:"dlp"`
	Recording    json.RawMessage `json:"recording,omitempty"`
}

// DecodeOffer validates and decodes the server's session_offer envelope.
func DecodeOffer(data []byte) (SessionOffer, error) {
	var envelope Envelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		return SessionOffer{}, fmt.Errorf("link agent: decode envelope: %w", err)
	}
	if envelope.Type != "session_offer" || len(envelope.Payload) == 0 {
		return SessionOffer{}, errors.New("link agent: expected session_offer with payload")
	}
	var offer SessionOffer
	if err := json.Unmarshal(envelope.Payload, &offer); err != nil {
		return SessionOffer{}, fmt.Errorf("link agent: decode session offer: %w", err)
	}
	if !validUUID(offer.SessionID) || !validUUID(offer.OperatorID) {
		return SessionOffer{}, errors.New("link agent: invalid session or operator UUID")
	}
	if len(offer.OperatorName) > 512 {
		return SessionOffer{}, errors.New("link agent: operator display name exceeds size limit")
	}
	if offer.AccessMode != "view" && offer.AccessMode != "control" {
		return SessionOffer{}, errors.New("link agent: invalid access mode")
	}
	if offer.AccessType != "attended" && offer.AccessType != "unattended" {
		return SessionOffer{}, errors.New("link agent: invalid access type")
	}
	if offer.DesktopScope != "" && offer.DesktopScope != "interactive" && offer.DesktopScope != "system_console" {
		return SessionOffer{}, errors.New("link agent: invalid desktop scope")
	}
	if offer.DesktopScope == "system_console" && offer.AccessType != "unattended" {
		return SessionOffer{}, errors.New("link agent: system_console scope requires unattended access")
	}
	if offer.SDP == "" || len(offer.SDP) > maxSessionSDPBytes {
		return SessionOffer{}, errors.New("link agent: incomplete or oversized session SDP")
	}
	if len(offer.DLP) == 0 || len(offer.DLP) > maxSessionDLPSize || !json.Valid(offer.DLP) {
		return SessionOffer{}, errors.New("link agent: incomplete session offer")
	}
	if len(offer.ICEServers) > maxSessionICEServersSize ||
		(len(offer.ICEServers) != 0 && !json.Valid(offer.ICEServers)) {
		return SessionOffer{}, errors.New("link agent: invalid ICE server configuration")
	}
	if len(offer.RelayToken) > maxRelayTokenBytes {
		return SessionOffer{}, errors.New("link agent: relay token exceeds size limit")
	}
	if len(offer.Recording) > maxSessionRecordingSize ||
		(len(offer.Recording) != 0 && !json.Valid(offer.Recording)) {
		return SessionOffer{}, errors.New("link agent: invalid recording configuration")
	}
	return offer, nil
}

// MarshalSessionAnswer creates the server-compatible session_answer message.
func MarshalSessionAnswer(sessionID string, accepted bool, reason, sdp string) ([]byte, error) {
	if !validUUID(sessionID) {
		return nil, errors.New("link agent: invalid session UUID")
	}
	payload, err := json.Marshal(struct {
		SessionID string `json:"session_id"`
		Accepted  bool   `json:"accepted"`
		Reason    string `json:"reason,omitempty"`
		SDP       string `json:"sdp,omitempty"`
	}{sessionID, accepted, reason, sdp})
	if err != nil {
		return nil, fmt.Errorf("link agent: encode session answer: %w", err)
	}
	message, err := json.Marshal(struct {
		Type      string          `json:"type"`
		SessionID string          `json:"session_id"`
		Payload   json.RawMessage `json:"payload"`
	}{"session_answer", sessionID, payload})
	if err != nil {
		return nil, fmt.Errorf("link agent: encode answer envelope: %w", err)
	}
	return message, nil
}
