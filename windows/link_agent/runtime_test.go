package linkagent

import (
	"context"
	"errors"
	"testing"
)

func TestRunStoredAgentLoadsAndClearsIdentityOnStop(t *testing.T) {
	identity := testAgentIdentity(t)
	privateKey := identity.PrivateKey
	publicKey := identity.PublicKey
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	err := RunStoredAgent(ctx, AgentWSConfig{}, func() (*Identity, error) {
		return identity, nil
	}, nil, func(context.Context, []byte, func(any) error) error {
		return nil
	}, nil)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("RunStoredAgent error = %v, want context.Canceled", err)
	}
	if identity.PrivateKey != nil || identity.PublicKey != nil {
		t.Fatal("agent identity keys remain reachable after shutdown")
	}
	for _, b := range privateKey {
		if b != 0 {
			t.Fatal("private-key backing memory was not cleared")
		}
	}
	for _, b := range publicKey {
		if b != 0 {
			t.Fatal("public-key backing memory was not cleared")
		}
	}
}

func TestRunStoredAgentRejectsMissingLoaderAndIdentity(t *testing.T) {
	ctx := context.Background()
	handler := func(context.Context, []byte, func(any) error) error { return nil }
	if err := RunStoredAgent(ctx, AgentWSConfig{}, nil, nil, handler, nil); err == nil {
		t.Fatal("nil identity loader must fail")
	}
	if err := RunStoredAgent(ctx, AgentWSConfig{}, func() (*Identity, error) {
		return nil, nil
	}, nil, handler, nil); err == nil {
		t.Fatal("nil loaded identity must fail")
	}
}

func TestValidateAgentWSMetadataDoesNotNeedLoadedIdentity(t *testing.T) {
	config := StoredAgentConfig("https://core.example.test", "WS-01", "Windows 11", "0.1.0", nil)
	if err := ValidateAgentWSMetadata(config); err != nil {
		t.Fatalf("valid service metadata was rejected before identity loading: %v", err)
	}
	config.ServerURL = "http://core.example.test"
	if err := ValidateAgentWSMetadata(config); err == nil {
		t.Fatal("cleartext server URL must be rejected")
	}
}
