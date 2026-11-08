package linkagent

import (
	"encoding/json"
	"testing"
	"time"
)

func TestHostTelemetry_Serialization(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	telemetry := HostTelemetry{
		UptimeSeconds:   3600,
		CPUUsagePercent: 15,
		RAMUsedMB:       8192,
		RAMTotalMB:      16384,
		DiskTotalGB:     512,
		DiskFreeGB:      256,
		IsDomainJoined:  true,
		Sessions: []WTSSession{
			{
				SessionID: 1,
				Username:  "alice",
				Domain:    "CORP",
				IsActive:  true,
				IsConsole: true,
				IsLocked:  false,
				LogonTime: now,
			},
		},
	}

	raw, err := json.Marshal(telemetry)
	if err != nil {
		t.Fatalf("marshal telemetry failed: %v", err)
	}

	var decoded HostTelemetry
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal telemetry failed: %v", err)
	}

	if decoded.UptimeSeconds != 3600 || decoded.CPUUsagePercent != 15 || decoded.RAMUsedMB != 8192 {
		t.Fatalf("decoded metrics mismatch: %+v", decoded)
	}
	if !decoded.IsDomainJoined || len(decoded.Sessions) != 1 {
		t.Fatalf("decoded domain/sessions mismatch: %+v", decoded)
	}
	if decoded.Sessions[0].Username != "alice" || decoded.Sessions[0].IsLocked != false {
		t.Fatalf("decoded session mismatch: %+v", decoded.Sessions[0])
	}
}

func TestAgentHeartbeatMessage_IncludesTelemetry(t *testing.T) {
	cfg := AgentWSConfig{
		LocalIPs: func() []string { return []string{"192.168.1.50"} },
		InteractiveUser: func() string { return "alice" },
		Telemetry: func() HostTelemetry {
			return HostTelemetry{
				CPUUsagePercent: 22,
				RAMUsedMB:       4096,
				RAMTotalMB:      8192,
				DiskTotalGB:     256,
				DiskFreeGB:      128,
				IsDomainJoined:  true,
			}
		},
		PolicyStatus: func() HostPolicyStatus {
			return HostPolicyStatus{
				Console2FAEnabled: 1,
				Console2FASource:  "gpo",
			}
		},
	}

	msg := agentHeartbeatMessage(cfg, true)
	if msg["type"] != "heartbeat" {
		t.Fatalf("expected heartbeat type, got %v", msg["type"])
	}
	if msg["cpu_usage_percent"] != 22 || msg["disk_total_gb"] != 256 {
		t.Fatalf("heartbeat missing telemetry fields: %+v", msg)
	}
	pol, ok := msg["policy_status"].(HostPolicyStatus)
	if !ok || pol.Console2FAEnabled != 1 || pol.Console2FASource != "gpo" {
		t.Fatalf("heartbeat missing policy status: %+v", msg["policy_status"])
	}
}
