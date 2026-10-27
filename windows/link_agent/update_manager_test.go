package linkagent

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestUpdateManager_StageAndApply(t *testing.T) {
	tempDir, err := os.MkdirTemp("", "linkagent-update-test-*")
	if err != nil {
		t.Fatalf("MkdirTemp failed: %v", err)
	}
	defer os.RemoveAll(tempDir)

	payload := []byte("dummy msi binary content for testing")
	hasher := sha256.New()
	hasher.Write(payload)
	payloadSHA := hex.EncodeToString(hasher.Sum(nil))

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/x-msi")
		_, _ = w.Write(payload)
	}))
	defer srv.Close()

	mgr := NewUpdateManager(tempDir)

	var lastStatus string
	var lastVersion string
	var lastErr string

	send := func(msg any) error {
		if m, ok := msg.(map[string]any); ok {
			if p, ok := m["payload"].(map[string]any); ok {
				lastStatus, _ = p["status"].(string)
				lastVersion, _ = p["version"].(string)
				lastErr, _ = p["error"].(string)
			}
		}
		return nil
	}

	ctx := context.Background()

	// 1. Stage with valid SHA
	err = mgr.StageUpdate(ctx, srv.URL, "/package.msi", "1.2.0", payloadSHA, send)
	if err != nil {
		t.Fatalf("StageUpdate failed: %v", err)
	}
	if lastStatus != "staged" || lastVersion != "1.2.0" {
		t.Errorf("expected staged 1.2.0, got %s %s", lastStatus, lastVersion)
	}

	expectedFile := filepath.Join(tempDir, "ligament_1.2.0.msi")
	if _, err := os.Stat(expectedFile); err != nil {
		t.Errorf("expected staged file at %s, got err: %v", expectedFile, err)
	}

	// 2. Stage with invalid SHA
	err = mgr.StageUpdate(ctx, srv.URL, "/package.msi", "1.2.1", "badhash", send)
	if err == nil {
		t.Fatalf("expected error on SHA mismatch, got nil")
	}
	if lastStatus != "failed" || lastErr == "" {
		t.Errorf("expected failed status with error, got status=%s err=%s", lastStatus, lastErr)
	}

	// 3. Apply staged update
	err = mgr.ApplyUpdate(ctx, srv.URL, "/package.msi", "1.2.0", 1, send)
	if err != nil {
		t.Fatalf("ApplyUpdate failed: %v", err)
	}
	if lastStatus != "applying" {
		t.Errorf("expected status applying, got %s", lastStatus)
	}
}
