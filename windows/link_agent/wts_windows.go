//go:build windows

package linkagent

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	procWTSDisconnectSession = wtsapi.NewProc("WTSDisconnectSession")
	procWTSLogoffSession     = wtsapi.NewProc("WTSLogoffSession")
)

const (
	wtsInfoUserName       = 5
	wtsInfoWinStationName = 6
	wtsInfoDomainName     = 7
	wtsInfoClientName     = 10
	wtsInfoClientAddress  = 14
	wtsInfoClientProtocol = 16
	wtsInfoSessionInfoEx  = 25
)

type win32WTSClientAddress struct {
	AddressFamily uint32
	Address       [20]byte
}

var enumerateAllWTSSessions = defaultEnumerateAllWTSSessions

// EnumerateAllWTSSessions queries all WTS sessions on the local system (Console & RDP),
// returning detailed session metadata for monitoring and recording.
func EnumerateAllWTSSessions() ([]WTSSession, error) {
	return enumerateAllWTSSessions()
}

func defaultEnumerateAllWTSSessions() ([]WTSSession, error) {
	if procWTSEnumerateSessions.Find() != nil || procWTSQuerySessionInformation.Find() != nil {
		return nil, errors.New("link agent: WTS API unavailable")
	}
	var rawSessions *wtsSessionInfo
	var count uint32
	result, _, _ := procWTSEnumerateSessions.Call(0, 0, 1,
		uintptr(unsafe.Pointer(&rawSessions)), uintptr(unsafe.Pointer(&count)))
	if result == 0 || rawSessions == nil || count == 0 || count > 2048 {
		return nil, nil
	}
	defer windows.WTSFreeMemory(uintptr(unsafe.Pointer(rawSessions)))

	sessions := make([]WTSSession, 0, count)
	for _, raw := range unsafe.Slice(rawSessions, count) {
		if raw.SessionID == 0 {
			// Session 0 is reserved for non-interactive system services
			continue
		}
		station := ""
		if raw.WinStationName != nil {
			station = windows.UTF16PtrToString(raw.WinStationName)
		}
		session := WTSSession{
			SessionID:   raw.SessionID,
			StationName: station,
			State:       raw.ConnectionState,
			StateName:   wtsStateName(raw.ConnectionState),
			IsActive:    raw.ConnectionState == WTSActive,
		}

		// Enrich session metadata
		session.Username = queryWTSString(raw.SessionID, wtsInfoUserName)
		session.Domain = queryWTSString(raw.SessionID, wtsInfoDomainName)
		session.ClientName = queryWTSString(raw.SessionID, wtsInfoClientName)
		session.ProtocolType = queryWTSProtocolType(raw.SessionID)
		session.ClientIP = queryWTSClientIP(raw.SessionID)
		session.IsRDP = session.ProtocolType == WTSProtocolRDP ||
			strings.HasPrefix(strings.ToUpper(session.StationName), "RDP-") ||
			session.ClientIP != ""
		if session.IsRDP && session.ProtocolType == 0 {
			session.ProtocolType = WTSProtocolRDP
		}
		session.IsConsole = !session.IsRDP && session.ProtocolType == WTSProtocolConsole
		session.IsLocked, session.LogonTime = queryWTSSessionLockAndLogon(raw.SessionID)

		sessions = append(sessions, session)
	}
	return sessions, nil
}

// LockWTSSession locks an active workstation session without ripping GPU/DWM.
func LockWTSSession(session WTSSession) error {
	if session.IsRDP {
		return DisconnectWTSSession(session.SessionID, false)
	}
	return LockConsoleSession(session.SessionID)
}

// LogoffWTSSession terminates a WTS session.
func LogoffWTSSession(sessionID uint32, wait bool) error {
	if procWTSLogoffSession.Find() != nil {
		return errors.New("link agent: WTSLogoffSession API unavailable")
	}
	waitVal := uintptr(0)
	if wait {
		waitVal = 1
	}
	r, _, err := procWTSLogoffSession.Call(0, uintptr(sessionID), waitVal)
	if r == 0 {
		return err
	}
	return nil
}

// LockConsoleSession launches rundll32.exe user32.dll,LockWorkStation via CreateProcessAsUserW.
func LockConsoleSession(sessionID uint32) error {
	token, err := systemTokenForSession(sessionID)
	if err != nil {
		return fmt.Errorf("link agent: get session token for lock: %w", err)
	}
	defer token.Close()

	sysDir, err := windows.GetSystemDirectory()
	if err != nil {
		sysDir = `C:\Windows\System32`
	}
	appPath := filepath.Join(sysDir, "rundll32.exe")
	app, _ := windows.UTF16PtrFromString(appPath)
	cmd, _ := windows.UTF16PtrFromString(fmt.Sprintf(`"%s" user32.dll,LockWorkStation`, appPath))
	desktop, _ := windows.UTF16PtrFromString(`winsta0\default`)
	dir, _ := windows.UTF16PtrFromString(sysDir)

	startup := windows.StartupInfo{
		Cb:         uint32(unsafe.Sizeof(windows.StartupInfo{})),
		Desktop:    desktop,
		Flags:      windows.STARTF_USESHOWWINDOW,
		ShowWindow: windows.SW_HIDE,
	}
	var created windows.ProcessInformation
	if err := windows.CreateProcessAsUser(token, app, cmd, nil, nil, false,
		0, nil, dir, &startup, &created); err != nil {
		return fmt.Errorf("link agent: launch LockWorkStation: %w", err)
	}
	_ = windows.CloseHandle(created.Thread)
	_ = windows.CloseHandle(created.Process)
	return nil
}

func queryWTSSessionLockAndLogon(sessionID uint32) (bool, time.Time) {
	if procWTSQuerySessionInformation.Find() != nil {
		return false, time.Time{}
	}
	var buffer *byte
	var bytesReturned uint32
	result, _, _ := procWTSQuerySessionInformation.Call(
		0, uintptr(sessionID), wtsInfoSessionInfoEx,
		uintptr(unsafe.Pointer(&buffer)), uintptr(unsafe.Pointer(&bytesReturned)),
	)
	if result == 0 || buffer == nil {
		return false, time.Time{}
	}
	defer windows.WTSFreeMemory(uintptr(unsafe.Pointer(buffer)))

	if bytesReturned < 20 {
		return false, time.Time{}
	}

	var sessionFlags int32 = -1
	idAt4 := *(*uint32)(unsafe.Pointer(uintptr(unsafe.Pointer(buffer)) + 4))
	idAt8 := *(*uint32)(unsafe.Pointer(uintptr(unsafe.Pointer(buffer)) + 8))
	var dataOffset uintptr = 0
	if idAt8 == sessionID {
		dataOffset = 8
		sessionFlags = *(*int32)(unsafe.Pointer(uintptr(unsafe.Pointer(buffer)) + 16))
	} else if idAt4 == sessionID {
		dataOffset = 4
		sessionFlags = *(*int32)(unsafe.Pointer(uintptr(unsafe.Pointer(buffer)) + 12))
	}

	isLocked := (sessionFlags == 0) // WTS_SESSIONSTATE_LOCK = 0

	var logonTime time.Time
	if dataOffset > 0 && bytesReturned >= uint32(dataOffset+12+144+32) {
		logonOffset := dataOffset + 12 + 144 + 24
		rawFT := *(*uint64)(unsafe.Pointer(uintptr(unsafe.Pointer(buffer)) + logonOffset))
		if rawFT > 116444736000000000 {
			nsec := (int64(rawFT) - 116444736000000000) * 100
			logonTime = time.Unix(0, nsec)
		}
	}
	return isLocked, logonTime
}

// DisconnectWTSSession disconnects an active RDP session.
func DisconnectWTSSession(sessionID uint32, wait bool) error {
	if procWTSDisconnectSession.Find() != nil {
		return errors.New("link agent: WTSDisconnectSession API unavailable")
	}
	waitVal := uintptr(0)
	if wait {
		waitVal = 1
	}
	r, _, err := procWTSDisconnectSession.Call(0, uintptr(sessionID), waitVal)
	if r == 0 {
		return err
	}
	return nil
}

func queryWTSString(sessionID uint32, infoClass uint32) string {
	var buffer *uint16
	var bytesReturned uint32
	result, _, _ := procWTSQuerySessionInformation.Call(
		0, uintptr(sessionID), uintptr(infoClass),
		uintptr(unsafe.Pointer(&buffer)), uintptr(unsafe.Pointer(&bytesReturned)),
	)
	if result == 0 || buffer == nil {
		return ""
	}
	defer windows.WTSFreeMemory(uintptr(unsafe.Pointer(buffer)))
	return windows.UTF16PtrToString(buffer)
}

func queryWTSProtocolType(sessionID uint32) uint16 {
	var buffer *uint16
	var bytesReturned uint32
	result, _, _ := procWTSQuerySessionInformation.Call(
		0, uintptr(sessionID), wtsInfoClientProtocol,
		uintptr(unsafe.Pointer(&buffer)), uintptr(unsafe.Pointer(&bytesReturned)),
	)
	if result == 0 || buffer == nil {
		return 0
	}
	defer windows.WTSFreeMemory(uintptr(unsafe.Pointer(buffer)))
	protocol, ok := decodeWTSClientProtocolType(buffer, bytesReturned)
	if !ok {
		return 0
	}
	return protocol
}

func queryWTSClientIP(sessionID uint32) string {
	var buffer *win32WTSClientAddress
	var bytesReturned uint32
	result, _, _ := procWTSQuerySessionInformation.Call(
		0, uintptr(sessionID), wtsInfoClientAddress,
		uintptr(unsafe.Pointer(&buffer)), uintptr(unsafe.Pointer(&bytesReturned)),
	)
	if result == 0 || buffer == nil || bytesReturned < uint32(unsafe.Sizeof(*buffer)) {
		return ""
	}
	defer windows.WTSFreeMemory(uintptr(unsafe.Pointer(buffer)))
	return parseWTSClientAddress(buffer.AddressFamily, buffer.Address[:])
}
