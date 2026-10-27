//go:build windows

package linkagent

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func defaultUpdateCacheDir() string {
	progData := os.Getenv("ProgramData")
	if progData == "" {
		progData = `C:\ProgramData`
	}
	return filepath.Join(progData, "Ligament", "cache")
}

func executeInstallerDetached(msiPath string, waitSeconds int) error {
	progData := os.Getenv("ProgramData")
	if progData == "" {
		progData = `C:\ProgramData`
	}
	lockFile := filepath.Join(progData, "Ligament", "upgrading.lock")
	logFile := filepath.Join(progData, "Ligament", "update.log")

	// 1. Создаем lock-файл для сторожа
	_ = os.WriteFile(lockFile, []byte("upgrading"), 0644)

	// 2. Формируем команду тихого обновления и последующего снятия lock
	cmdLine := fmt.Sprintf(
		`timeout /t %d /nobreak >nul & msiexec.exe /i "%s" /qn /norestart /l*v "%s" & del "%s"`,
		waitSeconds, msiPath, logFile, lockFile,
	)

	cmd := exec.Command("cmd.exe", "/c", cmdLine)
	// Запуск отвязанным от процесса службы агента
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | 0x00000008, // DETACHED_PROCESS
	}

	return cmd.Start()
}
