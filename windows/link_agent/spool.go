package linkagent

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// SpooledBatch represents a batch of frames/events stored on local disk.
type SpooledBatch struct {
	SessionID  string    `json:"session_id"`
	BatchIndex int64     `json:"batch_index"`
	CreatedAt  time.Time `json:"created_at"`
	Payload    []byte    `json:"payload"`
	FilePath   string    `json:"-"`
	ByteSize   int64     `json:"-"`
}

// DiskSpooler manages temporary local disk persistence for session recordings
// during network drops or Recorder outages.
type DiskSpooler struct {
	baseDir  string
	maxBytes int64
	mu       sync.Mutex
}

// NewDiskSpooler initializes a spooler rooted at baseDir with maxBytes quota limit.
func NewDiskSpooler(baseDir string, maxBytes int64) (*DiskSpooler, error) {
	if baseDir == "" {
		baseDir = defaultSpoolDirectory()
	}
	if maxBytes <= 0 {
		maxBytes = 5 * 1024 * 1024 * 1024 // 5 GB default quota
	}
	if err := ensureSecureDirectory(baseDir); err != nil {
		return nil, fmt.Errorf("spooler: ensure base dir %s: %w", baseDir, err)
	}
	return &DiskSpooler{
		baseDir:  baseDir,
		maxBytes: maxBytes,
	}, nil
}

// WriteBatch persists an unconfirmed batch to disk under baseDir/{sessionID}/{index}.chunk.
func (s *DiskSpooler) WriteBatch(sessionID string, batchIndex int64, payload []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	sessionDir := filepath.Join(s.baseDir, sessionID)
	if err := ensureSecureDirectory(sessionDir); err != nil {
		return fmt.Errorf("spooler: ensure session dir: %w", err)
	}

	fileName := fmt.Sprintf("%012d.chunk", batchIndex)
	filePath := filepath.Join(sessionDir, fileName)
	tempPath := filePath + ".tmp"

	record := SpooledBatch{
		SessionID:  sessionID,
		BatchIndex: batchIndex,
		CreatedAt:  time.Now().UTC(),
		Payload:    payload,
	}

	data, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("spooler: marshal batch: %w", err)
	}

	if err := os.WriteFile(tempPath, data, 0o600); err != nil {
		return fmt.Errorf("spooler: write temp chunk: %w", err)
	}

	if err := os.Rename(tempPath, filePath); err != nil {
		_ = os.Remove(tempPath)
		return fmt.Errorf("spooler: commit chunk: %w", err)
	}

	s.enforceQuotaLocked(sessionID)
	return nil
}

// ReadPendingBatches returns all spooled batches for sessionID sorted by batch index ascending.
func (s *DiskSpooler) ReadPendingBatches(sessionID string) ([]SpooledBatch, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	sessionDir := filepath.Join(s.baseDir, sessionID)
	entries, err := os.ReadDir(sessionDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}

	batches := make([]SpooledBatch, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".chunk" {
			continue
		}
		path := filepath.Join(sessionDir, entry.Name())
		info, err := entry.Info()
		if err != nil {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var record SpooledBatch
		if err := json.Unmarshal(data, &record); err != nil {
			continue
		}
		record.FilePath = path
		record.ByteSize = info.Size()
		batches = append(batches, record)
	}

	sort.Slice(batches, func(i, j int) bool {
		return batches[i].BatchIndex < batches[j].BatchIndex
	})

	return batches, nil
}

// RemoveBatch deletes an acknowledged batch file from disk.
func (s *DiskSpooler) RemoveBatch(filePath string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return os.Remove(filePath)
}

// RemoveSession deletes the entire session directory after complete/drain.
func (s *DiskSpooler) RemoveSession(sessionID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	sessionDir := filepath.Join(s.baseDir, sessionID)
	return os.RemoveAll(sessionDir)
}

// enforceQuotaLocked prunes oldest session directories if total spool size exceeds maxBytes,
// preserving the currently active session.
func (s *DiskSpooler) enforceQuotaLocked(protectSessionID string) {
	var totalBytes int64
	type dirInfo struct {
		id      string
		path    string
		modTime time.Time
		size    int64
	}
	var dirs []dirInfo

	sessions, err := os.ReadDir(s.baseDir)
	if err != nil {
		return
	}

	for _, sess := range sessions {
		if !sess.IsDir() {
			continue
		}
		dirPath := filepath.Join(s.baseDir, sess.Name())
		var dirSize int64
		var oldest time.Time
		chunks, cErr := os.ReadDir(dirPath)
		if cErr != nil {
			continue
		}
		for _, c := range chunks {
			if info, iErr := c.Info(); iErr == nil {
				dirSize += info.Size()
				if oldest.IsZero() || info.ModTime().Before(oldest) {
					oldest = info.ModTime()
				}
			}
		}
		totalBytes += dirSize
		dirs = append(dirs, dirInfo{id: sess.Name(), path: dirPath, modTime: oldest, size: dirSize})
	}

	if totalBytes <= s.maxBytes {
		return
	}

	// Sort oldest first
	sort.Slice(dirs, func(i, j int) bool {
		return dirs[i].modTime.Before(dirs[j].modTime)
	})

	for _, d := range dirs {
		if totalBytes <= s.maxBytes {
			break
		}
		if d.id == protectSessionID {
			// Do not evict the currently active session that just wrote data
			continue
		}
		_ = os.RemoveAll(d.path)
		totalBytes -= d.size
	}
}
