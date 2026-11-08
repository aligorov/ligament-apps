package linkagent

// HostPolicyStatus reflects the currently enforced 2FA logon settings and their configuration provenance.
type HostPolicyStatus struct {
	Console2FAEnabled   int    `json:"console_2fa_enabled"`
	Console2FASource    string `json:"console_2fa_source"` // "gpo", "local", "default"
	RDP2FAEnabled       int    `json:"rdp_2fa_enabled"`
	RDP2FASource        string `json:"rdp_2fa_source"`
	Elevation2FAEnabled int    `json:"elevation_2fa_enabled"`
	Elevation2FASource  string `json:"elevation_2fa_source"`
}

// ApplyPolicyCommand instructs the host agent to write whitelisted 2FA settings to the local registry.
type ApplyPolicyCommand struct {
	CommandID           string `json:"command_id"`
	Console2FAEnabled   *int   `json:"console_2fa_enabled"`
	RDP2FAEnabled       *int   `json:"rdp_2fa_enabled"`
	Elevation2FAEnabled *int   `json:"elevation_2fa_enabled"`
}
