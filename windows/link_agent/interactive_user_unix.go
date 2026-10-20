//go:build darwin || linux

package linkagent

import "os/user"

// CurrentInteractiveUser returns the account running the per-user Unix agent.
func CurrentInteractiveUser() string {
	current, err := user.Current()
	if err != nil {
		return ""
	}
	return current.Username
}
