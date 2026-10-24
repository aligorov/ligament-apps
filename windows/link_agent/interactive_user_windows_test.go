//go:build windows

package linkagent

import (
	"errors"
	"testing"
)

func TestResolveInteractiveSession(t *testing.T) {
	original := enumerateInteractiveSessions
	defer func() { enumerateInteractiveSessions = original }()

	t.Run("no active sessions", func(t *testing.T) {
		enumerateInteractiveSessions = func() ([]InteractiveSession, error) {
			return nil, nil
		}
		sess, err := ResolveInteractiveSession()
		if sess != nil || !errors.Is(err, ErrNoActiveInteractiveUser) {
			t.Fatalf("got sess=%v, err=%v, want ErrNoActiveInteractiveUser", sess, err)
		}
		if user := CurrentInteractiveUser(); user != "" {
			t.Fatalf("CurrentInteractiveUser() = %q, want empty", user)
		}
	})

	t.Run("single console or rdp user", func(t *testing.T) {
		enumerateInteractiveSessions = func() ([]InteractiveSession, error) {
			return []InteractiveSession{{SessionID: 2, Username: "alice"}}, nil
		}
		sess, err := ResolveInteractiveSession()
		if err != nil || sess == nil || sess.SessionID != 2 || sess.Username != "alice" {
			t.Fatalf("got sess=%v, err=%v, want SessionID=2, Username=alice", sess, err)
		}
		if user := CurrentInteractiveUser(); user != "alice" {
			t.Fatalf("CurrentInteractiveUser() = %q, want alice", user)
		}
	})

	t.Run("ambiguous multiple users", func(t *testing.T) {
		enumerateInteractiveSessions = func() ([]InteractiveSession, error) {
			return []InteractiveSession{
				{SessionID: 1, Username: "alice"},
				{SessionID: 2, Username: "bob"},
			}, nil
		}
		sess, err := ResolveInteractiveSession()
		if sess != nil || !errors.Is(err, ErrAmbiguousInteractiveSession) {
			t.Fatalf("got sess=%v, err=%v, want ErrAmbiguousInteractiveSession", sess, err)
		}
		if user := CurrentInteractiveUser(); user != "" {
			t.Fatalf("CurrentInteractiveUser() = %q, want empty (must not choose randomly)", user)
		}
	})

	t.Run("unattended logon screen fallback", func(t *testing.T) {
		enumerateInteractiveSessions = func() ([]InteractiveSession, error) {
			return nil, nil
		}
		origConsole := getActiveConsoleSessionID
		defer func() { getActiveConsoleSessionID = origConsole }()
		getActiveConsoleSessionID = func() uint32 { return 1 }

		// Attended should fail with no active user
		sess, _, err := ResolveTargetSession(false)
		if sess != nil || !errors.Is(err, ErrNoActiveInteractiveUser) {
			t.Fatalf("attended: got sess=%v, err=%v, want ErrNoActiveInteractiveUser", sess, err)
		}

		// Unattended should resolve console session at default desktop (persistent across logon)
		sess, desktop, err := ResolveTargetSession(true)
		if err != nil || sess == nil || sess.SessionID != 1 || desktop != `winsta0\default` {
			t.Fatalf("unattended: got sess=%v, desktop=%q, err=%v, want SessionID=1, winsta0\\default", sess, desktop, err)
		}
	})
}
