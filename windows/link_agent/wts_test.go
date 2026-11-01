package linkagent

import (
	"testing"
)

func TestParseWTSClientAddress(t *testing.T) {
	// IPv4: AF_INET = 2, IP starts at byte index 2: 192.168.1.55
	rawIPv4 := []byte{0, 0, 192, 168, 1, 55, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	ip := parseWTSClientAddress(2, rawIPv4)
	if ip != "192.168.1.55" {
		t.Fatalf("parseWTSClientAddress IPv4: got %q, want %q", ip, "192.168.1.55")
	}

	// Loopback should be ignored (empty string)
	rawLoopback := []byte{0, 0, 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	if got := parseWTSClientAddress(2, rawLoopback); got != "" {
		t.Fatalf("parseWTSClientAddress loopback: got %q, want empty", got)
	}

	// Unknown family should return empty
	if got := parseWTSClientAddress(999, rawIPv4); got != "" {
		t.Fatalf("parseWTSClientAddress unknown family: got %q, want empty", got)
	}
}

func TestWTSSession_UserAccount(t *testing.T) {
	sess := WTSSession{
		Domain:   "corp",
		Username: "ivanov",
	}
	if got := sess.UserAccount(); got != "CORP\\ivanov" {
		t.Fatalf("got %q, want CORP\\ivanov", got)
	}

	sessNoDomain := WTSSession{Username: "localadmin"}
	if got := sessNoDomain.UserAccount(); got != "localadmin" {
		t.Fatalf("got %q, want localadmin", got)
	}
}
