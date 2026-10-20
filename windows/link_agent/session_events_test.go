package linkagent

import "testing"

func TestSessionChangeName(t *testing.T) {
	tests := []struct {
		eventType uint32
		want      string
	}{
		{1, "console_connect"},
		{2, "console_disconnect"},
		{3, "remote_connect"},
		{4, "remote_disconnect"},
		{5, "session_logon"},
		{6, "session_logoff"},
		{7, "session_lock"},
		{8, "session_unlock"},
		{9, "session_remote_control"},
		{10, "session_create"},
		{11, "session_terminate"},
		{99, "unknown"},
	}
	for _, test := range tests {
		if got := SessionChangeName(test.eventType); got != test.want {
			t.Errorf("SessionChangeName(%d) = %q, want %q", test.eventType, got, test.want)
		}
	}
}
