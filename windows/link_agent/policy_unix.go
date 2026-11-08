//go:build !windows

package linkagent

// ReadHostPolicyStatus returns default zero values on non-Windows platforms.
func ReadHostPolicyStatus() HostPolicyStatus {
	return HostPolicyStatus{}
}

// ApplyHostPolicy is a no-op stub on non-Windows platforms.
func ApplyHostPolicy(cmd ApplyPolicyCommand) error {
	return nil
}
