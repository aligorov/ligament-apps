package linkagent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
)

func TestRDSSupervisor_Lifecycle(t *testing.T) {
	tempDir, err := os.MkdirTemp("", "rds_super_test_*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tempDir)

	var sentMessagesMu sync.Mutex
	var sentMessages []map[string]any

	sendToCore := func(msg any) error {
		sentMessagesMu.Lock()
		defer sentMessagesMu.Unlock()
		if m, ok := msg.(map[string]any); ok {
			sentMessages = append(sentMessages, m)
		}
		return nil
	}

	super, err := NewRDSSupervisor(tempDir, sendToCore, nil)
	if err != nil {
		t.Fatalf("NewRDSSupervisor: %v", err)
	}

	// 1. Handle logon of RDP session 2
	session := WTSSession{
		SessionID:    2,
		Username:     "ivanov",
		Domain:       "CORP",
		ClientIP:     "192.168.1.100",
		ClientName:   "DESKTOP-1",
		ProtocolType: WTSProtocolRDP,
		IsRDP:        true,
		IsActive:     true,
	}
	super.HandleSessionLogon(session)

	sentMessagesMu.Lock()
	if len(sentMessages) != 1 || sentMessages[0]["type"] != "rdp_session_start" {
		t.Fatalf("expected rdp_session_start message, got: %+v", sentMessages)
	}
	if sentMessages[0]["username"] != "ivanov" || sentMessages[0]["wts_session_id"] != uint32(2) {
		t.Fatalf("mismatch in logon message: %+v", sentMessages[0])
	}
	sentMessagesMu.Unlock()

	// 2. Mock recorder server
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(BatchACK{Status: "ok"})
	}))
	defer ts.Close()

	// 3. Apply session policy from Core
	ctx := context.Background()
	policy := RDSSessionStartPolicy{
		WTSSessionID:  2,
		SessionID:     "core-sess-uuid",
		Record:        true,
		RecorderURL:   ts.URL + "/batch",
		IngestToken:   "tok-123",
		FailurePolicy: "resilient",
		TargetFPS:     1.0,
		Quality:       65,
	}
	if err := super.ApplySessionPolicy(ctx, policy); err != nil {
		t.Fatalf("ApplySessionPolicy: %v", err)
	}

	// 4. Handle logoff
	super.HandleSessionLogoff(2, "user_logoff")

	sentMessagesMu.Lock()
	if len(sentMessages) != 2 || sentMessages[1]["type"] != "rdp_session_end" {
		t.Fatalf("expected rdp_session_end message, got: %+v", sentMessages)
	}
	sentMessagesMu.Unlock()

	// 5. Clean up
	super.StopAll("shutdown")
}
