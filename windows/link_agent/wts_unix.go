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
