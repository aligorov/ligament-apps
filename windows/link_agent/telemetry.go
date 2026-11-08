package linkagent

// HostTelemetry represents current hardware and session metrics of the computer.
type HostTelemetry struct {
	UptimeSeconds   int64        `json:"uptime_seconds"`
	CPUUsagePercent int          `json:"cpu_usage_percent"`
	RAMUsedMB       int          `json:"ram_used_mb"`
	RAMTotalMB      int          `json:"ram_total_mb"`
	DiskTotalGB     int          `json:"disk_total_gb"`
	DiskFreeGB      int          `json:"disk_free_gb"`
	IsDomainJoined  bool         `json:"is_domain_joined"`
	Sessions        []WTSSession `json:"sessions"`
}
