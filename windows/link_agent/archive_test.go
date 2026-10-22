package linkagent

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestArchivedIdentityCleanupRequiresAuthenticatedServer(t *testing.T) {
	for _, test := range []struct {
		name, status        string
		sameID, wantDeleted bool
	}{
		{"archive", "archived", true, true},
		{"ordinary-revoke", "revoked", true, false},
		{"wrong-agent", "archived", false, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			identity := testAgentIdentity(t)
			expectedPubKey := append([]byte(nil), identity.PublicKey...)
			id := identity.AgentID
			if !test.sameID {
				id = "00000000-0000-0000-0000-000000000000"
			}
			upgrader := websocket.Upgrader{}
			doneHandler := make(chan struct{})
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				defer close(doneHandler)
				conn, err := upgrader.Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer conn.Close()
				var hello Hello
				if err := conn.ReadJSON(&hello); err != nil {
					return
				}
				if !VerifyHello(hello, expectedPubKey) {
					t.Error("invalid hello")
					return
				}
				_ = conn.WriteJSON(map[string]string{"type": "agent_unbound", "agent_id": id, "status": test.status})
				// Read until client exits, avoiding racing its initial heartbeat.
				_ = conn.SetReadDeadline(time.Now().Add(time.Second))
				for {
					if _, _, err := conn.ReadMessage(); err != nil {
						return
					}
				}
			}))
			defer func() {
				server.Close()
				select {
				case <-doneHandler:
				case <-time.After(time.Second):
				}
			}()
			dialer := &websocket.Dialer{TLSClientConfig: server.Client().Transport.(*http.Transport).TLSClientConfig}
			deleted := false
			config := AgentConfig(server.URL, "TEST-PC", "windows", "11", "test", nil)
			config.DeleteIdentity = func() error { deleted = true; return nil }
			ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
			defer cancel()
			err := RunStoredAgent(ctx, config, func() (*Identity, error) { return identity, nil }, dialer, func(context.Context, []byte, func(any) error) error { return nil }, nil)
			if deleted != test.wantDeleted {
				t.Fatalf("deleted=%v err=%v", deleted, err)
			}
			if test.wantDeleted && !errors.Is(err, ErrAgentUnbound) {
				t.Fatalf("terminal error=%v", err)
			}
		})
	}
}

func TestNetworkFailureDoesNotDeleteIdentity(t *testing.T) {
	identity := testAgentIdentity(t)
	config := AgentConfig("https://127.0.0.1:1", "TEST-PC", "macos", "15", "test", nil)
	config.DeleteIdentity = func() error { t.Fatal("network failure deleted identity"); return nil }
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if err := RunStoredAgent(ctx, config, func() (*Identity, error) { return identity, nil }, nil, func(context.Context, []byte, func(any) error) error { return nil }, nil); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error=%v", err)
	}
}
