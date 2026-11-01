//go:build !windows

package linkagent

import (
	"context"
)

func (s *RDSSupervisor) runSessionRecording(ctx context.Context, wtsSessionID uint32, active *activeRDSSession, fps float64, quality int) {
	// Stub for non-Windows platforms
	<-ctx.Done()
}
