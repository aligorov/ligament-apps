//go:build windows

package linkagent

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

func (s *RDSSupervisor) runSessionRecording(ctx context.Context, wtsSessionID uint32, active *activeRDSSession, fps float64, quality int) {
	defer func() {
		s.mu.Lock()
		if current, ok := s.sessions[wtsSessionID]; ok && current == active {
			delete(s.sessions, wtsSessionID)
		}
		s.mu.Unlock()
	}()

	pipeNonce := make([]byte, 8)
	_, _ = rand.Read(pipeNonce)
	pipeName := fmt.Sprintf(`\\.\pipe\ligament-rds-%d-%s`, wtsSessionID, hex.EncodeToString(pipeNonce))
	active.pipeName = pipeName

	pipeNameUTF16, err := windows.UTF16PtrFromString(pipeName)
	if err != nil {
		s.logf("[RDS] encode pipe name failed: %v", err)
		return
	}

	sd, err := windows.SecurityDescriptorFromString(linkHostPipeSDDL)
	if err != nil {
		s.logf("[RDS] parse SDDL failed: %v", err)
		return
	}
	absSD, err := sd.ToAbsolute()
	if err != nil {
		s.logf("[RDS] convert SD to absolute failed: %v", err)
		return
	}
	secAttrs := windows.SecurityAttributes{
		Length:             uint32(unsafe.Sizeof(windows.SecurityAttributes{})),
		SecurityDescriptor: absSD,
	}

	pipe, err := windows.CreateNamedPipe(
		pipeNameUTF16,
		windows.PIPE_ACCESS_DUPLEX,
		windows.PIPE_TYPE_MESSAGE|windows.PIPE_READMODE_MESSAGE|windows.PIPE_NOWAIT|windows.PIPE_REJECT_REMOTE_CLIENTS,
		1, linkHostFrameLimit, linkHostFrameLimit, 0, &secAttrs,
	)
	if err != nil {
		s.logf("[RDS] create named pipe failed: %v", err)
		return
	}
	defer windows.CloseHandle(pipe)

	// Launch worker process in wtsSessionID under LocalSystem token
	exePath, err := os.Executable()
	if err != nil {
		s.logf("[RDS] resolve executable failed: %v", err)
		return
	}

	cmdLine := fmt.Sprintf("\"%s\" --capture-worker --pipe=%s --session-id=%d --fps=%.2f --quality=%d",
		exePath, pipeName, wtsSessionID, fps, quality)
	cmdLineUTF16, _ := windows.UTF16PtrFromString(cmdLine)
	dirUTF16, _ := windows.UTF16PtrFromString(filepath.Dir(exePath))
	desktopUTF16, _ := windows.UTF16PtrFromString(`winsta0\default`)

	token, err := systemTokenForSession(wtsSessionID)
	if err != nil {
		s.logf("[RDS] acquire system token for session %d failed: %v", wtsSessionID, err)
		return
	}
	defer token.Close()

	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		s.logf("[RDS] create job object failed: %v", err)
		return
	}
	defer windows.CloseHandle(job)

	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | windows.JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION
	_, _ = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits)))

	var env *uint16
	_ = windows.CreateEnvironmentBlock(&env, token, false)
	if env != nil {
		defer windows.DestroyEnvironmentBlock(env)
	}

	startup := windows.StartupInfo{
		Cb:      uint32(unsafe.Sizeof(windows.StartupInfo{})),
		Desktop: desktopUTF16,
	}
	var procInfo windows.ProcessInformation

	creationFlags := uint32(windows.CREATE_UNICODE_ENVIRONMENT | windows.CREATE_SUSPENDED | windows.CREATE_NO_WINDOW)
	err = windows.CreateProcessAsUser(
		token,
		nil,
		cmdLineUTF16,
		nil,
		nil,
		false,
		creationFlags,
		env,
		dirUTF16,
		&startup,
		&procInfo,
	)
	if err != nil {
		s.logf("[RDS] CreateProcessAsUser for session %d failed: %v", wtsSessionID, err)
		return
	}
	defer windows.CloseHandle(procInfo.Process)
	defer windows.CloseHandle(procInfo.Thread)

	_ = windows.AssignProcessToJobObject(job, procInfo.Process)
	_, _ = windows.ResumeThread(procInfo.Thread)

	// Wait for pipe connection
	connected := false
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return
		}
		err := windows.ConnectNamedPipe(pipe, nil)
		if err == nil || errors.Is(err, windows.ERROR_PIPE_CONNECTED) {
			connected = true
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !connected {
		s.logf("[RDS] worker for session %d failed to connect to pipe in time", wtsSessionID)
		return
	}

	// Flush ticker for outgoing batches
	flushTicker := time.NewTicker(2 * time.Second)
	defer flushTicker.Stop()

	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-flushTicker.C:
				_ = active.recorder.Flush(ctx)
			}
		}
	}()

	// Read loop from worker Named Pipe
	buffer := make([]byte, linkHostFrameLimit)
	for {
		if ctx.Err() != nil {
			return
		}
		available, peekErr := peekPipeBytes(pipe)
		if peekErr != nil {
			if errors.Is(peekErr, windows.ERROR_PIPE_NOT_CONNECTED) || errors.Is(peekErr, windows.ERROR_BROKEN_PIPE) {
				s.logf("[RDS] pipe closed for session %d", wtsSessionID)
				return
			}
			time.Sleep(20 * time.Millisecond)
			continue
		}
		if available == 0 {
			time.Sleep(20 * time.Millisecond)
			continue
		}
		if available > linkHostFrameLimit {
			time.Sleep(20 * time.Millisecond)
			continue
		}

		var bytesRead uint32
		readErr := windows.ReadFile(pipe, buffer[:available], &bytesRead, nil)
		if readErr != nil {
			if errors.Is(readErr, windows.ERROR_NO_DATA) {
				time.Sleep(10 * time.Millisecond)
				continue
			}
			return
		}

		if bytesRead > 0 {
			payload := buffer[:bytesRead]
			var header struct {
				Type string `json:"type"`
			}
			if json.Unmarshal(payload, &header) == nil {
				switch header.Type {
				case WorkerMsgFrame:
					var frame WorkerFrameMessage
					if json.Unmarshal(payload, &frame) == nil {
						active.recorder.EnqueueFrame(RecordedFrame{
							Seq:           active.recorder.NextSeq(),
							FrameKind:     "periodic",
							Width:         frame.Width,
							Height:        frame.Height,
							Codec:         frame.Codec,
							PayloadBase64: frame.PayloadBase64,
							CapturedAt:    frame.CapturedAt,
							WindowTitle:   frame.WindowTitle,
							ProcessName:   frame.ProcessName,
						})
					}
				case WorkerMsgEvent:
					var ev WorkerEventMessage
					if json.Unmarshal(payload, &ev) == nil {
						active.recorder.EnqueueEvent(RecordedEvent{
							Seq:        active.recorder.NextSeq(),
							EventType:  ev.EventKind,
							Source:     "host_system",
							OccurredAt: ev.OccurredAt,
							Metadata:   ev.Payload,
						})
					}
				}
			}
		}
	}
}
