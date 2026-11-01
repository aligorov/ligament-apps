package linkagent

import (
	"fmt"
	"net"
	"strings"
)

// WTS Connection States from Win32 WTS_CONNECTSTATE_CLASS
const (
	WTSActive       uint32 = 0
	WTSConnected    uint32 = 1
	WTSConnectQuery uint32 = 2
	WTSShadow       uint32 = 3
	WTSDisconnected uint32 = 4
	WTSIdle         uint32 = 5
	WTSListen       uint32 = 6
	WTSReset        uint32 = 7
	WTSDown         uint32 = 8
	WTSInit         uint32 = 9
)

// WTS Protocol Types
const (
	WTSProtocolConsole uint16 = 0
	WTSProtocolICA     uint16 = 1
	WTSProtocolRDP     uint16 = 2
)

// WTSSession represents an interactive or remote desktop session on a Windows Terminal Server.
type WTSSession struct {
	SessionID    uint32 `json:"session_id"`
	StationName  string `json:"station_name"`
	State        uint32 `json:"state"`
	StateName    string `json:"state_name"`
	Username     string `json:"username"`
	Domain       string `json:"domain"`
	ClientIP     string `json:"client_ip,omitempty"`
	ClientName   string `json:"client_name,omitempty"`
	ProtocolType uint16 `json:"protocol_type"`
	IsRDP        bool   `json:"is_rdp"`
	IsConsole    bool   `json:"is_console"`
	IsActive     bool   `json:"is_active"`
}

// UserAccount returns DOMAIN\username or username.
func (s WTSSession) UserAccount() string {
	if s.Domain != "" && s.Username != "" {
		return strings.ToUpper(s.Domain) + "\\" + s.Username
	}
	return s.Username
}

func wtsStateName(state uint32) string {
	switch state {
	case WTSActive:
		return "Active"
	case WTSConnected:
		return "Connected"
	case WTSConnectQuery:
		return "ConnectQuery"
	case WTSShadow:
		return "Shadow"
	case WTSDisconnected:
		return "Disconnected"
	case WTSIdle:
		return "Idle"
	case WTSListen:
		return "Listen"
	case WTSReset:
		return "Reset"
	case WTSDown:
		return "Down"
	case WTSInit:
		return "Init"
	default:
		return fmt.Sprintf("Unknown(%d)", state)
	}
}

// parseWTSClientAddress parses raw bytes from WTS_CLIENT_ADDRESS structure.
// In Win32:
// struct WTS_CLIENT_ADDRESS {
//     DWORD AddressFamily; // 2 = AF_INET, 23 = AF_INET6
//     BYTE  Address[20];
// }
func parseWTSClientAddress(family uint32, raw []byte) string {
	const afINET = 2
	const afINET6 = 23

	if family == afINET && len(raw) >= 6 {
		// In AF_INET, WTS stores IP bytes starting at index 2 (matching sockaddr sin_addr offset)
		ip := net.IPv4(raw[2], raw[3], raw[4], raw[5])
		if !ip.IsUnspecified() && !ip.IsLoopback() {
			return ip.String()
		}
	} else if family == afINET6 && len(raw) >= 18 {
		ip := net.IP(raw[2:18])
		if !ip.IsUnspecified() && !ip.IsLoopback() {
			return ip.String()
		}
	}
	return ""
}
