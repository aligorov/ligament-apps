//go:build windows

package linkagent

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

var wtsapi = windows.NewLazySystemDLL("wtsapi32.dll")
var procWTSQuerySessionInformation = wtsapi.NewProc("WTSQuerySessionInformationW")
var procWTSEnumerateSessions = wtsapi.NewProc("WTSEnumerateSessionsW")

type wtsSessionInfo struct {
	SessionID       uint32
	WinStationName  *uint16
	ConnectionState uint32
}

// CurrentInteractiveUser returns the username of an active interactive WTS
// session, preferring the physical console and supporting active RDP sessions.
// It never falls back to the LocalSystem service identity.
func CurrentInteractiveUser() string {
	if procWTSEnumerateSessions.Find() != nil || procWTSQuerySessionInformation.Find() != nil {
		return ""
	}
	var sessions *wtsSessionInfo
	var count uint32
	result, _, _ := procWTSEnumerateSessions.Call(0, 0, 1,
		uintptr(unsafe.Pointer(&sessions)), uintptr(unsafe.Pointer(&count)))
	if result == 0 || sessions == nil || count == 0 || count > 1024 {
		return ""
	}
	defer windows.WTSFreeMemory(uintptr(unsafe.Pointer(sessions)))
	active := make([]uint32, 0, count)
	for _, session := range unsafe.Slice(sessions, count) {
		if session.ConnectionState == 0 { // WTSActive
			active = append(active, session.SessionID)
		}
	}
	consoleSession := windows.WTSGetActiveConsoleSessionId()
	if consoleSession != 0xffffffff {
		for index, id := range active {
			if id == consoleSession {
				active[0], active[index] = active[index], active[0]
				break
			}
		}
	}
	for _, sessionID := range active {
		if username := queryWTSUsername(sessionID); username != "" {
			return username
		}
	}
	return ""
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
