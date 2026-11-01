package linkagent

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"
)

// RDSSessionStartPolicy is returned by Core upon rdp_session_start.
type RDSSessionStartPolicy struct {
	WTSSessionID  uint32  `json:"wts_session_id"`
	SessionID     string  `json:"session_id"`
	Record        bool    `json:"record"`
	RecorderURL   string  `json:"recorder_url"`
	IngestToken   string  `json:"ingest_token"`
	FailurePolicy string  `json:"failure_policy"` // "resilient", "strict"
	TargetFPS     float64 `json:"target_fps"`
	Quality       int     `json:"quality"`
}

type activeRDSSession struct {
	wtsSession    WTSSession
	coreSessionID string
	cancel        context.CancelFunc
	recorder      *RecorderClient
	pipeName      string
	startedAt     time.Time
}

// RDSSupervisor coordinates multi-session RDP recording on Windows Terminal Servers.
type RDSSupervisor struct {
	spooler      *DiskSpooler
	sendToCore   func(any) error
	logger       *log.Logger
	mu           sync.RWMutex
	sessions     map[uint32]*activeRDSSession
	autoRecord   bool
	defaultFPS   float64
	defaultQual  int
	failPolicy   string
	spoolBaseDir string
}

// NewRDSSupervisor creates an RDS session supervisor.
func NewRDSSupervisor(spoolBaseDir string, sendToCore func(any) error, logger *log.Logger) (*RDSSupervisor, error) {
	spooler, err := NewDiskSpooler(spoolBaseDir, 5*1024*1024*1024)
	if err != nil {
		return nil, fmt.Errorf("rds supervisor: init spooler: %w", err)
	}
	return &RDSSupervisor{
		spooler:      spooler,
		sendToCore:   sendToCore,
		logger:       logger,
		sessions:     make(map[uint32]*activeRDSSession),
		autoRecord:   true,
		defaultFPS:   1.0,
		defaultQual:  65,
		failPolicy:   "resilient",
		spoolBaseDir: spoolBaseDir,
	}, nil
}

// HandleSessionLogon is invoked when a user logs on (WTS_SESSION_LOGON or WTS_REMOTE_CONNECT).
func (s *RDSSupervisor) HandleSessionLogon(session WTSSession) {
	if !session.IsRDP && !session.IsActive {
		return
	}
	if session.Username == "" {
		return
	}

	s.mu.Lock()
	if _, exists := s.sessions[session.SessionID]; exists {
		s.mu.Unlock()
		return
	}
	s.mu.Unlock()

	if s.logger != nil {
		s.logger.Printf("[RDS] user logon detected: session=%d user=%s ip=%s",
			session.SessionID, session.UserAccount(), session.ClientIP)
	}

	if s.sendToCore != nil {
		_ = s.sendToCore(map[string]any{
			"type":           "rdp_session_start",
			"wts_session_id": session.SessionID,
			"username":       session.Username,
			"domain":         session.Domain,
			"client_ip":      session.ClientIP,
			"client_name":    session.ClientName,
			"protocol_type":  session.ProtocolType,
		})
	}
}

// HandleSessionLogoff is invoked when a user disconnects or logs off (WTS_SESSION_LOGOFF or WTS_REMOTE_DISCONNECT).
func (s *RDSSupervisor) HandleSessionLogoff(sessionID uint32, reason string) {
	s.mu.Lock()
	sess, exists := s.sessions[sessionID]
	if !exists {
		s.mu.Unlock()
		return
	}
	delete(s.sessions, sessionID)
	s.mu.Unlock()

	if s.logger != nil {
		s.logger.Printf("[RDS] user logoff: session=%d core_id=%s reason=%s",
			sessionID, sess.coreSessionID, reason)
	}

	if sess.cancel != nil {
		sess.cancel()
	}
	if sess.recorder != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		_ = sess.recorder.Complete(ctx, "completed", reason)
		cancel()
	}

	if s.sendToCore != nil {
		_ = s.sendToCore(map[string]any{
			"type":           "rdp_session_end",
			"wts_session_id": sessionID,
			"session_id":     sess.coreSessionID,
			"reason":         reason,
		})
	}
}

// ApplySessionPolicy starts recording for a confirmed RDP session.
func (s *RDSSupervisor) ApplySessionPolicy(ctx context.Context, policy RDSSessionStartPolicy) error {
	if !policy.Record || policy.IngestToken == "" || policy.RecorderURL == "" {
		return nil
	}

	s.mu.Lock()
	if _, exists := s.sessions[policy.WTSSessionID]; exists {
		s.mu.Unlock()
		return nil
	}
	s.mu.Unlock()

	fps := policy.TargetFPS
	if fps <= 0 {
		fps = s.defaultFPS
	}
	qual := policy.Quality
	if qual <= 0 {
		qual = s.defaultQual
	}
	failPol := policy.FailurePolicy
	if failPol == "" {
		failPol = s.failPolicy
	}

	recClient, err := NewRecorderClient(RecorderClientConfig{
		SessionID:     policy.SessionID,
		IngestURL:     policy.RecorderURL,
		IngestToken:   policy.IngestToken,
		FailurePolicy: failPol,
		Spooler:       s.spooler,
	})
	if err != nil {
		return fmt.Errorf("rds supervisor: init recorder client: %w", err)
	}

	sessCtx, cancel := context.WithCancel(ctx)
	active := &activeRDSSession{
		coreSessionID: policy.SessionID,
		cancel:        cancel,
		recorder:      recClient,
		startedAt:     time.Now().UTC(),
	}

	s.mu.Lock()
	s.sessions[policy.WTSSessionID] = active
	s.mu.Unlock()

	go s.runSessionRecording(sessCtx, policy.WTSSessionID, active, fps, qual)
	return nil
}

// StopAll stops all active recording sessions.
func (s *RDSSupervisor) StopAll(reason string) {
	s.mu.Lock()
	activeList := make([]*activeRDSSession, 0, len(s.sessions))
	for _, a := range s.sessions {
		activeList = append(activeList, a)
	}
	s.sessions = make(map[uint32]*activeRDSSession)
	s.mu.Unlock()

	for _, a := range activeList {
		if a.cancel != nil {
			a.cancel()
		}
		if a.recorder != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			_ = a.recorder.Complete(ctx, "completed", reason)
			cancel()
		}
	}
}
