package linkagent

import (
	"image"
	"math/bits"
)

// IPC message types sent by CaptureWorker over the Named Pipe to Session 0 Supervisor
const (
	WorkerMsgFrame     = "frame"
	WorkerMsgEvent     = "event"
	WorkerMsgHeartbeat = "heartbeat"
)

// WorkerFrameMessage is the JSON envelope sent from worker to supervisor over Named Pipe.
type WorkerFrameMessage struct {
	Type          string `json:"type"` // "frame"
	Seq           int64  `json:"seq"`
	Width         int    `json:"width"`
	Height        int    `json:"height"`
	Codec         string `json:"codec"` // "jpeg"
	PayloadBase64 string `json:"payload_base64"`
	CapturedAt    string `json:"captured_at"`
	WindowTitle   string `json:"window_title,omitempty"`
	ProcessName   string `json:"process_name,omitempty"`
}

// WorkerEventMessage represents an interaction or OS lifecycle event sent over IPC.
type WorkerEventMessage struct {
	Type       string         `json:"type"` // "event"
	Seq        int64          `json:"seq"`
	EventKind  string         `json:"event_kind"`
	OccurredAt string         `json:"occurred_at"`
	Payload    map[string]any `json:"payload,omitempty"`
}

// ComputeDHash64 calculates a fast 64-bit difference hash (dHash) from an image.
// It samples a 9x8 grid of luminance values and computes horizontal gradients.
func ComputeDHash64(img image.Image) uint64 {
	bounds := img.Bounds()
	w := bounds.Dx()
	h := bounds.Dy()
	if w < 9 || h < 8 {
		return 0
	}

	var grid [8][9]uint32
	xStep := w / 9
	yStep := h / 8

	for r := 0; r < 8; r++ {
		y := bounds.Min.Y + r*yStep + yStep/2
		for c := 0; c < 9; c++ {
			x := bounds.Min.X + c*xStep + xStep/2
			rCol, gCol, bCol, _ := img.At(x, y).RGBA()
			// Fast standard grayscale conversion: 0.299R + 0.587G + 0.114B (scaled 16-bit)
			gray := (rCol*19595 + gCol*38469 + bCol*7472) >> 16
			grid[r][c] = gray
		}
	}

	var hash uint64
	bitIndex := 0
	for r := 0; r < 8; r++ {
		for c := 0; c < 8; c++ {
			if grid[r][c] > grid[r][c+1] {
				hash |= 1 << bitIndex
			}
			bitIndex++
		}
	}
	return hash
}

// DHashDistance computes the Hamming distance between two 64-bit hashes.
func DHashDistance(hash1, hash2 uint64) int {
	return bits.OnesCount64(hash1 ^ hash2)
}
