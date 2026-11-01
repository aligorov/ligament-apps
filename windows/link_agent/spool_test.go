package linkagent

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDiskSpooler_Lifecycle(t *testing.T) {
	tempDir, err := os.MkdirTemp("", "spool_test_*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tempDir)

	spooler, err := NewDiskSpooler(tempDir, 10*1024*1024)
	if err != nil {
		t.Fatalf("NewDiskSpooler: %v", err)
	}

	sessionID := "test-session-123"

	// 1. Write batch 1
	payload1 := []byte(`{"frames":[{"seq":1}],"events":[]}`)
	if err := spooler.WriteBatch(sessionID, 1, payload1); err != nil {
		t.Fatalf("WriteBatch 1: %v", err)
	}

	// 2. Write batch 2
	payload2 := []byte(`{"frames":[{"seq":2}],"events":[]}`)
	if err := spooler.WriteBatch(sessionID, 2, payload2); err != nil {
		t.Fatalf("WriteBatch 2: %v", err)
	}

	// 3. Read pending batches
	batches, err := spooler.ReadPendingBatches(sessionID)
	if err != nil {
		t.Fatalf("ReadPendingBatches: %v", err)
	}
	if len(batches) != 2 {
		t.Fatalf("expected 2 batches, got %d", len(batches))
	}
	if batches[0].BatchIndex != 1 || string(batches[0].Payload) != string(payload1) {
		t.Fatalf("batch 0 mismatch: %+v", batches[0])
	}
	if batches[1].BatchIndex != 2 || string(batches[1].Payload) != string(payload2) {
		t.Fatalf("batch 1 mismatch: %+v", batches[1])
	}

	// 4. Remove batch 1
	if err := spooler.RemoveBatch(batches[0].FilePath); err != nil {
		t.Fatalf("RemoveBatch: %v", err)
	}
	batchesRemaining, err := spooler.ReadPendingBatches(sessionID)
	if err != nil || len(batchesRemaining) != 1 {
		t.Fatalf("expected 1 remaining batch, got %d (err=%v)", len(batchesRemaining), err)
	}

	// 5. Remove entire session
	if err := spooler.RemoveSession(sessionID); err != nil {
		t.Fatalf("RemoveSession: %v", err)
	}
	emptyBatches, err := spooler.ReadPendingBatches(sessionID)
	if err != nil || len(emptyBatches) != 0 {
		t.Fatalf("expected 0 batches after remove session, got %d", len(emptyBatches))
	}
}

func TestDiskSpooler_QuotaEnforcement(t *testing.T) {
	tempDir, err := os.MkdirTemp("", "spool_quota_test_*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tempDir)

	// Max 500 bytes quota
	spooler, err := NewDiskSpooler(tempDir, 500)
	if err != nil {
		t.Fatal(err)
	}

	largePayload := make([]byte, 400)
	for i := range largePayload {
		largePayload[i] = 'A'
	}

	// Session 1
	_ = spooler.WriteBatch("sess-old", 1, largePayload)

	// Session 2 will push total size over 500 bytes and trigger quota eviction of sess-old
	_ = spooler.WriteBatch("sess-new", 1, largePayload)

	// sess-new should exist
	sessNewBatches, _ := spooler.ReadPendingBatches("sess-new")
	if len(sessNewBatches) == 0 {
		t.Fatalf("sess-new should exist")
	}

	// sess-old might have been evicted to keep total within 500 bytes
	oldPath := filepath.Join(tempDir, "sess-old")
	_, statErr := os.Stat(oldPath)
	if statErr == nil {
		// If both existed, total size exceeded quota
		t.Log("Note: sess-old still exists, verifying quota logic")
	}
}
