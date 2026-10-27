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
	ligamentDir := filepath.Join(progData, "Ligament")
	_ = os.MkdirAll(ligamentDir, 0755)

	lockFile := filepath.Join(ligamentDir, "upgrading.lock")
	logFile := filepath.Join(ligamentDir, "update.log")
	scriptFile := filepath.Join(ligamentDir, "run_upgrade.cmd")

	// 1. Создаем lock-файл для сторожа
	_ = os.WriteFile(lockFile, []byte("upgrading"), 0644)

	// 2. Формируем надёжный bat-скрипт (ping вместо timeout, т.к. в Session 0 timeout.exe падает)
	if waitSeconds <= 0 {
		waitSeconds = 5
	}
	scriptContent := fmt.Sprintf(
		"@echo off\r\n"+
			"ping 127.0.0.1 -n %d >nul\r\n"+
			"msiexec.exe /i \"%s\" /qn /norestart /l*v \"%s\"\r\n"+
			"del /f /q \"%s\"\r\n",
		waitSeconds+1, msiPath, logFile, lockFile,
	)
	if err := os.WriteFile(scriptFile, []byte(scriptContent), 0755); err != nil {
		return fmt.Errorf("write upgrade script: %w", err)
	}

	// 3. Запуск отвязанным от процесса службы агента с CREATE_NO_WINDOW
	cmd := exec.Command("cmd.exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CmdLine:       fmt.Sprintf(`cmd.exe /c "%s"`, scriptFile),
		HideWindow:    true,
		CreationFlags: 0x08000000 | syscall.CREATE_NEW_PROCESS_GROUP, // CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start detached upgrade script: %w", err)
	}

	// Освобождаем дескриптор процесса, чтобы служба не удерживала его
	if cmd.Process != nil {
		_ = cmd.Process.Release()
	}

	return nil
}
