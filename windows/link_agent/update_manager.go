package linkagent

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// UpdateManager координирует предзагрузку и установку релизных пакетов ПК.
type UpdateManager struct {
	mu       sync.Mutex
	cacheDir string
	status   string
	version  string
	progress int
	lastErr  string
}

func NewUpdateManager(cacheDir string) *UpdateManager {
	if cacheDir == "" {
		cacheDir = defaultUpdateCacheDir()
	}
	_ = os.MkdirAll(cacheDir, 0755)
	return &UpdateManager{
		cacheDir: cacheDir,
		status:   "idle",
	}
}

// StageUpdate скачивает пакет во временный кэш и сверяет SHA-256.
func (m *UpdateManager) StageUpdate(ctx context.Context, rawServerURL, rawDownloadURL, version, expectedSHA string, send func(any) error) error {
	m.mu.Lock()
	if m.status == "staging" || m.status == "applying" {
		m.mu.Unlock()
		return errors.New("update already in progress")
	}
	m.status = "staging"
	m.version = version
	m.progress = 0
	m.lastErr = ""
	m.mu.Unlock()

	m.notify(send, "staging", version, 0, "")

	fullURL, err := resolvePackageURL(rawServerURL, rawDownloadURL)
	if err != nil {
		m.fail(send, version, fmt.Sprintf("invalid download URL: %v", err))
		return err
	}

	targetPath := filepath.Join(m.cacheDir, fmt.Sprintf("ligament_%s.msi", version))
	tempPath := targetPath + ".tmp"

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fullURL, nil)
	if err != nil {
		m.fail(send, version, fmt.Sprintf("create download request: %v", err))
		return err
	}

	client := &http.Client{Timeout: 15 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		m.fail(send, version, fmt.Sprintf("download failed: %v", err))
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		m.fail(send, version, fmt.Sprintf("server HTTP %d", resp.StatusCode))
		return fmt.Errorf("server returned HTTP %d", resp.StatusCode)
	}

	out, err := os.Create(tempPath)
	if err != nil {
		m.fail(send, version, fmt.Sprintf("create temp file: %v", err))
		return err
	}
	defer func() {
		out.Close()
		_ = os.Remove(tempPath)
	}()

	hasher := sha256.New()
	writer := io.MultiWriter(out, hasher)

	totalBytes := resp.ContentLength
	var downloaded int64

	buf := make([]byte, 64*1024)
	lastReport := time.Now()

	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			if _, wErr := writer.Write(buf[:n]); wErr != nil {
				m.fail(send, version, fmt.Sprintf("write file: %v", wErr))
				return wErr
			}
			downloaded += int64(n)
			if totalBytes > 0 && time.Since(lastReport) > 2*time.Second {
				progress := int(float64(downloaded) / float64(totalBytes) * 100)
				m.notify(send, "staging", version, progress, "")
				lastReport = time.Now()
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				break
			}
			m.fail(send, version, fmt.Sprintf("stream read failed: %v", readErr))
			return readErr
		}
	}
	_ = out.Close()

	calculatedSHA := hex.EncodeToString(hasher.Sum(nil))
	if expectedSHA != "" && !strings.EqualFold(calculatedSHA, expectedSHA) {
		m.fail(send, version, fmt.Sprintf("sha256 mismatch: got %s, want %s", calculatedSHA, expectedSHA))
		return errors.New("sha256 checksum mismatch")
	}

	if err := os.Rename(tempPath, targetPath); err != nil {
		m.fail(send, version, fmt.Sprintf("rename temp file: %v", err))
		return err
	}

	m.mu.Lock()
	m.status = "staged"
	m.progress = 100
	m.mu.Unlock()

	m.notify(send, "staged", version, 100, "")
	return nil
}

// ApplyUpdate проверяет наличие пакета в кэше и запускает отвязанный установщик.
func (m *UpdateManager) ApplyUpdate(ctx context.Context, rawServerURL, rawDownloadURL, version string, deadlineSec int, send func(any) error) error {
	targetPath := filepath.Join(m.cacheDir, fmt.Sprintf("ligament_%s.msi", version))

	// Если пакета еще нет в кэше — докачиваем
	if _, err := os.Stat(targetPath); err != nil {
		if stageErr := m.StageUpdate(ctx, rawServerURL, rawDownloadURL, version, "", send); stageErr != nil {
			return stageErr
		}
	}

	m.mu.Lock()
	m.status = "applying"
	m.mu.Unlock()

	m.notify(send, "applying", version, 100, "")

	if deadlineSec <= 0 {
		deadlineSec = 15
	}

	return executeInstallerDetached(targetPath, deadlineSec)
}

func (m *UpdateManager) notify(send func(any) error, status, version string, progress int, errStr string) {
	if send == nil {
		return
	}
	_ = send(map[string]any{
		"type": "update_status",
		"payload": map[string]any{
			"status":   status,
			"version":  version,
			"progress": progress,
			"error":    errStr,
		},
	})
}

func (m *UpdateManager) fail(send func(any) error, version, errStr string) {
	m.mu.Lock()
	m.status = "failed"
	m.lastErr = errStr
	m.mu.Unlock()
	m.notify(send, "failed", version, 0, errStr)
}

func resolvePackageURL(base, path string) (string, error) {
	if strings.HasPrefix(path, "http://") || strings.HasPrefix(path, "https://") {
		return path, nil
	}
	baseURL, err := url.Parse(base)
	if err != nil {
		return "", err
	}
	if baseURL.Scheme == "wss" {
		baseURL.Scheme = "https"
	} else if baseURL.Scheme == "ws" {
		baseURL.Scheme = "http"
	}
	relURL, err := url.Parse(path)
	if err != nil {
		return "", err
	}
	return baseURL.ResolveReference(relURL).String(), nil
}
