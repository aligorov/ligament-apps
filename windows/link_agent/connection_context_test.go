package linkagent

import (
 "context"
 "testing"
 "time"
)

// Regression expectation: losing the authenticated control connection must
// close its desktop worker even when the WebRTC connection remains alive.
func TestAuditWorkerStopsOnConnectionCancellation(t *testing.T) {
 ctx, cancel := context.WithCancel(context.Background())
 defer cancel()
 process := newFakeSessionWorker()
 launcher := &fakeSessionWorkerLauncher{process: process, started: make(chan SessionOffer, 1)}
 broker := NewSessionWorkerBroker(launcher)
 defer broker.stop(testSessionID)
 offer := []byte(`{"type":"session_offer","payload":{"session_id":"` + testSessionID + `","operator_id":"` + testOperatorID + `","access_type":"attended","access_mode":"view","sdp":"v=0","ice_servers":[],"dlp":{}}}`)
 if err := broker.Handler(ctx, offer, func(any) error { return nil }); err != nil { t.Fatal(err) }
 select { case <-launcher.started: case <-time.After(5*time.Second): t.Fatal("worker not started") }
 // A routed signal proves the process has been installed and is receiving IPC.
 signal := []byte(`{"type":"signal","session_id":"` + testSessionID + `","signal":{"candidate":{"candidate":"candidate:audit"}}}`)
 if err := broker.Handler(ctx, signal, func(any) error { return nil }); err != nil { t.Fatal(err) }
 select { case <-process.sent: case <-time.After(5*time.Second): t.Fatal("worker not ready") }
 cancel()
 select {
 case <-process.closed:
 case <-time.After(time.Second): t.Fatal("worker survived cancellation of its WSS connection context")
 }
}

