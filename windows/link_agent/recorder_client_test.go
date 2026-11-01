package linkagent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
)

func TestRecorderClient_DirectFlush(t *testing.T) {
	var batchesReceived atomic.Int64

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/batch" {
			batchesReceived.Add(1)
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(BatchACK{
				SessionID:           "test-sess",
				AckHighWatermarkSeq: 10,
				Status:              "ok",
			})
			return
		}
		if r.URL.Path == "/complete" {
			w.WriteHeader(http.StatusOK)
			return
		}
		http.NotFound(w, r)
	}))
	defer ts.Close()

	client, err := NewRecorderClient(RecorderClientConfig{
		SessionID:  "test-sess",
		IngestURL:  ts.URL + "/batch",
		HTTPClient: ts.Client(),
	})
	if err != nil {
		t.Fatal(err)
	}

	client.EnqueueFrame(RecordedFrame{
		Seq:           1,
		Codec:         "jpeg",
		PayloadBase64: "aGVsbG8=",
	})
	client.EnqueueEvent(RecordedEvent{
		Seq:       2,
		EventType: "focus_change",
	})

	ctx := context.Background()
	if err := client.Flush(ctx); err != nil {
		t.Fatalf("Flush: %v", err)
	}

	if batchesReceived.Load() != 1 {
		t.Fatalf("expected 1 batch, got %d", batchesReceived.Load())
	}

	if err := client.Complete(ctx, "completed", "user_logout"); err != nil {
		t.Fatalf("Complete: %v", err)
	}
}

func TestRecorderClient_SpoolFallbackAndDrain(t *testing.T) {
	tempDir, err := os.MkdirTemp("", "rec_spool_*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tempDir)

	spooler, err := NewDiskSpooler(tempDir, 10*1024*1024)
	if err != nil {
		t.Fatal(err)
	}

	var shouldFail atomic.Bool
	shouldFail.Store(true)
	var successfulBatches atomic.Int64

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if shouldFail.Load() {
			http.Error(w, "server unavailable", http.StatusServiceUnavailable)
			return
		}
		if r.URL.Path == "/batch" {
			successfulBatches.Add(1)
			_ = json.NewEncoder(w).Encode(BatchACK{
				SessionID:           "sess-spool",
				AckHighWatermarkSeq: 5,
				Status:              "ok",
			})
			return
		}
		if r.URL.Path == "/complete" {
			w.WriteHeader(http.StatusOK)
			return
		}
	}))
	defer ts.Close()

	client, err := NewRecorderClient(RecorderClientConfig{
		SessionID:     "sess-spool",
		IngestURL:     ts.URL + "/batch",
		FailurePolicy: "resilient",
		Spooler:       spooler,
		HTTPClient:    ts.Client(),
	})
	if err != nil {
		t.Fatal(err)
	}

	client.EnqueueFrame(RecordedFrame{
		Seq:           1,
		PayloadBase64: "c3Bvb2xNZQ==",
	})

	ctx := context.Background()
	// Flush while server is down -> should spool without fatal error
	if err := client.Flush(ctx); err != nil {
		t.Fatalf("expected graceful resilient flush with spooling, got: %v", err)
	}

	// Verify batch was written to disk
	spooled, err := spooler.ReadPendingBatches("sess-spool")
	if err != nil || len(spooled) != 1 {
		t.Fatalf("expected 1 spooled batch, got %d (err=%v)", len(spooled), err)
	}

	// Now recover server
	shouldFail.Store(false)

	// Flush again with a new frame -> should send both live and spooled batch!
	client.EnqueueFrame(RecordedFrame{
		Seq:           2,
		PayloadBase64: "bGl2ZUZyYW1l",
	})
	if err := client.Flush(ctx); err != nil {
		t.Fatalf("Flush after recovery: %v", err)
	}

	// Disk spool should now be drained (0 batches remaining)
	remaining, _ := spooler.ReadPendingBatches("sess-spool")
	if len(remaining) != 0 {
		t.Fatalf("expected 0 spooled batches after recovery drain, got %d", len(remaining))
	}

	if successfulBatches.Load() != 2 {
		t.Fatalf("expected 2 successful batches (1 live + 1 spooled), got %d", successfulBatches.Load())
	}
}
