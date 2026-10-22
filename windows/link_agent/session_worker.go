package linkagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
)

const maxQueuedWorkerSignals = 256

// SessionWorkerProcess is the framed IPC endpoint for one interactive desktop
// worker. Implementations must bound frame sizes and unblock Send/Receive on
// context cancellation.
type SessionWorkerProcess interface {
	Send(context.Context, []byte) error
	Receive(context.Context) ([]byte, error)
	Close() error
}

const (
	ReasonHostNoActiveUser       = "host_no_active_user"
	ReasonHostSessionAmbiguous   = "host_session_ambiguous"
	ReasonHostWorkerNotInstalled = "host_worker_not_installed"
	ReasonHostWorkerLaunchFailed = "host_worker_launch_failed"
	ReasonHostWorkerUnavailable  = "host_worker_unavailable"
)

var (
	ErrNoActiveInteractiveUser     = errors.New("link agent: no active interactive user")
	ErrAmbiguousInteractiveSession = errors.New("link agent: ambiguous interactive user sessions")
)

// InteractiveSession holds the identified single active interactive session.
type InteractiveSession struct {
	SessionID uint32
	Username  string
}

// WorkerLaunchError reports a specific safe reason when worker launch fails.
type WorkerLaunchError struct {
	Reason string
	Err    error
}

func (e *WorkerLaunchError) Error() string {
	if e.Err != nil {
		return fmt.Sprintf("link agent: %s: %v", e.Reason, e.Err)
	}
	return "link agent: " + e.Reason
}

func (e *WorkerLaunchError) Unwrap() error {
	return e.Err
}

func classifyWorkerLaunchError(err error) string {
	if err == nil {
		return ""
	}
	var launchErr *WorkerLaunchError
	if errors.As(err, &launchErr) && launchErr.Reason != "" {
		return launchErr.Reason
	}
	return ReasonHostWorkerUnavailable
}

// SessionWorkerLauncher starts a worker in the selected interactive session.
// The initial frame is the validated server offer envelope.
type SessionWorkerLauncher interface {
	Launch(context.Context, SessionOffer, []byte) (SessionWorkerProcess, error)
}

type workerSession struct {
	cancel   context.CancelFunc
	process  SessionWorkerProcess
	outbound chan []byte
}

// SessionWorkerBroker routes WSS session offers/signals to per-session
// interactive workers and returns only session-scoped worker responses.
type SessionWorkerBroker struct {
	launcher SessionWorkerLauncher
	mu       sync.Mutex
	sessions map[string]*workerSession
}

func NewSessionWorkerBroker(launcher SessionWorkerLauncher) *SessionWorkerBroker {
	return &SessionWorkerBroker{
		launcher: launcher,
		sessions: make(map[string]*workerSession),
	}
}

// Handler is an AgentMessageHandler suitable for RunAgent. The connection
// context owns worker processes so a lost WSS connection tears down media.
func (b *SessionWorkerBroker) Handler(ctx context.Context, message []byte, send func(any) error) error {
	var envelope Envelope
	if err := json.Unmarshal(message, &envelope); err != nil {
		return fmt.Errorf("link agent: decode worker envelope: %w", err)
	}
	switch envelope.Type {
	case "session_offer":
		offer, err := DecodeOffer(message)
		if err != nil {
			return err
		}
		return b.start(ctx, offer, message, send)
	case "signal":
		if !validUUID(envelope.SessionID) || len(envelope.Signal) == 0 || !json.Valid(envelope.Signal) {
			return errors.New("link agent: invalid worker signal envelope")
		}
		return b.route(ctx, envelope.SessionID, message)
	case "session_close", "session_revoke", "session_terminate":
		if validUUID(envelope.SessionID) {
			b.stop(envelope.SessionID)
		}
		return nil
	default:
		// Heartbeats and other service-level frames remain owned by RunAgent.
		return nil
	}
}

func (b *SessionWorkerBroker) start(ctx context.Context, offer SessionOffer, frame []byte, send func(any) error) error {
	if b.launcher == nil {
		return sendRejectedAnswer(send, offer.SessionID, ReasonHostWorkerUnavailable)
	}
	workerCtx, cancel := context.WithCancel(ctx)
	session := &workerSession{
		cancel:   cancel,
		outbound: make(chan []byte, maxQueuedWorkerSignals),
	}
	b.mu.Lock()
	if _, exists := b.sessions[offer.SessionID]; exists {
		b.mu.Unlock()
		cancel()
		return nil // Duplicate offer is idempotent; never launch a second desktop worker.
	}
	b.sessions[offer.SessionID] = session
	b.mu.Unlock()

	offerFrame := append([]byte(nil), frame...)
	go b.run(workerCtx, offer, offerFrame, session, send)
	return nil
}

func (b *SessionWorkerBroker) run(ctx context.Context, offer SessionOffer, frame []byte, session *workerSession, send func(any) error) {
	defer clear(frame)
	process, err := b.launcher.Launch(ctx, offer, frame)
	if err != nil {
		reason := classifyWorkerLaunchError(err)
		_ = sendRejectedAnswer(send, offer.SessionID, reason)
		b.remove(offer.SessionID, session)
		return
	}
	b.mu.Lock()
	if b.sessions[offer.SessionID] != session || ctx.Err() != nil {
		b.mu.Unlock()
		_ = process.Close()
		return
	}
	session.process = process
	b.mu.Unlock()

	writerDone := make(chan error, 1)
	go func() {
		for {
			select {
			case <-ctx.Done():
				writerDone <- ctx.Err()
				return
			case signal := <-session.outbound:
				err := process.Send(ctx, signal)
				clear(signal)
				if err != nil {
					writerDone <- err
					return
				}
			}
		}
	}()

	defer b.remove(offer.SessionID, session)
	type readResult struct {
		frame []byte
		err   error
	}
	readResults := make(chan readResult, 1)
	go func() {
		for {
			frame, err := process.Receive(ctx)
			select {
			case readResults <- readResult{frame: frame, err: err}:
			case <-ctx.Done():
				clear(frame)
				return
			}
			if err != nil {
				return
			}
		}
	}()
	for {
		select {
		case <-ctx.Done():
			return
		case err := <-writerDone:
			if err != nil {
				return
			}
		case result := <-readResults:
			if result.err != nil {
				clear(result.frame)
				return
			}
			response := result.frame
			if !validWorkerResponse(response, offer.SessionID) {
				clear(response)
				return
			}
			if err := send(json.RawMessage(response)); err != nil {
				clear(response)
				return
			}
			clear(response)
		}
	}
}

func (b *SessionWorkerBroker) route(ctx context.Context, sessionID string, frame []byte) error {
	b.mu.Lock()
	session := b.sessions[sessionID]
	if session == nil {
		b.mu.Unlock()
		return nil // Offers and stale signals may race over independent WSS frames.
	}
	outbound := session.outbound
	b.mu.Unlock()
	queued := append([]byte(nil), frame...)
	select {
	case outbound <- queued:
		return nil
	case <-ctx.Done():
		clear(queued)
		return ctx.Err()
	default:
		clear(queued)
		b.stop(sessionID)
		return errors.New("link agent: worker signal queue limit exceeded")
	}
}

func (b *SessionWorkerBroker) stop(sessionID string) {
	b.mu.Lock()
	session := b.sessions[sessionID]
	if session != nil {
		delete(b.sessions, sessionID)
	}
	b.mu.Unlock()
	if session == nil {
		return
	}
	session.cancel()
	if session.process != nil {
		_ = session.process.Close()
	}
}

func (b *SessionWorkerBroker) remove(sessionID string, expected *workerSession) {
	b.mu.Lock()
	owned := b.sessions[sessionID] == expected
	if owned {
		delete(b.sessions, sessionID)
	}
	b.mu.Unlock()
	if owned {
		b.stopProcess(expected)
	}
}

func (b *SessionWorkerBroker) stopProcess(session *workerSession) {
	if session == nil {
		return
	}
	session.cancel()
	if session.process != nil {
		_ = session.process.Close()
	}
}

func sendRejectedAnswer(send func(any) error, sessionID, reason string) error {
	answer, err := MarshalSessionAnswer(sessionID, false, reason, "")
	if err != nil {
		return err
	}
	return send(json.RawMessage(answer))
}

func validWorkerResponse(frame []byte, sessionID string) bool {
	if len(frame) == 0 || len(frame) > 512*1024 {
		return false
	}
	var envelope Envelope
	if json.Unmarshal(frame, &envelope) != nil || envelope.SessionID != sessionID {
		return false
	}
	switch envelope.Type {
	case "session_terminate":
		var request struct {
			SessionID string `json:"session_id"`
			Reason    string `json:"reason"`
		}
		return json.Unmarshal(envelope.Payload, &request) == nil &&
			request.SessionID == sessionID && request.Reason == "host_local_disconnect"
	case "session_answer":
		var answer struct {
			SessionID string `json:"session_id"`
			Accepted  bool   `json:"accepted"`
			SDP       string `json:"sdp"`
		}
		return json.Unmarshal(envelope.Payload, &answer) == nil &&
			answer.SessionID == sessionID &&
			(!answer.Accepted || (answer.SDP != "" && len(answer.SDP) <= maxSessionSDPBytes))
	case "signal":
		var signal struct {
			Candidate json.RawMessage `json:"candidate"`
		}
		return len(envelope.Signal) > 0 && len(envelope.Signal) <= maxSessionICEServersSize &&
			json.Unmarshal(envelope.Signal, &signal) == nil && len(signal.Candidate) > 0 && json.Valid(signal.Candidate)
	default:
		return false
	}
}
