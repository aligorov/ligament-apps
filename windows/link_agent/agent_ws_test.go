package linkagent

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestConnectAgentSendsSignedHelloFirst(t *testing.T) {
	identity := testAgentIdentity(t)
	upgrader := websocket.Upgrader{}
	helloCh := make(chan Hello, 1)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/link/agent/ws" {
			t.Errorf("wrong WSS path: %s", r.URL.Path)
			http.NotFound(w, r)
			return
		}
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade: %v", err)
			return
		}
		defer conn.Close()
		_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		var hello Hello
		if err := conn.ReadJSON(&hello); err != nil {
			t.Errorf("read hello: %v", err)
			return
		}
		helloCh <- hello
		_ = conn.WriteJSON(map[string]string{"type": "ready"})
	}))
	defer server.Close()

	httpTransport := server.Client().Transport.(*http.Transport)
	dialer := &websocket.Dialer{
		TLSClientConfig:  httpTransport.TLSClientConfig,
		HandshakeTimeout: 3 * time.Second,
	}
	config := AgentWSConfig{
		ServerURL: server.URL, Identity: identity, Hostname: "WS-01",
		OSFamily: "windows", OSVersion: "11", AgentVersion: "0.1.0",
	}
	conn, err := ConnectAgent(context.Background(), config, dialer)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	select {
	case hello := <-helloCh:
		if hello.AgentID != identity.AgentID || !VerifyHello(hello, identity.PublicKey) {
			t.Fatal("server did not receive a valid signed AgentHello")
		}
	case <-time.After(4 * time.Second):
		t.Fatal("server did not receive AgentHello")
	}
}

func TestAgentWebSocketURLAndReconnectBackoff(t *testing.T) {
	endpoint, err := agentWebSocketEndpoint("https://example.test/ligament/")
	if err != nil || endpoint != "wss://example.test/ligament/api/v1/link/agent/ws" {
		t.Fatalf("unexpected WSS endpoint %q, err=%v", endpoint, err)
	}
	if _, err := agentWebSocketEndpoint("http://example.test"); err == nil {
		t.Fatal("cleartext WebSocket URL must be rejected")
	}
	for attempt := 0; attempt < 10; attempt++ {
		delay := nextReconnectDelay(attempt)
		if delay < agentReconnectMin*4/5 || delay > agentReconnectMax {
			t.Fatalf("reconnect delay outside bounds at attempt %d: %s", attempt, delay)
		}
	}
}

func TestServeAgentConnectionHeartbeatsAndDispatchesServerMessages(t *testing.T) {
	identity := testAgentIdentity(t)
	upgrader := websocket.Upgrader{}
	serverResult := make(chan error, 1)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			serverResult <- err
			return
		}
		defer conn.Close()
		_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		var hello Hello
		if err := conn.ReadJSON(&hello); err != nil {
			serverResult <- err
			return
		}
		var heartbeat map[string]string
		if err := conn.ReadJSON(&heartbeat); err != nil {
			serverResult <- err
			return
		}
		if heartbeat["type"] != "heartbeat" {
			serverResult <- errors.New("expected initial heartbeat")
			return
		}
		if err := conn.WriteJSON(map[string]string{"type": "heartbeat_ack"}); err != nil {
			serverResult <- err
			return
		}
		if err := conn.WriteJSON(map[string]string{"type": "test_event"}); err != nil {
			serverResult <- err
			return
		}
		var response map[string]string
		if err := conn.ReadJSON(&response); err != nil {
			serverResult <- err
			return
		}
		if response["type"] != "test_reply" {
			serverResult <- errors.New("unexpected client reply")
			return
		}
		serverResult <- nil
	}))
	defer server.Close()

	httpTransport := server.Client().Transport.(*http.Transport)
	dialer := &websocket.Dialer{TLSClientConfig: httpTransport.TLSClientConfig}
	conn, err := ConnectAgent(context.Background(), AgentWSConfig{
		ServerURL: server.URL, Identity: identity, Hostname: "WS-01",
		OSFamily: "windows", AgentVersion: "0.1.0",
	}, dialer)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	err = serveAgentConnection(ctx, conn, AgentWSConfig{}, func(_ context.Context, message []byte, send func(any) error) error {
		var event map[string]string
		if err := json.Unmarshal(message, &event); err != nil {
			return err
		}
		if event["type"] != "test_event" {
			return errors.New("unexpected server event")
		}
		return send(map[string]string{"type": "test_reply"})
	})
	if err == nil && ctx.Err() == nil {
		t.Fatal("expected server close or context timeout to end connection")
	}
	select {
	case serverErr := <-serverResult:
		if serverErr != nil {
			t.Fatal(serverErr)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("server did not receive agent reply")
	}
}

func TestAgentHeartbeatCollectsInteractiveUserOnlyWhenServerAllows(t *testing.T) {
	userReads := 0
	config := AgentWSConfig{
		InteractiveUser: func() string {
			userReads++
			return "DOMAIN\\alice"
		},
		LocalIPs: func() []string { return []string{"192.168.1.20"} },
	}
	initial := agentHeartbeatMessage(config, false)
	if _, exists := initial["interactive_user"]; exists || userReads != 0 {
		t.Fatal("agent read or sent the OS username before server policy allowed it")
	}
	if got := initial["local_ips"].([]string); len(got) != 1 || got[0] != "192.168.1.20" {
		t.Fatalf("local IP telemetry = %#v", got)
	}
	allowed := agentHeartbeatMessage(config, true)
	if got := allowed["interactive_user"]; got != "DOMAIN\\alice" || userReads != 1 {
		t.Fatalf("allowed username = %#v, reads=%d", got, userReads)
	}
}

func TestValidateAgentWSConfigRejectsMismatchedIdentity(t *testing.T) {
	config := AgentWSConfig{
		Identity: testAgentIdentity(t), Hostname: "WS-01", OSFamily: "windows", AgentVersion: "0.1.0",
	}
	_, differentPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	config.Identity.PrivateKey = differentPrivate
	if err := validateAgentWSConfig(config); err == nil {
		t.Fatal("expected a mismatched enrolled keypair to be rejected")
	}
}

func testAgentIdentity(t *testing.T) *Identity {
	t.Helper()
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	fingerprint := sha256.Sum256(publicKey)
	return &Identity{
		AgentID:   "10000000-0000-4000-8000-000000000001",
		PublicKey: publicKey, PrivateKey: privateKey,
		Fingerprint: hex.EncodeToString(fingerprint[:]),
	}
}
