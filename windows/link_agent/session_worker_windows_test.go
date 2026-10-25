//go:build windows

package linkagent

import (
	"strings"
	"testing"
	"time"
)

func TestConsoleSessionMismatch15sTimeout(t *testing.T) {
	p := &windowsSessionWorkerProcess{
		sessionID: 2,
		pid:       1234,
	}

	t0 := time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)

	// 1. Same session ID -> no mismatch
	if err := p.checkConsoleSessionMismatch(2, t0); err != nil {
		t.Fatalf("unexpected error for matching session: %v", err)
	}
	if !p.consoleMismatchSince.IsZero() {
		t.Fatalf("expected consoleMismatchSince to be zero, got %v", p.consoleMismatchSince)
	}

	// 2. Special console IDs (0, 0xFFFFFFFF) -> ignored
	if err := p.checkConsoleSessionMismatch(0, t0); err != nil {
		t.Fatalf("unexpected error for console 0: %v", err)
	}
	if err := p.checkConsoleSessionMismatch(0xFFFFFFFF, t0); err != nil {
		t.Fatalf("unexpected error for console 0xFFFFFFFF: %v", err)
	}
	if !p.consoleMismatchSince.IsZero() {
		t.Fatalf("expected consoleMismatchSince to remain zero, got %v", p.consoleMismatchSince)
	}

	// 3. First detection of mismatch -> records timestamp, returns nil (does not abort)
	if err := p.checkConsoleSessionMismatch(3, t0); err != nil {
		t.Fatalf("expected no error on first mismatch detection, got: %v", err)
	}
	if p.consoleMismatchSince != t0 {
		t.Fatalf("expected consoleMismatchSince to be %v, got %v", t0, p.consoleMismatchSince)
	}

	// 4. Repeated mismatch within 15 seconds (e.g., at 10s) -> returns nil
	t10 := t0.Add(10 * time.Second)
	if err := p.checkConsoleSessionMismatch(3, t10); err != nil {
		t.Fatalf("expected no error within 10s of mismatch, got: %v", err)
	}
	if p.consoleMismatchSince != t0 {
		t.Fatalf("expected consoleMismatchSince to remain %v, got %v", t0, p.consoleMismatchSince)
	}

	// 5. Active console returns to worker session before 15s (e.g. at 14s) -> resets timer
	t14 := t0.Add(14 * time.Second)
	if err := p.checkConsoleSessionMismatch(2, t14); err != nil {
		t.Fatalf("expected no error when active console returns: %v", err)
	}
	if !p.consoleMismatchSince.IsZero() {
		t.Fatalf("expected consoleMismatchSince to be reset, got %v", p.consoleMismatchSince)
	}

	// 6. New mismatch starts at 20s
	t20 := t0.Add(20 * time.Second)
	if err := p.checkConsoleSessionMismatch(3, t20); err != nil {
		t.Fatalf("expected no error on new mismatch detection, got: %v", err)
	}
	if p.consoleMismatchSince != t20 {
		t.Fatalf("expected consoleMismatchSince to be %v, got %v", t20, p.consoleMismatchSince)
	}

	// 7. Mismatch persists past 15 seconds (at 36s, 16s later) -> returns error
	t36 := t20.Add(16 * time.Second)
	err := p.checkConsoleSessionMismatch(3, t36)
	if err == nil {
		t.Fatalf("expected error when mismatch persists > 15s, got nil")
	}
	if !strings.Contains(err.Error(), "persisted > 15s") {
		t.Fatalf("expected error message to contain 'persisted > 15s', got: %v", err)
	}
}
