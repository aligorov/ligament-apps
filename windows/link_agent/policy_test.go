package linkagent

import (
	"context"
	"encoding/json"
	"testing"
)

func TestApplyPolicy_Serialization(t *testing.T) {
	one := 1
	zero := 0
	cmd := ApplyPolicyCommand{
		CommandID:           "test-cmd-1",
		Console2FAEnabled:   &one,
		RDP2FAEnabled:       &zero,
		Elevation2FAEnabled: &one,
	}

	raw, err := json.Marshal(cmd)
	if err != nil {
		t.Fatalf("marshal cmd failed: %v", err)
	}

	var decoded ApplyPolicyCommand
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal cmd failed: %v", err)
	}

	if decoded.CommandID != "test-cmd-1" || *decoded.Console2FAEnabled != 1 || *decoded.RDP2FAEnabled != 0 {
		t.Fatalf("decoded policy mismatch: %+v", decoded)
	}
}

func TestSessionWorkerBroker_PolicyAndLockRouting(t *testing.T) {
	origLock := lockWTSSessionFn
	origLogoff := logoffWTSSessionFn
	origApply := applyHostPolicyFn
	origRead := readHostPolicyFn
	origEnum := enumerateSessionsFn
	defer func() {
		lockWTSSessionFn = origLock
		logoffWTSSessionFn = origLogoff
		applyHostPolicyFn = origApply
		readHostPolicyFn = origRead
		enumerateSessionsFn = origEnum
	}()

	lockWTSSessionFn = func(s WTSSession) error { return nil }
	logoffWTSSessionFn = func(sessionID uint32, wait bool) error { return nil }
	applyHostPolicyFn = func(cmd ApplyPolicyCommand) error { return nil }
	readHostPolicyFn = func() HostPolicyStatus {
		return HostPolicyStatus{Console2FAEnabled: 1, Console2FASource: "local"}
	}
	enumerateSessionsFn = func() ([]WTSSession, error) {
		return []WTSSession{{SessionID: 1, Username: "bob", IsActive: true, IsConsole: true}}, nil
	}

	broker := NewSessionWorkerBroker(nil)

	sentFrames := make([][]byte, 0)
	sender := func(msg any) error {
		raw, err := json.Marshal(msg)
		if err != nil {
			return err
		}
		sentFrames = append(sentFrames, raw)
		return nil
	}

	// 1. host_lock envelope routing
	lockPayload := `{"type":"host_lock","command_id":"lock-123","username":"bob","reason":"AD disable"}`
	if err := broker.Handler(context.Background(), []byte(lockPayload), sender); err != nil {
		t.Fatalf("handler failed on host_lock: %v", err)
	}

	// 2. host_logoff envelope routing
	logoffPayload := `{"type":"host_logoff","command_id":"logoff-123","wts_session_id":2}`
	if err := broker.Handler(context.Background(), []byte(logoffPayload), sender); err != nil {
		t.Fatalf("handler failed on host_logoff: %v", err)
	}

	// 3. apply_policy envelope routing
	policyPayload := `{"type":"apply_policy","command_id":"pol-123","console_2fa_enabled":1}`
	if err := broker.Handler(context.Background(), []byte(policyPayload), sender); err != nil {
		t.Fatalf("handler failed on apply_policy: %v", err)
	}

	// Verify sender received policy_status acknowledgment frame
	if len(sentFrames) != 1 {
		t.Fatalf("expected 1 response frame for apply_policy, got %d", len(sentFrames))
	}
	var resp map[string]any
	if err := json.Unmarshal(sentFrames[0], &resp); err != nil {
		t.Fatalf("unmarshal resp failed: %v", err)
	}
	if resp["type"] != "policy_status" || resp["command_id"] != "pol-123" {
		t.Fatalf("unexpected policy response: %+v", resp)
	}
}
