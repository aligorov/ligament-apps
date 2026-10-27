//go:build darwin || linux

package linkagent

import (
	"os"
	"path/filepath"
)

func defaultUpdateCacheDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "/tmp/ligament_cache"
	}
	return filepath.Join(home, ".ligament", "cache")
}

func executeInstallerDetached(msiPath string, waitSeconds int) error {
	workerLog("[UPDATE MGR] Unix detached installer simulated for: %s (wait: %d s)", msiPath, waitSeconds)
	return nil
}
