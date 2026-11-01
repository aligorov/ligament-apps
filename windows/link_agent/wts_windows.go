//go:build windows

package linkagent

import (
	"errors"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

var procWTSDisconnectSession = wtsapi.NewProc("WTSDisconnectSession")

const (
	wtsInfoUserName         = 5
	wtsInfoWinStationName   = 6
	wtsInfoDomainName       = 7
	wtsInfoClientName       = 10
	wtsInfoClientAddress    = 14
	wtsInfoClientProtocol   = 16
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
		session.IsRDP = session.ProtocolType == WTSProtocolRDP || strings.HasPrefix(strings.ToUpper(session.StationName), "RDP-")
		session.IsConsole = session.ProtocolType == WTSProtocolConsole
		session.ClientIP = queryWTSClientIP(raw.SessionID)

		sessions = append(sessions, session)
	}
	return sessions, nil
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
