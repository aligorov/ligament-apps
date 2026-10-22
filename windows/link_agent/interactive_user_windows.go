//go:build windows

package linkagent

import (
	"errors"
	"unsafe"

	"golang.org/x/sys/windows"
)

var wtsapi = windows.NewLazySystemDLL("wtsapi32.dll")
var procWTSQuerySessionInformation = wtsapi.NewProc("WTSQuerySessionInformationW")
var procWTSEnumerateSessions = wtsapi.NewProc("WTSEnumerateSessionsW")

var kernel32 = windows.NewLazySystemDLL("kernel32.dll")
var procWTSGetActiveConsoleSessionId = kernel32.NewProc("WTSGetActiveConsoleSessionId")

var getActiveConsoleSessionID = defaultGetActiveConsoleSessionID

func defaultGetActiveConsoleSessionID() uint32 {
	if procWTSGetActiveConsoleSessionId.Find() != nil {
		return 0xFFFFFFFF
	}
	r, _, _ := procWTSGetActiveConsoleSessionId.Call()
	return uint32(r)
}

type wtsSessionInfo struct {
	SessionID       uint32
	WinStationName  *uint16
	ConnectionState uint32
}

var enumerateInteractiveSessions = defaultEnumerateInteractiveSessions

func defaultEnumerateInteractiveSessions() ([]InteractiveSession, error) {
	if procWTSEnumerateSessions.Find() != nil || procWTSQuerySessionInformation.Find() != nil {
		return nil, errors.New("link agent: WTS API unavailable")
	}
	var sessions *wtsSessionInfo
	var count uint32
	result, _, _ := procWTSEnumerateSessions.Call(0, 0, 1,
		uintptr(unsafe.Pointer(&sessions)), uintptr(unsafe.Pointer(&count)))
	if result == 0 || sessions == nil || count == 0 || count > 1024 {
		return nil, nil
	}
	defer windows.WTSFreeMemory(uintptr(unsafe.Pointer(sessions)))
	var active []InteractiveSession
	for _, session := range unsafe.Slice(sessions, count) {
		if session.SessionID == 0 {
			continue // Session 0 is reserved for non-interactive system services.
		}
		if session.ConnectionState == 0 { // WTSActive
			if username := queryWTSUsername(session.SessionID); username != "" {
				active = append(active, InteractiveSession{
					SessionID: session.SessionID,
					Username:  username,
				})
			}
		}
	}
	return active, nil
}

// ResolveTargetSession determines the session and desktop to attach to.
// If unattended is true and no user is logged in, it targets the active console session ID
// (logon screen / lock screen) with desktop winsta0\Winlogon.
func ResolveTargetSession(unattended bool) (*InteractiveSession, string, error) {
	active, err := enumerateInteractiveSessions()
	if err != nil {
		return nil, "", err
	}
	if len(active) == 1 {
		return &active[0], `winsta0\default`, nil
	}
	if len(active) > 1 {
		return nil, "", ErrAmbiguousInteractiveSession
	}
	// len(active) == 0: no interactive user logged in
	if unattended {
		consoleID := getActiveConsoleSessionID()
		if consoleID != 0xFFFFFFFF && consoleID != 0 {
			return &InteractiveSession{
				SessionID: consoleID,
				Username:  "",
			}, `winsta0\Winlogon`, nil
		}
	}
	return nil, "", ErrNoActiveInteractiveUser
}

// ResolveInteractiveSession inspects Terminal Services sessions on the system.
// It returns:
// - (session, nil) if exactly one active interactive user session exists (Console or RDP).
// - (nil, ErrNoActiveInteractiveUser) if no active user session exists.
// - (nil, ErrAmbiguousInteractiveSession) if multiple active user sessions exist.
//
// It never selects Session 0, and never selects a session without a logged-in user.
func ResolveInteractiveSession() (*InteractiveSession, error) {
	sess, _, err := ResolveTargetSession(false)
	return sess, err
}

// CurrentInteractiveUser returns the username of the single active interactive WTS
// session (supporting console or RDP). If there is no active user or if multiple
// users are active, it returns empty string rather than guessing.
// It never falls back to the LocalSystem service identity.
func CurrentInteractiveUser() string {
	sess, err := ResolveInteractiveSession()
	if err != nil || sess == nil {
		return ""
	}
	return sess.Username
}

func queryWTSUsername(sessionID uint32) string {
	var buffer *uint16
	var bytesReturned uint32
	// WTSUserName is information class 5. WTS owns the returned buffer.
	result, _, _ := procWTSQuerySessionInformation.Call(
		0, uintptr(sessionID), 5,
		uintptr(unsafe.Pointer(&buffer)), uintptr(unsafe.Pointer(&bytesReturned)),
	)
	if result == 0 || buffer == nil {
		return ""
	}
	defer windows.WTSFreeMemory(uintptr(unsafe.Pointer(buffer)))
	return windows.UTF16PtrToString(buffer)
}
