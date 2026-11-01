//go:build windows

package linkagent

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"path/filepath"
	"runtime"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	user32 = windows.NewLazySystemDLL("user32.dll")
	gdi32  = windows.NewLazySystemDLL("gdi32.dll")

	procGetDC                     = user32.NewProc("GetDC")
	procReleaseDC                 = user32.NewProc("ReleaseDC")
	procGetSystemMetrics          = user32.NewProc("GetSystemMetrics")
	procGetForegroundWindow       = user32.NewProc("GetForegroundWindow")
	procGetWindowTextW            = user32.NewProc("GetWindowTextW")
	procGetWindowThreadProcessId  = user32.NewProc("GetWindowThreadProcessId")
	procGetLastInputInfo          = user32.NewProc("GetLastInputInfo")
	procOpenInputDesktop          = user32.NewProc("OpenInputDesktop")
	procSetThreadDesktop          = user32.NewProc("SetThreadDesktop")
	procCloseDesktop              = user32.NewProc("CloseDesktop")
	procSetProcessDPIAware        = user32.NewProc("SetProcessDPIAware")
	procCreateCompatibleDC        = gdi32.NewProc("CreateCompatibleDC")
	procDeleteDC                  = gdi32.NewProc("DeleteDC")
	procCreateDIBSection          = gdi32.NewProc("CreateDIBSection")
	procSelectObject              = gdi32.NewProc("SelectObject")
	procDeleteObject              = gdi32.NewProc("DeleteObject")
	procBitBlt                    = gdi32.NewProc("BitBlt")
	procSetPriorityClass          = kernel32.NewProc("SetPriorityClass")
	procSetNamedPipeHandleState   = kernel32.NewProc("SetNamedPipeHandleState")
	procGetTickCount64            = kernel32.NewProc("GetTickCount64")
)

const (
	smCxVirtualScreen = 78
	smCyVirtualScreen = 79
	smXVirtualScreen  = 76
	smYVirtualScreen  = 77

	srccopy    = 0x00CC0020
	captureblt = 0x40000000

	belowNormalPriorityClass = 0x00004000
	pipeReadmodeMessage      = 0x00000002
)

type lastInputInfo struct {
	cbSize uint32
	dwTime uint32
}

type bitmapInfo struct {
	Header struct {
		Size          uint32
		Width         int32
		Height        int32
		Planes        uint16
		BitCount      uint16
		Compression   uint32
		SizeImage     uint32
		XPelsPerMeter int32
		YPelsPerMeter int32
		ClrUsed       uint32
		ClrImportant  uint32
	}
}

// RunCaptureWorker runs the headless screen capture loop inside a user RDP/WTS session.
func RunCaptureWorker(ctx context.Context, pipePath string, sessionID uint32, targetFPS float64, quality int) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	if procSetProcessDPIAware.Find() == nil {
		_, _, _ = procSetProcessDPIAware.Call()
	}
	if procSetPriorityClass.Find() == nil {
		curProcess, _ := windows.GetCurrentProcess()
		_, _, _ = procSetPriorityClass.Call(uintptr(curProcess), uintptr(belowNormalPriorityClass))
	}

	if targetFPS <= 0 || targetFPS > 5.0 {
		targetFPS = 1.0
	}
	if quality <= 0 || quality > 100 {
		quality = 65
	}

	// Connect to supervisor's Named Pipe
	pipePathUTF16, err := windows.UTF16PtrFromString(pipePath)
	if err != nil {
		return fmt.Errorf("worker: invalid pipe path: %w", err)
	}

	var pipeHandle windows.Handle
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		h, err := windows.CreateFile(
			pipePathUTF16,
			windows.GENERIC_READ|windows.GENERIC_WRITE,
			0,
			nil,
			windows.OPEN_EXISTING,
			0,
			0,
		)
		if err == nil {
			pipeHandle = h
			break
		}
		if !errors.Is(err, windows.ERROR_PIPE_BUSY) && !errors.Is(err, windows.ERROR_FILE_NOT_FOUND) {
			return fmt.Errorf("worker: connect pipe: %w", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	defer windows.CloseHandle(pipeHandle)

	// Set pipe to message mode
	mode := uint32(pipeReadmodeMessage)
	if procSetNamedPipeHandleState.Find() == nil {
		_, _, _ = procSetNamedPipeHandleState.Call(uintptr(pipeHandle), uintptr(unsafe.Pointer(&mode)), 0, 0)
	}

	var prevHash uint64
	var prevWinTitle, prevProcName string
	var seq int64
	lastHeartbeat := time.Now()

	frameInterval := time.Duration(float64(time.Second) / targetFPS)
	ticker := time.NewTicker(frameInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}

		// Adjust capture rate if user is idle
		idleSeconds := queryUserIdleSeconds()
		if idleSeconds > 10.0 {
			// Idle mode: capture only 1 frame every 10 seconds
			time.Sleep(time.Duration(10.0-1.0/targetFPS) * time.Second)
		}

		// Switch to active desktop (handles transitions between default and Winlogon)
		switchInputDesktopSafe()

		img, w, h, err := captureScreenGDI()
		if err != nil {
			continue
		}

		currentHash := ComputeDHash64(img)
		winTitle, procName := queryForegroundWindowDetails()

		contentChanged := seq == 0 || DHashDistance(currentHash, prevHash) > 0
		windowChanged := winTitle != prevWinTitle || procName != prevProcName

		if !contentChanged && !windowChanged {
			// Screen is identical. Send heartbeat every 5 seconds to keep pipe alive.
			if time.Since(lastHeartbeat) > 5*time.Second {
				_ = writeWorkerMessage(pipeHandle, map[string]any{"type": WorkerMsgHeartbeat, "ts": time.Now().UnixMilli()})
				lastHeartbeat = time.Now()
			}
			continue
		}

		// Content changed: encode to JPEG
		var jpegBuf bytes.Buffer
		if err := jpeg.Encode(&jpegBuf, img, &jpeg.Options{Quality: quality}); err != nil {
			continue
		}

		seq++
		msg := WorkerFrameMessage{
			Type:          WorkerMsgFrame,
			Seq:           seq,
			Width:         w,
			Height:        h,
			Codec:         "jpeg",
			PayloadBase64: base64.StdEncoding.EncodeToString(jpegBuf.Bytes()),
			CapturedAt:    time.Now().UTC().Format(time.RFC3339Nano),
			WindowTitle:   winTitle,
			ProcessName:   procName,
		}

		if err := writeWorkerMessage(pipeHandle, msg); err != nil {
			return fmt.Errorf("worker: pipe write failed: %w", err)
		}

		prevHash = currentHash
		prevWinTitle = winTitle
		prevProcName = procName
		lastHeartbeat = time.Now()
	}
}

var activeInputDesk windows.Handle

func switchInputDesktopSafe() {
	if procOpenInputDesktop.Find() != nil || procSetThreadDesktop.Find() != nil {
		return
	}
	r, _, _ := procOpenInputDesktop.Call(0, 0, uintptr(windows.GENERIC_ALL))
	if r == 0 {
		return
	}
	hDesk := windows.Handle(r)
	ret, _, _ := procSetThreadDesktop.Call(uintptr(hDesk))
	if ret != 0 {
		if activeInputDesk != 0 && procCloseDesktop.Find() == nil {
			_, _, _ = procCloseDesktop.Call(uintptr(activeInputDesk))
		}
		activeInputDesk = hDesk
	} else if procCloseDesktop.Find() == nil {
		_, _, _ = procCloseDesktop.Call(uintptr(hDesk))
	}
}

func queryUserIdleSeconds() float64 {
	if procGetLastInputInfo.Find() != nil || procGetTickCount64.Find() != nil {
		return 0
	}
	var info lastInputInfo
	info.cbSize = uint32(unsafe.Sizeof(info))
	r, _, _ := procGetLastInputInfo.Call(uintptr(unsafe.Pointer(&info)))
	if r == 0 {
		return 0
	}
	tick, _, _ := procGetTickCount64.Call()
	diff := uint64(tick) - uint64(info.dwTime)
	return float64(diff) / 1000.0
}

func queryForegroundWindowDetails() (string, string) {
	if procGetForegroundWindow.Find() != nil {
		return "", ""
	}
	hwnd, _, _ := procGetForegroundWindow.Call()
	if hwnd == 0 {
		return "", ""
	}

	// Window title
	var titleBuf [256]uint16
	procGetWindowTextW.Call(hwnd, uintptr(unsafe.Pointer(&titleBuf[0])), 256)
	title := windows.UTF16ToString(titleBuf[:])

	// Process name
	var pid uint32
	procGetWindowThreadProcessId.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
	if pid == 0 {
		return title, ""
	}

	hProc, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return title, ""
	}
	defer windows.CloseHandle(hProc)

	var exeBuf [windows.MAX_PATH]uint16
	exeLen := uint32(windows.MAX_PATH)
	if err := windows.QueryFullProcessImageName(hProc, 0, &exeBuf[0], &exeLen); err == nil && exeLen > 0 {
		fullPath := windows.UTF16ToString(exeBuf[:exeLen])
		return title, filepath.Base(fullPath)
	}
	return title, ""
}

func captureScreenGDI() (*image.RGBA, int, int, error) {
	if procGetDC.Find() != nil || procBitBlt.Find() != nil {
		return nil, 0, 0, errors.New("gdi: unavailable")
	}

	w := getSystemMetric(smCxVirtualScreen)
	h := getSystemMetric(smCyVirtualScreen)
	x := getSystemMetric(smXVirtualScreen)
	y := getSystemMetric(smYVirtualScreen)

	if w <= 0 || h <= 0 {
		w = getSystemMetric(0) // SM_CXSCREEN
		h = getSystemMetric(1) // SM_CYSCREEN
		x = 0
		y = 0
	}
	if w <= 0 || h <= 0 {
		return nil, 0, 0, errors.New("gdi: invalid screen dimensions")
	}

	hdcScreenR, _, _ := procGetDC.Call(0)
	if hdcScreenR == 0 {
		return nil, 0, 0, errors.New("gdi: GetDC failed")
	}
	hdcScreen := windows.Handle(hdcScreenR)
	defer procReleaseDC.Call(0, uintptr(hdcScreen))

	hdcMemR, _, _ := procCreateCompatibleDC.Call(uintptr(hdcScreen))
	if hdcMemR == 0 {
		return nil, 0, 0, errors.New("gdi: CreateCompatibleDC failed")
	}
	hdcMem := windows.Handle(hdcMemR)
	defer procDeleteDC.Call(uintptr(hdcMem))

	var bi bitmapInfo
	bi.Header.Size = uint32(unsafe.Sizeof(bi.Header))
	bi.Header.Width = int32(w)
	bi.Header.Height = -int32(h) // Top-down DIB
	bi.Header.Planes = 1
	bi.Header.BitCount = 32
	bi.Header.Compression = 0 // BI_RGB

	var pBits *byte
	hBmpR, _, _ := procCreateDIBSection.Call(
		uintptr(hdcScreen),
		uintptr(unsafe.Pointer(&bi)),
		0,
		uintptr(unsafe.Pointer(&pBits)),
		0,
		0,
	)
	if hBmpR == 0 || pBits == nil {
		return nil, 0, 0, errors.New("gdi: CreateDIBSection failed")
	}
	hBmp := windows.Handle(hBmpR)
	defer procDeleteObject.Call(uintptr(hBmp))

	procSelectObject.Call(uintptr(hdcMem), uintptr(hBmp))

	r, _, _ := procBitBlt.Call(
		uintptr(hdcMem), 0, 0, uintptr(w), uintptr(h),
		uintptr(hdcScreen), uintptr(x), uintptr(y),
		uintptr(srccopy|captureblt),
	)
	if r == 0 {
		return nil, 0, 0, errors.New("gdi: BitBlt failed")
	}

	stride := w * 4
	rawBytes := unsafe.Slice(pBits, w*h*4)
	img := &image.RGBA{
		Pix:    make([]byte, len(rawBytes)),
		Stride: stride,
		Rect:   image.Rect(0, 0, w, h),
	}

	// GDI 32-bit DIB is BGRA, convert to RGBA
	for i := 0; i < len(rawBytes); i += 4 {
		img.Pix[i] = rawBytes[i+2]   // R
		img.Pix[i+1] = rawBytes[i+1] // G
		img.Pix[i+2] = rawBytes[i]   // B
		img.Pix[i+3] = 0xFF          // A
	}

	return img, w, h, nil
}

func getSystemMetric(idx int) int {
	if procGetSystemMetrics.Find() != nil {
		return 0
	}
	r, _, _ := procGetSystemMetrics.Call(uintptr(idx))
	return int(int32(r))
}

func writeWorkerMessage(h windows.Handle, msg any) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	var written uint32
	return windows.WriteFile(h, data, &written, nil)
}
