//go:build windows

package linkagent

import (
	"os"
	"path/filepath"
)

func defaultSpoolDirectory() string {
	programData := os.Getenv("ProgramData")
	if programData == "" {
		programData = `C:\ProgramData`
	}
	return filepath.Join(programData, "Ligament", "Spool")
}

func ensureSecureDirectory(dir string) error {
	// In Windows, directories created in ProgramData inherit SYSTEM and Admin access.
	return os.MkdirAll(dir, 0o700)
}
