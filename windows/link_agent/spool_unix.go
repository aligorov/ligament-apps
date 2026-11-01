//go:build !windows

package linkagent

import (
	"os"
	"path/filepath"
)

func defaultSpoolDirectory() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "/tmp/ligament/spool"
	}
	return filepath.Join(home, ".ligament", "spool")
}

func ensureSecureDirectory(dir string) error {
	return os.MkdirAll(dir, 0o700)
}
