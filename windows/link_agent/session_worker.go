package linkagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
)

const maxQueuedWorkerSignals = 256

var (
	workerLogMu sync.RWMutex
	workerLogFn = func(format string, args ...any) {}
)

// SetWorkerLogger configures a thread-safe diagnostic logger for worker lifecycle events.
func SetWorkerLogger(fn func(format string, args ...any)) {
	workerLogMu.Lock()
	defer workerLogMu.Unlock()
	if fn != nil {
		workerLogFn = fn
	}
}

func workerLog(format string, args ...any) {
	workerLogMu.RLock()
	fn := workerLogFn
	workerLogMu.RUnlock()
	if fn != nil {
		fn(format, args...)
	}
}

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
	cancel             context.CancelFunc
	process            SessionWorkerProcess
	outbound           chan []byte
	sendMu             sync.RWMutex
	send               func(any) error
	mu                 sync.Mutex
	terminateRequested bool
	stopped            bool
}

func (s *workerSession) setSender(send func(any) error) {
	if send == nil {
		return
	}
	s.sendMu.Lock()
	s.send = send
	s.sendMu.Unlock()
}

func (s *workerSession) markTerminated() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.terminateRequested = true
}

func (s *workerSession) isTerminated() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.terminateRequested || s.stopped
}

func (s *workerSession) drainOutbound() {
	for {
		select {
		case sig := <-s.outbound:
			clear(sig)
		default:
			return
		}
	}
}

func (s *workerSession) sendFrame(msg any) error {
	s.sendMu.RLock()
	fn := s.send
	s.sendMu.RUnlock()
	if fn == nil {
		return errors.New("link agent: no active WSS sender")
	}
	return fn(msg)
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

// RebindSender updates the outbound WSS sender for all active worker sessions
// after a control-channel reconnect so running sessions do not drop.
func (b *SessionWorkerBroker) RebindSender(send func(any) error) {
	if send == nil {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, s := range b.sessions {
		s.setSender(send)
	}
}

// Handler is an AgentMessageHandler suitable for RunAgent.
func (b *SessionWorkerBroker) Handler(ctx context.Context, message []byte, send func(any) error) error {
	b.RebindSender(send)
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
		send:     send,
	}
	b.mu.Lock()
	if existing, exists := b.sessions[offer.SessionID]; exists {
		existing.setSender(send)
		b.mu.Unlock()
		cancel()
		return nil // Duplicate offer is idempotent; never launch a second desktop worker.
	}
	b.sessions[offer.SessionID] = session
	b.mu.Unlock()

	offerFrame := append([]byte(nil), frame...)
	go b.run(workerCtx, offer, offerFrame, session)
	return nil
}

func (b *SessionWorkerBroker) run(ctx context.Context, offer SessionOffer, frame []byte, session *workerSession) {
	initialOfferFrame := append([]byte(nil), frame...)
	defer clear(initialOfferFrame)
	defer clear(frame)
	defer b.remove(offer.SessionID, session)

	var restarts int
	restartWindow := time.Now()

	for {
		if ctx.Err() != nil || session.isTerminated() {
			return
		}

		process, err := b.launcher.Launch(ctx, offer, initialOfferFrame)
		if err != nil {
			if restarts == 0 {
				reason := classifyWorkerLaunchError(err)
				_ = sendRejectedAnswer(session.sendFrame, offer.SessionID, reason)
				return
			}
			workerLog("[LINK RECOVERY] Worker restart launch failed for session %s: %v", offer.SessionID, err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(1 * time.Second):
			}
			if time.Since(restartWindow) >= 60*time.Second {
				restartWindow = time.Now()
				restarts = 0
			}
			restarts++
			if restarts > 3 {
				workerLog("[LINK RECOVERY] Worker restart limit reached (3 in 60s) for session %s, terminating", offer.SessionID)
				return
			}
			continue
		}

		b.mu.Lock()
		if b.sessions[offer.SessionID] != session || ctx.Err() != nil {
			b.mu.Unlock()
			_ = process.Close()
			return
		}
		session.process = process
		b.mu.Unlock()

		workerLog("[LINK HOST] Active worker attached to session %s (restart count: %d)", offer.SessionID, restarts)

		// Drain stale signals from previous dead worker only on restart
		if restarts > 0 {
			session.drainOutbound()
		}

		procCtx, procCancel := context.WithCancel(ctx)
		writerDone := make(chan error, 1)
		go func() {
			for {
				select {
				case <-procCtx.Done():
					writerDone <- procCtx.Err()
					return
				case signal := <-session.outbound:
					err := process.Send(procCtx, signal)
					clear(signal)
					if err != nil {
						writerDone <- err
						return
					}
				}
			}
		}()

		type readResult struct {
			frame []byte
			err   error
		}
		readResults := make(chan readResult, 1)
		go func() {
			for {
				frame, err := process.Receive(procCtx)
				select {
				case readResults <- readResult{frame: frame, err: err}:
				case <-procCtx.Done():
					clear(frame)
					return
				}
				if err != nil {
					return
				}
			}
		}()

		procDone := false
		for !procDone {
			select {
			case <-ctx.Done():
				procCancel()
				_ = process.Close()
				return
			case err := <-writerDone:
				if err != nil {
					workerLog("[LINK RECOVERY] Worker writer stopped for session %s: %v", offer.SessionID, err)
					procCancel()
					procDone = true
				}
			case result := <-readResults:
				if result.err != nil {
					workerLog("[LINK RECOVERY] Worker reader stopped for session %s: %v", offer.SessionID, result.err)
					procCancel()
					procDone = true
					break
				}
				response := result.frame
				if !validWorkerResponse(response, offer.SessionID) {
					clear(response)
					procCancel()
					procDone = true
					break
				}
				var envelope Envelope
				_ = json.Unmarshal(response, &envelope)
				if envelope.Type == "session_terminate" {
					session.markTerminated()
				}
				_ = session.sendFrame(json.RawMessage(response))
				clear(response)
			}
		}

		procCancel()
		_ = process.Close()

		if session.isTerminated() || ctx.Err() != nil {
			workerLog("[LINK HOST] Session %s terminated cleanly, not restarting", offer.SessionID)
			return
		}

		if time.Since(restartWindow) >= 60*time.Second {
			restartWindow = time.Now()
			restarts = 0
		}
		restarts++
		if restarts > 3 {
			workerLog("[LINK RECOVERY] Worker restart limit reached (3 in 60s) for session %s, giving up", offer.SessionID)
			return
		}

		workerLog("[LINK RECOVERY] Initiating recovery restart %d/3 for session %s in 500ms...", restarts, offer.SessionID)
		select {
		case <-ctx.Done():
			return
		case <-time.After(500 * time.Millisecond):
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
	session.markTerminated()
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
	session.markTerminated()
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
			request.SessionID == sessionID &&
			(request.Reason == "host_local_disconnect" ||
				request.Reason == "peer_failed" ||
				strings.HasPrefix(request.Reason, "recorder_"))
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
