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
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const enrollmentResponseLimit = 1 << 20

// EnrollmentMetadata is sent to POST /api/v1/link/agents/enroll.
type EnrollmentMetadata struct {
	Hostname     string         `json:"hostname"`
	OSFamily     string         `json:"os_family"`
	OSVersion    string         `json:"os_version,omitempty"`
	AgentVersion string         `json:"agent_version"`
	Capabilities map[string]any `json:"capabilities,omitempty"`
	EnclaveType  string         `json:"enclave_type,omitempty"`
	ADOU         string         `json:"ad_ou,omitempty"`
	GroupName    string         `json:"group_name,omitempty"`
	Tags         []string       `json:"tags,omitempty"`
}

// Identity is returned only after the server accepts the public key.
// Callers must persist PrivateKey using the platform's protected key store.
type Identity struct {
	AgentID          string
	PublicKey        ed25519.PublicKey
	PrivateKey       ed25519.PrivateKey
	ServerTimeOffset time.Duration
	Fingerprint      string
}

type enrollmentResponse struct {
	AgentID     string `json:"agent_id"`
	Fingerprint string `json:"fingerprint"`
	Status      string `json:"status"`
	ServerTime  int64  `json:"server_time"`
}

// EnrollAgent creates a fresh Ed25519 identity and enrolls its public key.
// Enrollment tokens are never put in URLs, headers, logs, or redirect requests.
func EnrollAgent(ctx context.Context, serverURL, enrollmentToken string, metadata EnrollmentMetadata, client *http.Client) (*Identity, error) {
	endpoint, err := enrollmentEndpoint(serverURL)
	if err != nil {
		return nil, err
	}
	if err := validateEnrollment(enrollmentToken, metadata); err != nil {
		return nil, err
	}
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("link agent: generate identity: %w", err)
	}
	clearPrivateKey := true
	defer func() {
		if clearPrivateKey {
			clear(privateKey)
		}
	}()

	started := time.Now()
	payload, err := json.Marshal(struct {
		EnrollmentToken string `json:"enrollment_token"`
		PublicKey       string `json:"public_key"`
		EnrollmentMetadata
	}{enrollmentToken, hex.EncodeToString(publicKey), metadata})
	if err != nil {
		return nil, fmt.Errorf("link agent: encode enrollment: %w", err)
	}
	if len(payload) > 64*1024 {
		clear(payload)
		return nil, errors.New("link agent: enrollment request exceeds server limit")
	}
	defer clear(payload)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return nil, fmt.Errorf("link agent: create enrollment request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	if client == nil {
		client = &http.Client{
			Timeout:   15 * time.Second,
			Transport: &http.Transport{Proxy: nil},
		}
	}
	clientCopy := *client
	if clientCopy.Timeout <= 0 {
		clientCopy.Timeout = 15 * time.Second
	}
	// The one-time bearer secret is inside the POST body. Do not let net/http
	// forward that body to a redirect target, even when a caller supplied a client.
	clientCopy.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := clientCopy.Do(req)
	if err != nil {
		return nil, fmt.Errorf("link agent: enrollment request failed: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, enrollmentResponseLimit+1))
	if err != nil {
		return nil, fmt.Errorf("link agent: read enrollment response: %w", err)
	}
	if len(body) > enrollmentResponseLimit {
		return nil, errors.New("link agent: enrollment response exceeds size limit")
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("link agent: enrollment rejected with HTTP %d", resp.StatusCode)
	}
	var result enrollmentResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("link agent: decode enrollment response: %w", err)
	}
	fingerprintSum := sha256.Sum256(publicKey)
	expectedFingerprint := hex.EncodeToString(fingerprintSum[:])
	if !validUUID(result.AgentID) || result.Status != "enrolled" || result.ServerTime <= 0 || result.Fingerprint != expectedFingerprint {
		return nil, errors.New("link agent: incomplete enrollment response")
	}
	finished := time.Now()
	serverTime := time.Unix(result.ServerTime, 0)
	offset := serverTime.Sub(started.Add(finished.Sub(started) / 2))
	identity := &Identity{
		AgentID: result.AgentID, PublicKey: publicKey,
		PrivateKey: privateKey, ServerTimeOffset: offset,
		Fingerprint: result.Fingerprint,
	}
	clearPrivateKey = false
	return identity, nil
}

func enrollmentEndpoint(serverURL string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(serverURL))
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("link agent: enrollment server URL must be an https origin without credentials, query, or fragment")
	}
	u.Path = strings.TrimRight(u.Path, "/") + "/api/v1/link/agents/enroll"
	u.RawPath = ""
	return u.String(), nil
}

// ValidateServerURL verifies a server base URL accepted by both enrollment and
// the agent WSS connection. It never permits cleartext or URL credentials.
func ValidateServerURL(serverURL string) error {
	if _, err := enrollmentEndpoint(serverURL); err != nil {
		return err
	}
	if _, err := agentWebSocketEndpoint(serverURL); err != nil {
		return err
	}
	return nil
}

// ResolveBindingServerURL prevents a user-session app from redirecting a
// machine-configured agent to another server. An unset machine URL is returned
// with persist=true so the service can save it before enrolling the host.
func ResolveBindingServerURL(configuredURL, requestedURL string) (serverURL string, persist bool, err error) {
	requested := strings.TrimRight(strings.TrimSpace(requestedURL), "/")
	if err := ValidateServerURL(requested); err != nil {
		return "", false, err
	}
	configured := strings.TrimRight(strings.TrimSpace(configuredURL), "/")
	if configured == "" {
		return requested, true, nil
	}
	if err := ValidateServerURL(configured); err != nil {
		return "", false, fmt.Errorf("link agent: invalid configured server URL: %w", err)
	}
	if configured != requested {
		return "", false, errors.New("link agent: app server does not match configured machine server")
	}
	return configured, false, nil
}

func validateEnrollment(token string, metadata EnrollmentMetadata) error {
	tokenBytes, err := hex.DecodeString(token)
	if err != nil || len(tokenBytes) != 32 {
		return errors.New("link agent: enrollment token must be 32-byte hex")
	}
	clear(tokenBytes)
	if strings.TrimSpace(metadata.Hostname) == "" || strings.TrimSpace(metadata.AgentVersion) == "" {
		return errors.New("link agent: hostname and agent version are required")
	}
	switch strings.ToLower(strings.TrimSpace(metadata.OSFamily)) {
	case "windows", "linux", "macos":
	default:
		return errors.New("link agent: unsupported OS family")
	}
	return nil
}
