//go:build !windows

package linkagent

import "errors"

var enumerateAllWTSSessions = defaultEnumerateAllWTSSessions

// EnumerateAllWTSSessions stub for non-Windows platforms.
func EnumerateAllWTSSessions() ([]WTSSession, error) {
	return enumerateAllWTSSessions()
}

func defaultEnumerateAllWTSSessions() ([]WTSSession, error) {
	return nil, nil
}

// DisconnectWTSSession stub for non-Windows platforms.
func DisconnectWTSSession(sessionID uint32, wait bool) error {
	return errors.New("wts: not supported on non-windows platform")
}

// LockWTSSession stub for non-Windows platforms.
func LockWTSSession(session WTSSession) error {
	return nil
}

// LogoffWTSSession stub for non-Windows platforms.
func LogoffWTSSession(sessionID uint32, wait bool) error {
	return nil
}

// LockConsoleSession stub for non-Windows platforms.
func LockConsoleSession(sessionID uint32) error {
	return nil
}
