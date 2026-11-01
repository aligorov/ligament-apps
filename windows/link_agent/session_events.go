package linkagent

// Windows Service Control Manager WTS Session Change notification constants
const (
	WTSConsoleConnect       uint32 = 1
	WTSConsoleDisconnect    uint32 = 2
	WTSRemoteConnect        uint32 = 3
	WTSRemoteDisconnect     uint32 = 4
	WTSSessionLogon         uint32 = 5
	WTSSessionLogoff        uint32 = 6
	WTSSessionLock          uint32 = 7
	WTSSessionUnlock        uint32 = 8
	WTSSessionRemoteControl uint32 = 9
	WTSSessionCreate        uint32 = 10
	WTSSessionTerminate     uint32 = 11
)

const (
	wtsConsoleConnect       = WTSConsoleConnect
	wtsConsoleDisconnect    = WTSConsoleDisconnect
	wtsRemoteConnect        = WTSRemoteConnect
	wtsRemoteDisconnect     = WTSRemoteDisconnect
	wtsSessionLogon         = WTSSessionLogon
	wtsSessionLogoff        = WTSSessionLogoff
	wtsSessionLock          = WTSSessionLock
	wtsSessionUnlock        = WTSSessionUnlock
	wtsSessionRemoteControl = WTSSessionRemoteControl
	wtsSessionCreate        = WTSSessionCreate
	wtsSessionTerminate     = WTSSessionTerminate
)

// SessionChangeName maps the WTS session notification values delivered by the
// Windows Service Control Manager to stable log labels. Unknown values remain
// visible so Windows-version-specific notifications are not silently dropped.
func SessionChangeName(eventType uint32) string {
	switch eventType {
	case wtsConsoleConnect:
		return "console_connect"
	case wtsConsoleDisconnect:
		return "console_disconnect"
	case wtsRemoteConnect:
		return "remote_connect"
	case wtsRemoteDisconnect:
		return "remote_disconnect"
	case wtsSessionLogon:
		return "session_logon"
	case wtsSessionLogoff:
		return "session_logoff"
	case wtsSessionLock:
		return "session_lock"
	case wtsSessionUnlock:
		return "session_unlock"
	case wtsSessionRemoteControl:
		return "session_remote_control"
	case wtsSessionCreate:
		return "session_create"
	case wtsSessionTerminate:
		return "session_terminate"
	default:
		return "unknown"
	}
}
