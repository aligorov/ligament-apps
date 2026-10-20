package linkagent

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

const testSessionID = "10000000-0000-4000-8000-000000000001"
const testOperatorID = "20000000-0000-4000-8000-000000000002"

func TestDecodeServerSessionOffer(t *testing.T) {
	data := []byte(`{"type":"session_offer","payload":{"session_id":"` + testSessionID + `","operator_id":"` + testOperatorID + `","access_type":"attended","access_mode":"view","sdp":"v=0","ice_servers":[],"dlp":{"allow_clipboard_in":false}}}`)
	offer, err := DecodeOffer(data)
	if err != nil {
		t.Fatal(err)
	}
	if offer.SessionID != testSessionID || offer.AccessMode != "view" || offer.SDP != "v=0" {
		t.Fatalf("unexpected decoded offer: %+v", offer)
	}
}

func TestDecodeOfferRejectsWrongTypeAndInvalidAccessMode(t *testing.T) {
	if _, err := DecodeOffer([]byte(`{"type":"heartbeat"}`)); err == nil {
		t.Fatal("expected wrong message type to be rejected")
	}
	data := []byte(`{"type":"session_offer","payload":{"session_id":"` + testSessionID + `","operator_id":"` + testOperatorID + `","access_type":"attended","access_mode":"admin","sdp":"v=0","dlp":{}}}`)
	if _, err := DecodeOffer(data); err == nil {
		t.Fatal("expected unsupported access mode to be rejected")
	}
}

func TestDecodeOfferRejectsOversizedHostWorkerInputs(t *testing.T) {
	tests := []struct {
		name  string
		field string
		size  int
	}{
		{name: "sdp", field: "sdp", size: maxSessionSDPBytes + 1},
		{name: "ice servers", field: "ice_servers", size: maxSessionICEServersSize + 1},
		{name: "dlp", field: "dlp", size: maxSessionDLPSize + 1},
		{name: "relay token", field: "relay_token", size: maxRelayTokenBytes + 1},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			value := strings.Repeat("x", test.size)
			if test.field == "ice_servers" || test.field == "dlp" {
				value = `"` + value + `"`
			}
			payload := `{"session_id":"` + testSessionID + `","operator_id":"` +
				testOperatorID + `","access_type":"attended","access_mode":"view",` +
				`"sdp":"v=0","ice_servers":[],"dlp":{},"relay_token":""}`
			var fields map[string]json.RawMessage
			if err := json.Unmarshal([]byte(payload), &fields); err != nil {
				t.Fatal(err)
			}
			if test.field == "dlp" {
				fields[test.field] = json.RawMessage(value)
			} else {
				encoded, err := json.Marshal(value)
				if err != nil {
					t.Fatal(err)
				}
				fields[test.field] = encoded
			}
			if test.field == "sdp" {
				encoded, err := json.Marshal(value)
				if err != nil {
					t.Fatal(err)
				}
				fields[test.field] = encoded
			}
			payloadBytes, err := json.Marshal(fields)
			if err != nil {
				t.Fatal(err)
			}
			envelope, err := json.Marshal(map[string]json.RawMessage{
				`"type"`:    json.RawMessage(`"session_offer"`),
				`"payload"`: payloadBytes,
			})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := DecodeOffer(envelope); err == nil {
				t.Fatalf("DecodeOffer accepted oversized %s", test.field)
			}
		})
	}
}

func TestMarshalSessionAnswerMatchesServerEnvelope(t *testing.T) {
	data, err := MarshalSessionAnswer(testSessionID, true, "", "v=0 answer")
	if err != nil {
		t.Fatal(err)
	}
	var message struct {
		Type      string `json:"type"`
		SessionID string `json:"session_id"`
		Payload   struct {
			SessionID string `json:"session_id"`
			Accepted  bool   `json:"accepted"`
			SDP       string `json:"sdp"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(data, &message); err != nil {
		t.Fatal(err)
	}
	if message.Type != "session_answer" || message.SessionID != testSessionID || message.Payload.SessionID != testSessionID || !message.Payload.Accepted || message.Payload.SDP != "v=0 answer" {
		t.Fatalf("unexpected answer envelope: %s", data)
	}
}

func TestRejectUnavailableSessionWorkerDeclinesOffer(t *testing.T) {
	data := []byte(`{"type":"session_offer","payload":{"session_id":"` + testSessionID + `","operator_id":"` + testOperatorID + `","access_type":"attended","access_mode":"view","sdp":"v=0","ice_servers":[],"dlp":{}}}`)
	var sent any
	err := RejectUnavailableSessionWorker(context.Background(), data, func(message any) error {
		sent = message
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	raw, ok := sent.(json.RawMessage)
	if !ok {
		t.Fatalf("sent message has type %T, want json.RawMessage", sent)
	}
	var response struct {
		Type    string `json:"type"`
		Payload struct {
			SessionID string `json:"session_id"`
			Accepted  bool   `json:"accepted"`
			Reason    string `json:"reason"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		t.Fatal(err)
	}
	if response.Type != "session_answer" || response.Payload.SessionID != testSessionID || response.Payload.Accepted || response.Payload.Reason != "host_worker_unavailable" {
		t.Fatalf("unexpected fail-closed answer: %s", raw)
	}
}

func TestRejectUnavailableSessionWorkerIgnoresNonOffer(t *testing.T) {
	sent := false
	err := RejectUnavailableSessionWorker(context.Background(), []byte(`{"type":"heartbeat_ack"}`), func(any) error {
		sent = true
		return nil
	})
	if err != nil || sent {
		t.Fatalf("non-offer: sent=%v err=%v, want no-op", sent, err)
	}
}
