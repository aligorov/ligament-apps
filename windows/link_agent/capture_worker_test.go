package linkagent

import (
	"image"
	"image/color"
	"testing"
)

func TestDHash64(t *testing.T) {
	// Create uniform image 100x100
	img1 := image.NewRGBA(image.Rect(0, 0, 100, 100))
	for y := 0; y < 100; y++ {
		for x := 0; x < 100; x++ {
			img1.Set(x, y, color.RGBA{R: uint8(x * 2), G: 100, B: 50, A: 255})
		}
	}

	hash1 := ComputeDHash64(img1)
	hash1Copy := ComputeDHash64(img1)

	if hash1 != hash1Copy {
		t.Fatalf("hash non-deterministic: %x vs %x", hash1, hash1Copy)
	}

	if dist := DHashDistance(hash1, hash1Copy); dist != 0 {
		t.Fatalf("distance between identical images: %d, want 0", dist)
	}

	// Create inverted gradient image
	img2 := image.NewRGBA(image.Rect(0, 0, 100, 100))
	for y := 0; y < 100; y++ {
		for x := 0; x < 100; x++ {
			img2.Set(x, y, color.RGBA{R: uint8((100 - x) * 2), G: 100, B: 50, A: 255})
		}
	}

	hash2 := ComputeDHash64(img2)
	dist := DHashDistance(hash1, hash2)
	if dist == 0 {
		t.Fatalf("distance between different images: %d, want > 0", dist)
	}
}
