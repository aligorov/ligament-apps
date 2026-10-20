package linkagent

const (
	wtsConsoleConnect       uint32 = 1
	wtsConsoleDisconnect    uint32 = 2
	wtsRemoteConnect        uint32 = 3
	wtsRemoteDisconnect     uint32 = 4
	wtsSessionLogon         uint32 = 5
	wtsSessionLogoff        uint32 = 6
	wtsSessionLock          uint32 = 7
	wtsSessionUnlock        uint32 = 8
	wtsSessionRemoteControl uint32 = 9
	wtsSessionCreate        uint32 = 10
	wtsSessionTerminate     uint32 = 11
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
