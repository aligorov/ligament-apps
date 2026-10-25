package linkagent

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	agentReadLimit         = 512 * 1024
	agentWriteTimeout      = 10 * time.Second
	agentHeartbeatPeriod   = 25 * time.Second
	agentStablePeriod      = 60 * time.Second
	agentReconnectMin      = time.Second
	agentReconnectMax      = time.Minute
	agentWorkerGracePeriod = 60 * time.Second
)

var ErrAgentUnbound = errors.New("link agent: server archived this identity")

// AgentWSConfig contains the enrolled identity and non-secret host metadata.
type AgentWSConfig struct {
	ServerURL       string
	Identity        *Identity
	Hostname        string
	OSFamily        string
	OSVersion       string
	AgentVersion    string
	Capabilities    map[string]any
	InteractiveUser func() string
	LocalIPs        func() []string
	DeleteIdentity  func() error
	OnConnected     func(send func(any) error)
}

// AgentMessageHandler processes a server text frame. send is safe to call from
// the handler and serializes writes with heartbeat frames.
type AgentMessageHandler func(ctx context.Context, message []byte, send func(any) error) error

type agentSocket interface {
	ReadMessage() (int, []byte, error)
	WriteJSON(any) error
	SetWriteDeadline(time.Time) error
	WriteControl(int, []byte, time.Time) error
	SetReadLimit(int64)
	Close() error
}

// ConnectAgent opens the server's native WSS endpoint and sends AgentHello as
// the first application frame, as required by internal/api.LinkAPI.
func ConnectAgent(ctx context.Context, config AgentWSConfig, dialer *websocket.Dialer) (*websocket.Conn, error) {
	endpoint, err := agentWebSocketEndpoint(config.ServerURL)
	if err != nil {
		return nil, err
	}
	if err := validateAgentWSConfig(config); err != nil {
		return nil, err
	}
	if dialer == nil {
		dialer = websocket.DefaultDialer
	}
	dialerCopy := *dialer
	if dialerCopy.HandshakeTimeout <= 0 {
		dialerCopy.HandshakeTimeout = 15 * time.Second
	}
	// No implicit proxy/environment configuration: deployment settings are
	// explicit and the agent's control path is an outbound TLS connection.
	dialerCopy.Proxy = nil
	conn, response, err := dialerCopy.DialContext(ctx, endpoint, http.Header{})
	if err != nil {
		if response != nil && response.Body != nil {
			response.Body.Close()
		}
		return nil, fmt.Errorf("link agent: WSS connection failed: %w", err)
	}
	conn.SetReadLimit(agentReadLimit)
	hello, err := NewHello(config.Identity.AgentID, config.Hostname, config.OSFamily,
		config.OSVersion, config.AgentVersion, config.Capabilities,
		config.Identity.PrivateKey, time.Now().Add(config.Identity.ServerTimeOffset))
	if err != nil {
		conn.Close()
		return nil, err
	}
	if err := conn.SetWriteDeadline(time.Now().Add(agentWriteTimeout)); err != nil {
		conn.Close()
		return nil, fmt.Errorf("link agent: set handshake write deadline: %w", err)
	}
	if err := conn.WriteJSON(hello); err != nil {
		conn.Close()
		return nil, fmt.Errorf("link agent: send signed hello: %w", err)
	}
	if err := conn.SetWriteDeadline(time.Time{}); err != nil {
		conn.Close()
		return nil, fmt.Errorf("link agent: clear handshake write deadline: %w", err)
	}
	return conn, nil
}

// RunAgent maintains the outbound WSS connection and retries failures using
// bounded exponential backoff with jitter. It returns only when ctx is canceled.
func RunAgent(ctx context.Context, config AgentWSConfig, dialer *websocket.Dialer, handler AgentMessageHandler, reportError func(error)) error {
	if handler == nil {
		return errors.New("link agent: nil server-message handler")
	}
	var (
		attempt       int
		workerCtx     context.Context
		cancelWorkers context.CancelFunc
		graceTimer    *time.Timer
	)
	ensureWorkerScope := func() context.Context {
		if graceTimer != nil {
			graceTimer.Stop()
			graceTimer = nil
		}
		if workerCtx == nil || workerCtx.Err() != nil {
			workerCtx, cancelWorkers = context.WithCancel(ctx)
		}
		return workerCtx
	}
	defer func() {
		if graceTimer != nil {
			graceTimer.Stop()
		}
		if cancelWorkers != nil {
			cancelWorkers()
		}
	}()

	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		started := time.Now()
		conn, err := ConnectAgent(ctx, config, dialer)
		if err == nil {
			scopeCtx := ensureWorkerScope()
			err = serveAgentConnectionWithWorkerScope(ctx, scopeCtx, conn, config, handler, reportError)
			_ = conn.Close()
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if errors.Is(err, ErrAgentUnbound) {
			return err
		}
		if cancelWorkers != nil && graceTimer == nil {
			cancelFn := cancelWorkers
			graceTimer = time.AfterFunc(agentWorkerGracePeriod, cancelFn)
		}
		if reportError != nil && err != nil {
			reportError(err)
		}
		if time.Since(started) >= agentStablePeriod {
			attempt = 0
		}
		delay := nextReconnectDelay(attempt)
		if attempt < 16 {
			attempt++
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

func serveAgentConnection(ctx context.Context, conn agentSocket, config AgentWSConfig, handler AgentMessageHandler) error {
	return serveAgentConnectionWithWorkerScope(ctx, nil, conn, config, handler, nil)
}

func serveAgentConnectionWithWorkerScope(ctx context.Context, workerScopeCtx context.Context, conn agentSocket, config AgentWSConfig, handler AgentMessageHandler, reportError func(error)) error {
	defer conn.Close()
	connectionCtx, cancelConnection := context.WithCancel(ctx)
	defer cancelConnection()
	if workerScopeCtx == nil {
		workerScopeCtx = connectionCtx
	}
	writeMu := &sync.Mutex{}
	send := func(message any) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		if err := conn.SetWriteDeadline(time.Now().Add(agentWriteTimeout)); err != nil {
			return err
		}
		return conn.WriteJSON(message)
	}
	type readResult struct {
		messageType int
		payload     []byte
		err         error
	}
	readCh := make(chan readResult, 1)
	go func() {
		for {
			messageType, payload, err := conn.ReadMessage()
			select {
			case readCh <- readResult{messageType: messageType, payload: payload, err: err}:
			case <-connectionCtx.Done():
				return
			}
			if err != nil {
				return
			}
		}
	}()
	stopCloser := make(chan struct{})
	go func() {
		select {
		case <-connectionCtx.Done():
			_ = conn.WriteControl(websocket.CloseMessage,
				websocket.FormatCloseMessage(websocket.CloseGoingAway, "agent stopping"),
				time.Now().Add(time.Second))
			_ = conn.Close()
		case <-stopCloser:
		}
	}()
	defer close(stopCloser)

	lastAck := time.Now()
	collectInteractiveUser := false
	sendHeartbeat := func() error {
		return send(agentHeartbeatMessage(config, collectInteractiveUser))
	}
	if err := sendHeartbeat(); err != nil {
		return fmt.Errorf("link agent: initial heartbeat failed: %w", err)
	}
	if config.OnConnected != nil {
		config.OnConnected(send)
	}
	heartbeat := time.NewTicker(agentHeartbeatPeriod)
	defer heartbeat.Stop()
	for {
		select {
		case <-connectionCtx.Done():
			return connectionCtx.Err()
		case result := <-readCh:
			if result.err != nil {
				return fmt.Errorf("link agent: WSS read failed: %w", result.err)
			}
			if result.messageType != websocket.TextMessage {
				continue
			}
			var envelope struct {
				Type                   string `json:"type"`
				AgentID                string `json:"agent_id"`
				Status                 string `json:"status"`
				CollectInteractiveUser bool   `json:"collect_interactive_user"`
			}
			decoded := json.Unmarshal(result.payload, &envelope) == nil
			if decoded && envelope.Type == "agent_unbound" && envelope.Status == "archived" && config.Identity != nil && envelope.AgentID == config.Identity.AgentID {
				// Only an authenticated TLS server may trigger destructive local
				// cleanup. Network errors, HTTP and ordinary revocation keep keys.
				endpoint, parseErr := url.Parse(config.ServerURL)
				if parseErr != nil || endpoint.Scheme != "https" {
					return errors.New("link agent: unbind requires authenticated HTTPS")
				}
				return ErrAgentUnbound
			}
			if decoded && envelope.Type == "heartbeat_ack" {
				lastAck = time.Now()
				collectInteractiveUser = envelope.CollectInteractiveUser
				continue
			}
			if err := handler(workerScopeCtx, result.payload, send); err != nil {
				if reportError != nil {
					reportError(fmt.Errorf("link agent: server message handler warning: %w", err))
				}
				continue
			}
		case <-heartbeat.C:
			if time.Since(lastAck) > 2*agentHeartbeatPeriod {
				return errors.New("link agent: server heartbeat acknowledgement timed out")
			}
			if err := sendHeartbeat(); err != nil {
				return fmt.Errorf("link agent: send heartbeat: %w", err)
			}
		}
	}
}

func agentHeartbeatMessage(config AgentWSConfig, collectInteractiveUser bool) map[string]any {
	message := map[string]any{"type": "heartbeat"}
	if config.LocalIPs != nil {
		message["local_ips"] = config.LocalIPs()
	}
	if collectInteractiveUser && config.InteractiveUser != nil {
		message["interactive_user"] = config.InteractiveUser()
	}
	return message
}

func isVirtualAdapter(name string) bool {
	lower := strings.ToLower(name)
	for _, sub := range []string{
		"vethernet", "hyper-v", "wsl", "docker", "tailscale",
		"wireguard", "wg", "tun", "tap", "openvpn", "zerotier",
		"vmnet", "virtual", "vmware", "vbox", "hamachi",
	} {
		if strings.Contains(lower, sub) {
			return true
		}
	}
	return false
}

// CurrentLocalIPs returns bounded, non-loopback interface addresses for host
// inventory, filtering out virtual adapters (Hyper-V, WSL, VPNs).
// The server performs independent validation before persistence.
func CurrentLocalIPs() []string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	addresses := make([]string, 0, 8)
	var ipv4s, ipv6s []string
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		if isVirtualAdapter(iface.Name) {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch value := addr.(type) {
			case *net.IPNet:
				ip = value.IP
			case *net.IPAddr:
				ip = value.IP
			}
			if ip == nil || ip.IsLoopback() || ip.IsUnspecified() || ip.IsLinkLocalUnicast() {
				continue
			}
			if ip.To4() != nil {
				ipv4s = append(ipv4s, ip.String())
			} else {
				ipv6s = append(ipv6s, ip.String())
			}
		}
	}
	addresses = append(addresses, ipv4s...)
	addresses = append(addresses, ipv6s...)
	if len(addresses) > 20 {
		return addresses[:20]
	}
	return addresses
}

func agentWebSocketEndpoint(serverURL string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(serverURL))
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("link agent: WSS server URL must be an https origin without credentials, query, or fragment")
	}
	u.Scheme = "wss"
	u.Path = strings.TrimRight(u.Path, "/") + "/api/v1/link/agent/ws"
	u.RawPath = ""
	return u.String(), nil
}

func validateAgentWSConfig(config AgentWSConfig) error {
	if err := ValidateAgentWSMetadata(config); err != nil {
		return err
	}
	identity := config.Identity
	if identity == nil || !validUUID(identity.AgentID) || len(identity.PublicKey) != ed25519.PublicKeySize || len(identity.PrivateKey) != ed25519.PrivateKeySize {
		return errors.New("link agent: incomplete enrolled identity")
	}
	if !bytes.Equal(identity.PrivateKey[ed25519.SeedSize:], identity.PublicKey) {
		return errors.New("link agent: private key does not match enrolled public key")
	}
	fingerprint := sha256.Sum256(identity.PublicKey)
	if identity.Fingerprint != "" && identity.Fingerprint != hex.EncodeToString(fingerprint[:]) {
		return errors.New("link agent: enrolled key fingerprint mismatch")
	}
	return nil
}

func nextReconnectDelay(attempt int) time.Duration {
	delay := agentReconnectMin
	if attempt > 0 {
		shift := attempt
		if shift > 6 {
			shift = 6
		}
		delay *= time.Duration(1 << shift)
	}
	if delay > agentReconnectMax {
		delay = agentReconnectMax
	}
	// Bounded ±20% jitter avoids synchronized reconnect bursts across agents.
	jitter, err := rand.Int(rand.Reader, big.NewInt(4001))
	if err != nil {
		return delay
	}
	permille := jitter.Int64() - 2000
	delay += time.Duration(int64(delay) * permille / 10000)
	if delay < agentReconnectMin*4/5 {
		return agentReconnectMin * 4 / 5
	}
	if delay > agentReconnectMax {
		return agentReconnectMax
	}
	return delay
}
