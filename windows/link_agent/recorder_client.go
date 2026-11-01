package linkagent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// RecorderClientConfig holds ingest endpoint details and compliance policies.
type RecorderClientConfig struct {
	SessionID     string
	IngestURL     string
	IngestToken   string
	Epoch         int64
	LeaseTTL      time.Duration
	MaxBatchBytes int
	MaxQueueBytes int
	FailurePolicy string // "resilient" (default) or "strict"
	Spooler       *DiskSpooler
	HTTPClient    *http.Client
}

// RecordedFrame represents a single captured screen frame for the ingest protocol.
type RecordedFrame struct {
	Seq           int64  `json:"seq"`
	FrameKind     string `json:"frame_kind"` // "periodic", "activity", "keyframe", "gap_marker"
	MonitorID     string `json:"monitor_id"`
	Width         int    `json:"width"`
	Height        int    `json:"height"`
	Codec         string `json:"codec"` // "jpeg", "webp", "png"
	PayloadBase64 string `json:"payload_base64"`
	CapturedAt    string `json:"captured_at"`
	WindowTitle   string `json:"window_title,omitempty"`
	ProcessName   string `json:"process_name,omitempty"`
}

// RecordedEvent represents a user interaction or OS lifecycle event in the session.
type RecordedEvent struct {
	Seq        int64          `json:"seq"`
	EventKind  string         `json:"event_kind"` // "focus_change", "lock", "unlock", "logon", "logoff"
	OccurredAt string         `json:"occurred_at"`
	Payload    map[string]any `json:"payload,omitempty"`
}

// BatchACK represents the server response after ingesting a batch.
type BatchACK struct {
	SessionID           string `json:"session_id"`
	Epoch               int64  `json:"epoch"`
	AckHighWatermarkSeq int64  `json:"ack_high_watermark_seq"`
	FirstFrameAcked     bool   `json:"first_frame_acked"`
	LeaseExpiresAt      string `json:"lease_expires_at"`
	LeaseTTLMs          int64  `json:"lease_ttl_ms"`
	FramesCommitted     int    `json:"frames_committed"`
	EventsCommitted     int    `json:"events_committed"`
	Status              string `json:"status"`
}

// RecorderClient implements the Ligament Link/RDS Recorder Ingest protocol in pure Go.
type RecorderClient struct {
	cfg        RecorderClientConfig
	httpClient *http.Client

	seqCounter atomic.Int64
	spoolIndex atomic.Int64
	ackedSeq   atomic.Int64

	mu            sync.Mutex
	pendingFrames []RecordedFrame
	pendingEvents []RecordedEvent
	queuedBytes   int

	lastAckAt time.Time
	startedAt time.Time
	closed    bool
}

// NewRecorderClient initializes a new Recorder Ingest client.
func NewRecorderClient(cfg RecorderClientConfig) (*RecorderClient, error) {
	if cfg.SessionID == "" {
		return nil, errors.New("recorder client: missing session_id")
	}
	if cfg.IngestURL == "" {
		return nil, errors.New("recorder client: missing ingest_url")
	}
	if cfg.Epoch <= 0 {
		cfg.Epoch = 1
	}
	if cfg.LeaseTTL <= 0 {
		cfg.LeaseTTL = 60 * time.Second
	}
	if cfg.MaxBatchBytes <= 0 {
		cfg.MaxBatchBytes = 2 * 1024 * 1024 // 2 MB
	}
	if cfg.MaxQueueBytes <= 0 {
		cfg.MaxQueueBytes = 64 * 1024 * 1024 // 64 MB
	}
	if cfg.FailurePolicy == "" {
		cfg.FailurePolicy = "resilient"
	}
	client := cfg.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}

	rc := &RecorderClient{
		cfg:           cfg,
		httpClient:    client,
		pendingFrames: make([]RecordedFrame, 0, 32),
		pendingEvents: make([]RecordedEvent, 0, 32),
		startedAt:     time.Now().UTC(),
	}
	return rc, nil
}

// NextSeq returns the next monotonically increasing sequence number.
func (c *RecorderClient) NextSeq() int64 {
	return c.seqCounter.Add(1)
}

// EnqueueFrame appends a captured frame to the outgoing queue.
func (c *RecorderClient) EnqueueFrame(frame RecordedFrame) bool {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed {
		return false
	}

	if frame.Seq <= 0 {
		frame.Seq = c.NextSeq()
	}
	if frame.MonitorID == "" {
		frame.MonitorID = "primary"
	}
	if frame.CapturedAt == "" {
		frame.CapturedAt = time.Now().UTC().Format(time.RFC3339Nano)
	}

	approxSize := len(frame.PayloadBase64) + len(frame.WindowTitle) + len(frame.ProcessName) + 128
	if c.queuedBytes+approxSize > c.cfg.MaxQueueBytes {
		// Queue full - in resilient mode drop non-essential periodic frames; in strict return false
		if frame.FrameKind == "periodic" {
			return false
		}
	}

	c.pendingFrames = append(c.pendingFrames, frame)
	c.queuedBytes += approxSize
	return true
}

// EnqueueEvent appends an audit event to the outgoing queue.
func (c *RecorderClient) EnqueueEvent(event RecordedEvent) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed {
		return
	}

	if event.Seq <= 0 {
		event.Seq = c.NextSeq()
	}
	if event.OccurredAt == "" {
		event.OccurredAt = time.Now().UTC().Format(time.RFC3339Nano)
	}

	c.pendingEvents = append(c.pendingEvents, event)
	c.queuedBytes += 256
}

// IsThrottled returns true if the memory queue exceeds 50% capacity.
func (c *RecorderClient) IsThrottled() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.queuedBytes >= c.cfg.MaxQueueBytes/2
}

// Flush builds a batch of pending items and attempts to send it to the Recorder.
// If sending fails and Spooler is configured, it spills the batch to disk.
func (c *RecorderClient) Flush(ctx context.Context) error {
	c.mu.Lock()
	if len(c.pendingFrames) == 0 && len(c.pendingEvents) == 0 {
		c.mu.Unlock()
		// Check if there are spooled batches to drain
		return c.drainSpool(ctx)
	}

	// Build batch within MaxBatchBytes limit
	batchFrames := make([]RecordedFrame, 0, len(c.pendingFrames))
	batchEvents := make([]RecordedEvent, 0, len(c.pendingEvents))
	currentBytes := 128
	framesToDrop := 0
	eventsToDrop := 0

	for _, f := range c.pendingFrames {
		fSize := len(f.PayloadBase64) + 128
		if len(batchFrames) > 0 && currentBytes+fSize > c.cfg.MaxBatchBytes {
			break
		}
		batchFrames = append(batchFrames, f)
		currentBytes += fSize
		framesToDrop++
	}

	for _, e := range c.pendingEvents {
		eSize := 256
		if len(batchEvents) > 0 && currentBytes+eSize > c.cfg.MaxBatchBytes {
			break
		}
		batchEvents = append(batchEvents, e)
		currentBytes += eSize
		eventsToDrop++
	}

	c.pendingFrames = c.pendingFrames[framesToDrop:]
	c.pendingEvents = c.pendingEvents[eventsToDrop:]
	c.queuedBytes -= currentBytes
	if c.queuedBytes < 0 {
		c.queuedBytes = 0
	}
	c.mu.Unlock()

	batchPayload := map[string]any{
		"session_id":        c.cfg.SessionID,
		"epoch":             c.cfg.Epoch,
		"lease_ttl_seconds": int(c.cfg.LeaseTTL.Seconds()),
		"frames":            batchFrames,
		"events":            batchEvents,
	}

	body, err := json.Marshal(batchPayload)
	if err != nil {
		return fmt.Errorf("recorder client: marshal batch: %w", err)
	}

	// Attempt direct HTTP POST
	ack, sendErr := c.postBatchHTTP(ctx, body)
	if sendErr == nil {
		c.lastAckAt = time.Now().UTC()
		if ack.AckHighWatermarkSeq > c.ackedSeq.Load() {
			c.ackedSeq.Store(ack.AckHighWatermarkSeq)
		}
		// Successfully sent live batch - now drain any previous spooled batches
		_ = c.drainSpool(ctx)
		return nil
	}

	// Network / HTTP error occurred
	if c.cfg.Spooler != nil {
		spoolIdx := c.spoolIndex.Add(1)
		spoolErr := c.cfg.Spooler.WriteBatch(c.cfg.SessionID, spoolIdx, body)
		if spoolErr == nil {
			// Spooled successfully to disk
			return nil
		}
	}

	if c.cfg.FailurePolicy == "strict" {
		return fmt.Errorf("recorder client: send batch failed (strict mode): %w", sendErr)
	}

	// Resilient mode: keep going even if network is down
	return nil
}

func (c *RecorderClient) postBatchHTTP(ctx context.Context, body []byte) (*BatchACK, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.cfg.IngestURL, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.cfg.IngestToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.cfg.IngestToken)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	respBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("recorder HTTP %d: %s", resp.StatusCode, string(respBytes))
	}

	var ack BatchACK
	if err := json.Unmarshal(respBytes, &ack); err != nil {
		// If 200 OK but body format is different (e.g. Core resilient synthetic ACK), provide fallback
		ack = BatchACK{
			SessionID: c.cfg.SessionID,
			Epoch:     c.cfg.Epoch,
			Status:    "ok",
		}
	}
	return &ack, nil
}

func (c *RecorderClient) drainSpool(ctx context.Context) error {
	if c.cfg.Spooler == nil {
		return nil
	}
	batches, err := c.cfg.Spooler.ReadPendingBatches(c.cfg.SessionID)
	if err != nil || len(batches) == 0 {
		return err
	}

	for _, b := range batches {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		ack, err := c.postBatchHTTP(ctx, b.Payload)
		if err != nil {
			// Still unreachable - stop draining for now
			return err
		}
		if ack != nil && ack.AckHighWatermarkSeq > c.ackedSeq.Load() {
			c.ackedSeq.Store(ack.AckHighWatermarkSeq)
		}
		_ = c.cfg.Spooler.RemoveBatch(b.FilePath)
	}
	return nil
}

// Complete notifies Recorder that the session has ended and flushes all remaining items.
func (c *RecorderClient) Complete(ctx context.Context, status, reason string) error {
	c.mu.Lock()
	c.closed = true
	c.mu.Unlock()

	// Flush whatever remains in memory
	_ = c.Flush(ctx)

	// Drain any remaining spooled batches
	_ = c.drainSpool(ctx)

	completeURL := strings.Replace(c.cfg.IngestURL, "/batch", "/complete", 1)
	completePayload := map[string]any{
		"epoch":  c.cfg.Epoch,
		"status": status,
		"reason": reason,
	}
	body, _ := json.Marshal(completePayload)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, completeURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.cfg.IngestToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.cfg.IngestToken)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if c.cfg.Spooler != nil {
		_ = c.cfg.Spooler.RemoveSession(c.cfg.SessionID)
	}
	return nil
}
