//go:build !windows

package linkagent

// CollectHostTelemetry returns zeroed telemetry metrics on non-Windows platforms.
func CollectHostTelemetry() HostTelemetry {
	return HostTelemetry{}
}
