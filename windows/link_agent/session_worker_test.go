package linkagent

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"
)

type fakeSessionWorker struct {
	sent      chan []byte
	responses chan []byte
	closed    chan struct{}
	once      sync.Once
}

func newFakeSessionWorker() *fakeSessionWorker {
	return &fakeSessionWorker{
		sent:      make(chan []byte, 8),
		responses: make(chan []byte, 8),
		closed:    make(chan struct{}),
	}
}

func (p *fakeSessionWorker) Send(ctx context.Context, frame []byte) error {
	select {
	case <-p.closed:
		return errors.New("worker closed")
	case <-ctx.Done():
		return ctx.Err()
	case p.sent <- append([]byte(nil), frame...):
		return nil
	}
}

func (p *fakeSessionWorker) Receive(ctx context.Context) ([]byte, error) {
	select {
	case <-p.closed:
		return nil, errors.New("worker closed")
	case <-ctx.Done():
		return nil, ctx.Err()
	case frame := <-p.responses:
		return append([]byte(nil), frame...), nil
	}
}

func (p *fakeSessionWorker) Close() error {
	p.once.Do(func() { close(p.closed) })
	return nil
}

type fakeSessionWorkerLauncher struct {
	process *fakeSessionWorker
	started chan SessionOffer
	gate    <-chan struct{}
}

func (l *fakeSessionWorkerLauncher) Launch(ctx context.Context, offer SessionOffer, _ []byte) (SessionWorkerProcess, error) {
	select {
	case l.started <- offer:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	if l.gate != nil {
		select {
		case <-l.gate:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return l.process, nil
}

func TestSessionWorkerBrokerRoutesOfferSignalsAndAnswer(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	process := newFakeSessionWorker()
	launcher := &fakeSessionWorkerLauncher{process: process, started: make(chan SessionOffer, 2)}
	broker := NewSessionWorkerBroker(launcher)
	answers := make(chan json.RawMessage, 2)
	accepted, err := json.Marshal(map[string]any{
		"type": "session_offer",
		"payload": map[string]any{
			"session_id": testSessionID, "operator_id": testOperatorID,
			"access_type": "attended", "access_mode": "control",
			"sdp": "v=0 offer", "ice_servers": []any{}, "dlp": map[string]any{},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	send := func(message any) error {
		frame, ok := message.(json.RawMessage)
		if !ok {
			return errors.New("unexpected response type")
		}
		answers <- append(json.RawMessage(nil), frame...)
		return nil
	}
	if err := broker.Handler(ctx, accepted, send); err != nil {
		t.Fatal(err)
	}
	select {
	case offer := <-launcher.started:
		if offer.SessionID != testSessionID || offer.AccessMode != "control" {
			t.Fatalf("unexpected worker offer: %+v", offer)
		}
	case <-time.After(time.Second):
		t.Fatal("worker launch not requested")
	}

	select {
	case <-time.After(time.Second):
	case <-process.closed:
		t.Fatal("worker closed before it was ready")
	default:
	}
	if err := broker.Handler(ctx, []byte(`{"type":"signal","session_id":"`+testSessionID+`","signal":{"candidate":{"candidate":"candidate:1"}}}`), send); err != nil {
		t.Fatal(err)
	}
	select {
	case raw := <-process.sent:
		var frame Envelope
		if err := json.Unmarshal(raw, &frame); err != nil || frame.Type != "signal" || frame.SessionID != testSessionID {
			t.Fatalf("unexpected worker signal: %s (%v)", raw, err)
		}
	case <-time.After(time.Second):
		t.Fatal("signal was not routed to worker")
	}

	answer, _ := MarshalSessionAnswer(testSessionID, true, "", "v=0 answer")
	process.responses <- answer
	select {
	case raw := <-answers:
		var frame Envelope
		if err := json.Unmarshal(raw, &frame); err != nil || frame.Type != "session_answer" || frame.SessionID != testSessionID {
			t.Fatalf("unexpected agent response: %s (%v)", raw, err)
		}
	case <-time.After(time.Second):
		t.Fatal("worker answer was not sent to WSS")
	}

	if err := broker.Handler(ctx, []byte(`{"type":"session_close","session_id":"`+testSessionID+`"}`), send); err != nil {
		t.Fatal(err)
	}
	select {
	case <-process.closed:
	case <-time.After(time.Second):
		t.Fatal("session close did not stop worker")
	}
}

func TestSessionWorkerBrokerQueuesSignalsWhileWorkerLaunches(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	gate := make(chan struct{})
	process := newFakeSessionWorker()
	launcher := &fakeSessionWorkerLauncher{
		process: process, started: make(chan SessionOffer, 1), gate: gate,
	}
	broker := NewSessionWorkerBroker(launcher)
	noop := func(any) error { return nil }
	offer := []byte(`{"type":"session_offer","payload":{"session_id":"` + testSessionID + `","operator_id":"` + testOperatorID + `","access_type":"attended","access_mode":"view","sdp":"v=0","ice_servers":[],"dlp":{}}}`)
	if err := broker.Handler(ctx, offer, noop); err != nil {
		t.Fatal(err)
	}
	select {
	case <-launcher.started:
	case <-time.After(time.Second):
		t.Fatal("worker launch not entered")
	}
	queued := []byte(`{"type":"signal","session_id":"` + testSessionID + `","signal":{"candidate":{"candidate":"candidate:early"}}}`)
	if err := broker.Handler(ctx, queued, noop); err != nil {
		t.Fatal(err)
	}
	close(gate)
	select {
	case raw := <-process.sent:
		if string(raw) != string(queued) {
			t.Fatalf("queued worker frame = %s, want %s", raw, queued)
		}
	case <-time.After(time.Second):
		t.Fatal("queued signal was not flushed after worker start")
	}
	broker.stop(testSessionID)
}

func TestSessionWorkerBrokerFailsClosedWithoutLauncher(t *testing.T) {
	broker := NewSessionWorkerBroker(nil)
	var got json.RawMessage
	err := broker.Handler(context.Background(), []byte(`{"type":"session_offer","payload":{"session_id":"`+testSessionID+`","operator_id":"`+testOperatorID+`","access_type":"attended","access_mode":"view","sdp":"v=0","ice_servers":[],"dlp":{}}}`), func(message any) error {
		var ok bool
		got, ok = message.(json.RawMessage)
		if !ok {
			return errors.New("unexpected response type")
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	var envelope struct {
		Type    string `json:"type"`
		Payload struct {
			Accepted bool   `json:"accepted"`
			Reason   string `json:"reason"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(got, &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope.Type != "session_answer" || envelope.Payload.Accepted || envelope.Payload.Reason != "host_worker_unavailable" {
		t.Fatalf("unexpected fail-closed response: %s", got)
	}
}

func TestValidWorkerResponseAllowsOnlyScopedLocalDisconnect(t *testing.T) {
	valid := []byte(`{"type":"session_terminate","session_id":"` + testSessionID + `","payload":{"session_id":"` + testSessionID + `","reason":"host_local_disconnect"}}`)
	if !validWorkerResponse(valid, testSessionID) {
		t.Fatal("expected scoped host-local disconnect to be accepted")
	}
	wrongSession := []byte(`{"type":"session_terminate","session_id":"` + testOperatorID + `","payload":{"session_id":"` + testOperatorID + `","reason":"host_local_disconnect"}}`)
	if validWorkerResponse(wrongSession, testSessionID) {
		t.Fatal("accepted disconnect outside the worker session scope")
	}
	wrongReason := []byte(`{"type":"session_terminate","session_id":"` + testSessionID + `","payload":{"session_id":"` + testSessionID + `","reason":"revoke_other_session"}}`)
	if validWorkerResponse(wrongReason, testSessionID) {
		t.Fatal("accepted a worker termination reason other than local disconnect")
	}
}
