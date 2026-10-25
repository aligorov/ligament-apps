//go:build windows

package linkagent

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	linkHostPipePrefix = `\\.\pipe\LigamentLinkHost-`
	linkHostPipeSDDL   = "D:P(A;;GA;;;SY)"
	linkHostFrameLimit = 512 * 1024
	linkHostPollPeriod = 10 * time.Millisecond
	linkHostStartLimit = 20 * time.Second
)

var peekNamedPipeProc = windows.NewLazySystemDLL("kernel32.dll").NewProc("PeekNamedPipe")

type WindowsSessionWorkerLauncher struct{}

func NewNativeSessionWorkerLauncher() SessionWorkerLauncher {
	return NewWindowsSessionWorkerLauncher()
}

func NewWindowsSessionWorkerLauncher() *WindowsSessionWorkerLauncher {
	return &WindowsSessionWorkerLauncher{}
}

func (*WindowsSessionWorkerLauncher) Launch(ctx context.Context, offer SessionOffer, offerFrame []byte) (SessionWorkerProcess, error) {
	if len(offerFrame) == 0 || len(offerFrame) > linkHostFrameLimit {
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerUnavailable,
			Err:    errors.New("link agent: invalid initial worker frame size"),
		}
	}
	allowLogon := (offer.AccessType == "unattended" && offer.DesktopScope == "system_console") ||
		(offer.AccessType == "unattended" && offer.SessionKind == "console")
	sess, desktop, err := ResolveTargetSession(allowLogon)
	if err != nil {
		if errors.Is(err, ErrNoActiveInteractiveUser) {
			return nil, &WorkerLaunchError{Reason: ReasonHostNoActiveUser, Err: err}
		}
		if errors.Is(err, ErrAmbiguousInteractiveSession) {
			return nil, &WorkerLaunchError{Reason: ReasonHostSessionAmbiguous, Err: err}
		}
		return nil, &WorkerLaunchError{Reason: ReasonHostWorkerLaunchFailed, Err: err}
	}
	sessionID := sess.SessionID

	pipeName, err := newLinkHostPipeName()
	if err != nil {
		return nil, &WorkerLaunchError{Reason: ReasonHostWorkerLaunchFailed, Err: err}
	}
	if !workerPipeNameIsValid(pipeName) {
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    errors.New("link agent: generated invalid worker pipe name"),
		}
	}
	pipeNameUTF16, err := windows.UTF16PtrFromString(pipeName)
	if err != nil {
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: encode worker pipe name: %w", err),
		}
	}
	sd, err := windows.SecurityDescriptorFromString(linkHostPipeSDDL)
	if err != nil {
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: create worker pipe ACL: %w", err),
		}
	}
	absSD, err := sd.ToAbsolute()
	if err != nil {
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: prepare worker pipe ACL: %w", err),
		}
	}
	security := windows.SecurityAttributes{
		Length:             uint32(unsafe.Sizeof(windows.SecurityAttributes{})),
		SecurityDescriptor: absSD,
	}
	pipe, err := windows.CreateNamedPipe(
		pipeNameUTF16,
		windows.PIPE_ACCESS_DUPLEX,
		windows.PIPE_TYPE_MESSAGE|windows.PIPE_READMODE_MESSAGE|windows.PIPE_NOWAIT|windows.PIPE_REJECT_REMOTE_CLIENTS,
		1, linkHostFrameLimit, linkHostFrameLimit, 0, &security,
	)
	if err != nil {
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: create worker named pipe: %w", err),
		}
	}
	process, err := startInteractiveLinkHost(pipeName, sessionID, desktop)
	if err != nil {
		_ = windows.CloseHandle(pipe)
		return nil, err
	}
	worker := &windowsSessionWorkerProcess{
		pipe:        pipe,
		process:     process.Process,
		job:         process.job,
		pid:         process.ProcessId,
		sessionID:   sessionID,
		desktopName: desktop,
		startedAt:   time.Now(),
	}
	activeConsole := getActiveConsoleSessionID()
	workerLog("interactive host started: pid=%d target_session=%d active_console=%d desktop=%s pipe=%s offer_session=%s",
		process.ProcessId, sessionID, activeConsole, desktop, pipeName, offer.SessionID)
	if err := worker.acceptChild(ctx, process.ProcessId); err != nil {
		var exitCode uint32
		_ = windows.GetExitCodeProcess(process.Process, &exitCode)
		activeNow := getActiveConsoleSessionID()
		workerLog("interactive host failed to connect pipe: pid=%d exit_code=%d target_session=%d active_console_now=%d err=%v",
			process.ProcessId, exitCode, sessionID, activeNow, err)
		_ = worker.Close()
		return nil, &WorkerLaunchError{Reason: ReasonHostWorkerLaunchFailed, Err: err}
	}
	workerLog("interactive host pipe connected: pid=%d", process.ProcessId)
	if err := worker.Send(ctx, offerFrame); err != nil {
		_ = worker.Close()
		return nil, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: send offer to interactive worker: %w", err),
		}
	}
	return worker, nil
}

type launchedProcess struct {
	windows.ProcessInformation
	job windows.Handle
}

func startInteractiveLinkHost(pipeName string, sessionID uint32, desktopName string) (launchedProcess, error) {
	executable, err := os.Executable()
	if err != nil {
		return launchedProcess{}, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: locate service executable: %w", err),
		}
	}
	appPath := filepath.Join(filepath.Dir(executable), "ligament_authenticator.exe")
	if info, err := os.Stat(appPath); err != nil || info.IsDir() {
		return launchedProcess{}, &WorkerLaunchError{
			Reason: ReasonHostWorkerNotInstalled,
			Err:    errors.New("link agent: interactive Flutter host is not installed"),
		}
	}
	app, err := windows.UTF16PtrFromString(appPath)
	if err != nil {
		return launchedProcess{}, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: encode Flutter host path: %w", err),
		}
	}
	command, err := windows.UTF16PtrFromString(fmt.Sprintf("\"%s\" --link-host=%s", appPath, pipeName))
	if err != nil {
		return launchedProcess{}, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: encode Flutter host command: %w", err),
		}
	}
	directory, err := windows.UTF16PtrFromString(filepath.Dir(appPath))
	if err != nil {
		return launchedProcess{}, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: encode Flutter host directory: %w", err),
		}
	}
	if desktopName == "" {
		desktopName = `winsta0\default`
	}
	desktop, err := windows.UTF16PtrFromString(desktopName)
	if err != nil {
		return launchedProcess{}, &WorkerLaunchError{Reason: ReasonHostWorkerLaunchFailed, Err: err}
	}
	token, err := systemTokenForSession(sessionID)
	if err != nil {
		return launchedProcess{}, &WorkerLaunchError{Reason: ReasonHostWorkerLaunchFailed, Err: err}
	}
	defer token.Close()
	var environment *uint16
	if err := windows.CreateEnvironmentBlock(&environment, token, false); err != nil {
		return launchedProcess{}, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: create worker environment: %w", err),
		}
	}
	defer windows.DestroyEnvironmentBlock(environment)

	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return launchedProcess{}, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: create worker job: %w", err),
		}
	}
	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | windows.JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits))); err != nil {
		_ = windows.CloseHandle(job)
		return launchedProcess{}, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: configure worker job: %w", err),
		}
	}
	startup := windows.StartupInfo{
		Cb:         uint32(unsafe.Sizeof(windows.StartupInfo{})),
		Desktop:    desktop,
		Flags:      windows.STARTF_USESHOWWINDOW,
		ShowWindow: windows.SW_HIDE,
	}
	var created windows.ProcessInformation
	const creationFlags = windows.CREATE_SUSPENDED | windows.CREATE_UNICODE_ENVIRONMENT
	if err := windows.CreateProcessAsUser(token, app, command, nil, nil, false,
		creationFlags, environment, directory, &startup, &created); err != nil {
		_ = windows.CloseHandle(job)
		return launchedProcess{}, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: start Flutter host in interactive session: %w", err),
		}
	}
	if err := windows.AssignProcessToJobObject(job, created.Process); err != nil {
		_ = windows.TerminateProcess(created.Process, 1)
		_ = windows.CloseHandle(created.Thread)
		_ = windows.CloseHandle(created.Process)
		_ = windows.CloseHandle(job)
		return launchedProcess{}, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: assign Flutter host job: %w", err),
		}
	}
	if _, err := windows.ResumeThread(created.Thread); err != nil {
		_ = windows.TerminateJobObject(job, 1)
		_ = windows.CloseHandle(created.Thread)
		_ = windows.CloseHandle(created.Process)
		_ = windows.CloseHandle(job)
		return launchedProcess{}, &WorkerLaunchError{
			Reason: ReasonHostWorkerLaunchFailed,
			Err:    fmt.Errorf("link agent: resume Flutter host: %w", err),
		}
	}
	_ = windows.CloseHandle(created.Thread)
	return launchedProcess{ProcessInformation: created, job: job}, nil
}

func systemTokenForSession(sessionID uint32) (windows.Token, error) {
	var source windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY|windows.TOKEN_DUPLICATE|windows.TOKEN_ADJUST_PRIVILEGES, &source); err != nil {
		return 0, fmt.Errorf("link agent: open service token: %w", err)
	}
	defer source.Close()
	user, err := source.GetTokenUser()
	if err != nil || !user.User.Sid.IsWellKnown(windows.WinLocalSystemSid) {
		return 0, errors.New("link agent: interactive worker launch requires LocalSystem")
	}
	for _, privilege := range []string{"SeTcbPrivilege", "SeAssignPrimaryTokenPrivilege", "SeIncreaseQuotaPrivilege"} {
		if err := enableTokenPrivilege(source, privilege); err != nil {
			return 0, err
		}
	}
	access := uint32(windows.TOKEN_QUERY | windows.TOKEN_DUPLICATE | windows.TOKEN_ASSIGN_PRIMARY |
		windows.TOKEN_ADJUST_DEFAULT | windows.TOKEN_ADJUST_SESSIONID)
	var token windows.Token
	if err := windows.DuplicateTokenEx(source, access, nil, windows.SecurityImpersonation, windows.TokenPrimary, &token); err != nil {
		return 0, fmt.Errorf("link agent: duplicate LocalSystem token: %w", err)
	}
	if err := windows.SetTokenInformation(token, windows.TokenSessionId, (*byte)(unsafe.Pointer(&sessionID)), uint32(unsafe.Sizeof(sessionID))); err != nil {
		_ = token.Close()
		return 0, fmt.Errorf("link agent: assign worker session token: %w", err)
	}
	return token, nil
}

func enableTokenPrivilege(token windows.Token, name string) error {
	nameUTF16, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return err
	}
	var luid windows.LUID
	if err := windows.LookupPrivilegeValue(nil, nameUTF16, &luid); err != nil {
		return fmt.Errorf("link agent: resolve %s: %w", name, err)
	}
	privileges := windows.Tokenprivileges{
		PrivilegeCount: 1,
		Privileges:     [1]windows.LUIDAndAttributes{{Luid: luid, Attributes: windows.SE_PRIVILEGE_ENABLED}},
	}
	if err := windows.AdjustTokenPrivileges(token, false, &privileges, 0, nil, nil); err != nil {
		return fmt.Errorf("link agent: enable %s: %w", name, err)
	}
	return nil
}

func newLinkHostPipeName() (string, error) {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return "", fmt.Errorf("link agent: generate worker pipe name: %w", err)
	}
	return linkHostPipePrefix + fmt.Sprintf("%x", nonce[:]), nil
}

type windowsSessionWorkerProcess struct {
	pipe        windows.Handle
	process     windows.Handle
	job         windows.Handle
	pid         uint32
	sessionID   uint32
	desktopName string
	startedAt            time.Time
	consoleMismatchSince time.Time

	mu     sync.RWMutex
	sendMu sync.Mutex
	closed bool
}

func (p *windowsSessionWorkerProcess) acceptChild(ctx context.Context, expectedPID uint32) error {
	deadline := time.Now().Add(linkHostStartLimit)
	for time.Now().Before(deadline) {
		if err := ctx.Err(); err != nil {
			return err
		}
		err := windows.ConnectNamedPipe(p.pipe, nil)
		if err == nil || errors.Is(err, windows.ERROR_PIPE_CONNECTED) {
			var childPID uint32
			if err := windows.GetNamedPipeClientProcessId(p.pipe, &childPID); err != nil || childPID != expectedPID {
				return errors.New("link agent: worker pipe client PID mismatch")
			}
			return nil
		}
		if !errors.Is(err, windows.ERROR_PIPE_LISTENING) && !errors.Is(err, windows.ERROR_NO_DATA) {
			return fmt.Errorf("link agent: accept worker pipe: %w", err)
		}
		if state, waitErr := windows.WaitForSingleObject(p.process, 0); waitErr != nil || state == windows.WAIT_OBJECT_0 {
			return errors.New("link agent: Flutter worker exited before pipe connection")
		}
		time.Sleep(linkHostPollPeriod)
	}
	return errors.New("link agent: Flutter worker pipe connection timed out")
}

func (p *windowsSessionWorkerProcess) Send(ctx context.Context, frame []byte) error {
	if len(frame) == 0 || len(frame) > linkHostFrameLimit {
		return errors.New("link agent: worker IPC frame exceeds size limit")
	}
	p.sendMu.Lock()
	defer p.sendMu.Unlock()
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		p.mu.RLock()
		if p.closed {
			p.mu.RUnlock()
			return errors.New("link agent: worker pipe closed")
		}
		pipe := p.pipe
		p.mu.RUnlock()
		var written uint32
		err := windows.WriteFile(pipe, frame, &written, nil)
		if err == nil {
			if written != uint32(len(frame)) {
				return errors.New("link agent: incomplete worker IPC write")
			}
			return nil
		}
		if !errors.Is(err, windows.ERROR_NO_DATA) && !errors.Is(err, windows.ERROR_PIPE_LISTENING) {
			return fmt.Errorf("link agent: write worker IPC frame: %w", err)
		}
		time.Sleep(linkHostPollPeriod)
	}
}

func (p *windowsSessionWorkerProcess) Receive(ctx context.Context) ([]byte, error) {
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		p.mu.RLock()
		if p.closed {
			p.mu.RUnlock()
			return nil, errors.New("link agent: worker pipe closed")
		}
		pipe, process := p.pipe, p.process
		p.mu.RUnlock()

		// Track active console session changes (e.g. Logon / Lock / Fast User Switch).
		// Close session only if the mismatch persists longer than 15s (task 3.5).
		activeConsole := getActiveConsoleSessionID()
		if err := p.checkConsoleSessionMismatch(activeConsole, time.Now()); err != nil {
			return nil, err
		}

		available, err := peekPipeBytes(pipe)
		if err != nil {
			var exitCode uint32
			_ = windows.GetExitCodeProcess(process, &exitCode)
			activeNow := getActiveConsoleSessionID()
			workerLog("interactive host pipe inspect failed: pid=%d exit_code=%d target_session=%d active_console_now=%d err=%v",
				p.pid, exitCode, p.sessionID, activeNow, err)
			return nil, fmt.Errorf("link agent: inspect worker pipe: %w", err)
		}
		if available > linkHostFrameLimit {
			return nil, errors.New("link agent: worker IPC frame exceeds size limit")
		}
		if available > 0 {
			buffer := make([]byte, available)
			var read uint32
			err := windows.ReadFile(pipe, buffer, &read, nil)
			if err != nil {
				clear(buffer)
				if errors.Is(err, windows.ERROR_MORE_DATA) {
					return nil, errors.New("link agent: worker IPC message exceeds size limit")
				}
				if errors.Is(err, windows.ERROR_NO_DATA) {
					continue
				}
				var exitCode uint32
				_ = windows.GetExitCodeProcess(process, &exitCode)
				activeNow := getActiveConsoleSessionID()
				workerLog("interactive host pipe read failed: pid=%d exit_code=%d target_session=%d active_console_now=%d err=%v",
					p.pid, exitCode, p.sessionID, activeNow, err)
				return nil, fmt.Errorf("link agent: read worker IPC frame: %w", err)
			}
			return buffer[:read], nil
		}
		if state, waitErr := windows.WaitForSingleObject(process, 0); waitErr != nil || state == windows.WAIT_OBJECT_0 {
			var exitCode uint32
			_ = windows.GetExitCodeProcess(process, &exitCode)
			activeNow := getActiveConsoleSessionID()
			workerLog("interactive host process exited: pid=%d exit_code=%d (0x%X) target_session=%d active_console_now=%d lifetime=%v",
				p.pid, exitCode, exitCode, p.sessionID, activeNow, time.Since(p.startedAt))
			return nil, fmt.Errorf("link agent: Flutter worker exited with code %d", exitCode)
		}
		time.Sleep(linkHostPollPeriod)
	}
}

func peekPipeBytes(pipe windows.Handle) (uint32, error) {
	var messageBytes uint32
	r1, _, callErr := peekNamedPipeProc.Call(uintptr(pipe), 0, 0, 0, 0,
		uintptr(unsafe.Pointer(&messageBytes)))
	if r1 == 0 {
		if callErr != windows.ERROR_SUCCESS {
			return 0, callErr
		}
		return 0, windows.GetLastError()
	}
	return messageBytes, nil
}

func (p *windowsSessionWorkerProcess) checkConsoleSessionMismatch(activeConsole uint32, now time.Time) error {
	if activeConsole != 0 && activeConsole != 0xFFFFFFFF && activeConsole != p.sessionID {
		if p.consoleMismatchSince.IsZero() {
			p.consoleMismatchSince = now
			workerLog("interactive host session mismatch detected: worker_session=%d active_console_now=%d pid=%d",
				p.sessionID, activeConsole, p.pid)
		} else if now.Sub(p.consoleMismatchSince) > 15*time.Second {
			workerLog("interactive host session mismatch exceeded 15s limit: worker_session=%d active_console_now=%d pid=%d",
				p.sessionID, activeConsole, p.pid)
			return fmt.Errorf("link agent: active console session changed from %d to %d (persisted > 15s)", p.sessionID, activeConsole)
		}
	} else {
		p.consoleMismatchSince = time.Time{}
	}
	return nil
}

func (p *windowsSessionWorkerProcess) Close() error {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return nil
	}
	p.closed = true
	pipe, process, job := p.pipe, p.process, p.job
	p.pipe, p.process, p.job = 0, 0, 0
	p.mu.Unlock()

	if job != 0 {
		_ = windows.TerminateJobObject(job, 1)
	}
	if pipe != 0 {
		_ = windows.CloseHandle(pipe)
	}
	if process != 0 {
		_, _ = windows.WaitForSingleObject(process, uint32(5*time.Second/time.Millisecond))
		_ = windows.CloseHandle(process)
	}
	if job != 0 {
		_ = windows.CloseHandle(job)
	}
	return nil
}

func workerPipeNameIsValid(pipe string) bool {
	if !strings.HasPrefix(pipe, linkHostPipePrefix) || len(pipe) != len(linkHostPipePrefix)+32 {
		return false
	}
	for _, c := range pipe[len(linkHostPipePrefix):] {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}
