//go:build !windows

package linkagent

import (
	"context"
	"errors"
)

// RunCaptureWorker stub for non-Windows platforms.
func RunCaptureWorker(ctx context.Context, pipePath string, sessionID uint32, targetFPS float64, quality int) error {
	return errors.New("capture worker: only supported on Windows")
}
