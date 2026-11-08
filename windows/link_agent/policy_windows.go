//go:build windows

package linkagent

import (
	"fmt"

	"golang.org/x/sys/windows/registry"
)

const (
	regKey2FAPolicies = `SOFTWARE\Policies\Ligament\2FA`
	regKey2FALocal    = `SOFTWARE\Ligament\2FA`
)

// ReadHostPolicyStatus inspects both GPO and local registry hives to determine active 2FA flags.
func ReadHostPolicyStatus() HostPolicyStatus {
	var status HostPolicyStatus
	status.Console2FAEnabled, status.Console2FASource = readPolicyDWORD("Console2FAEnabled", 0)
	status.RDP2FAEnabled, status.RDP2FASource = readPolicyDWORD("Rdp2FAEnabled", 0)
	status.Elevation2FAEnabled, status.Elevation2FASource = readPolicyDWORD("Elevation2FAEnabled", 0)
	return status
}

func readPolicyDWORD(name string, defaultVal int) (int, string) {
	// 1. Check GPO Policies first (authoritative domain setting)
	if key, err := registry.OpenKey(registry.LOCAL_MACHINE, regKey2FAPolicies, registry.QUERY_VALUE|registry.WOW64_64KEY); err == nil {
		val, _, err := key.GetIntegerValue(name)
		_ = key.Close()
		if err == nil {
			return int(val), "gpo"
		}
	}
	// 2. Check local registry
	if key, err := registry.OpenKey(registry.LOCAL_MACHINE, regKey2FALocal, registry.QUERY_VALUE|registry.WOW64_64KEY); err == nil {
		val, _, err := key.GetIntegerValue(name)
		_ = key.Close()
		if err == nil {
			return int(val), "local"
		}
	}
	return defaultVal, "default"
}

// ApplyHostPolicy writes whitelisted 2FA parameters strictly to HKLM\SOFTWARE\Ligament\2FA.
// Rejects any unexpected registry paths or non-whitelisted keys.
func ApplyHostPolicy(cmd ApplyPolicyCommand) error {
	key, _, err := registry.CreateKey(registry.LOCAL_MACHINE, regKey2FALocal, registry.SET_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return fmt.Errorf("open HKLM\\%s for policy write: %w", regKey2FALocal, err)
	}
	defer key.Close()

	if cmd.Console2FAEnabled != nil {
		val := uint32(0)
		if *cmd.Console2FAEnabled != 0 {
			val = 1
		}
		if err := key.SetDWordValue("Console2FAEnabled", val); err != nil {
			return fmt.Errorf("write Console2FAEnabled: %w", err)
		}
	}
	if cmd.RDP2FAEnabled != nil {
		val := uint32(0)
		if *cmd.RDP2FAEnabled != 0 {
			val = 1
		}
		if err := key.SetDWordValue("Rdp2FAEnabled", val); err != nil {
			return fmt.Errorf("write Rdp2FAEnabled: %w", err)
		}
	}
	if cmd.Elevation2FAEnabled != nil {
		val := uint32(0)
		if *cmd.Elevation2FAEnabled != 0 {
			val = 1
		}
		if err := key.SetDWordValue("Elevation2FAEnabled", val); err != nil {
			return fmt.Errorf("write Elevation2FAEnabled: %w", err)
		}
	}
	return nil
}
