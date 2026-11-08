//go:build windows

package linkagent

import (
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	modkernel32            = windows.NewLazySystemDLL("kernel32.dll")
	procGetSystemTimes     = modkernel32.NewProc("GetSystemTimes")
	procGlobalMemoryStatus = modkernel32.NewProc("GlobalMemoryStatusEx")
	procGetDiskFreeSpaceEx = modkernel32.NewProc("GetDiskFreeSpaceExW")

	modnetapi32          = windows.NewLazySystemDLL("netapi32.dll")
	procNetGetJoinInfo   = modnetapi32.NewProc("NetGetJoinInformation")
	procNetApiBufferFree = modnetapi32.NewProc("NetApiBufferFree")

	cpuTimesMu       sync.Mutex
	lastKernelTime   uint64
	lastUserTime     uint64
	lastIdleTime     uint64
	lastCPUSample    time.Time
	cachedCPUPercent int
)

type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

// CollectHostTelemetry captures lightweight Win32 host metrics with zero WMI overhead.
func CollectHostTelemetry() HostTelemetry {
	var t HostTelemetry

	// 1. Uptime
	if procGetTickCount64.Find() == nil {
		r, _, _ := procGetTickCount64.Call()
		t.UptimeSeconds = int64(r / 1000)
	}

	// 2. CPU usage delta
	t.CPUUsagePercent = sampleCPUUsage()

	// 3. RAM usage
	if procGlobalMemoryStatus.Find() == nil {
		var mem memoryStatusEx
		mem.Length = uint32(unsafe.Sizeof(mem))
		r, _, _ := procGlobalMemoryStatus.Call(uintptr(unsafe.Pointer(&mem)))
		if r != 0 {
			t.RAMTotalMB = int(mem.TotalPhys / (1024 * 1024))
			t.RAMUsedMB = int((mem.TotalPhys - mem.AvailPhys) / (1024 * 1024))
		}
	}

	// 4. Disk C: usage
	if procGetDiskFreeSpaceEx.Find() == nil {
		var freeBytesAvailable, totalNumberOfBytes, totalNumberOfFreeBytes uint64
		pathPtr, err := windows.UTF16PtrFromString("C:\\")
		if err == nil {
			r, _, _ := procGetDiskFreeSpaceEx.Call(
				uintptr(unsafe.Pointer(pathPtr)),
				uintptr(unsafe.Pointer(&freeBytesAvailable)),
				uintptr(unsafe.Pointer(&totalNumberOfBytes)),
				uintptr(unsafe.Pointer(&totalNumberOfFreeBytes)),
			)
			if r != 0 {
				t.DiskTotalGB = int(totalNumberOfBytes / (1024 * 1024 * 1024))
				t.DiskFreeGB = int(freeBytesAvailable / (1024 * 1024 * 1024))
			}
		}
	}

	// 5. Domain joined status
	if procNetGetJoinInfo.Find() == nil {
		var nameBuffer *uint16
		var joinStatus uint32
		r, _, _ := procNetGetJoinInfo.Call(
			0,
			uintptr(unsafe.Pointer(&nameBuffer)),
			uintptr(unsafe.Pointer(&joinStatus)),
		)
		if r == 0 {
			if nameBuffer != nil && procNetApiBufferFree.Find() == nil {
				_, _, _ = procNetApiBufferFree.Call(uintptr(unsafe.Pointer(nameBuffer)))
			}
			t.IsDomainJoined = (joinStatus == 3) // NetSetupDomainName
		}
	}

	// 6. Active sessions
	sessions, err := EnumerateAllWTSSessions()
	if err == nil {
		t.Sessions = sessions
	}

	return t
}

func sampleCPUUsage() int {
	if procGetSystemTimes.Find() != nil {
		return 0
	}
	cpuTimesMu.Lock()
	defer cpuTimesMu.Unlock()

	now := time.Now()
	if now.Sub(lastCPUSample) < 2*time.Second && lastKernelTime > 0 {
		return cachedCPUPercent
	}

	var idleTime, kernelTime, userTime windows.Filetime
	r, _, _ := procGetSystemTimes.Call(
		uintptr(unsafe.Pointer(&idleTime)),
		uintptr(unsafe.Pointer(&kernelTime)),
		uintptr(unsafe.Pointer(&userTime)),
	)
	if r == 0 {
		return cachedCPUPercent
	}

	k := (uint64(kernelTime.HighDateTime) << 32) | uint64(kernelTime.LowDateTime)
	u := (uint64(userTime.HighDateTime) << 32) | uint64(userTime.LowDateTime)
	i := (uint64(idleTime.HighDateTime) << 32) | uint64(idleTime.LowDateTime)

	if lastKernelTime == 0 {
		lastKernelTime = k
		lastUserTime = u
		lastIdleTime = i
		lastCPUSample = now
		return 0
	}

	deltaKernel := k - lastKernelTime
	deltaUser := u - lastUserTime
	deltaIdle := i - lastIdleTime

	lastKernelTime = k
	lastUserTime = u
	lastIdleTime = i
	lastCPUSample = now

	totalSys := deltaKernel + deltaUser
	if totalSys == 0 {
		return cachedCPUPercent
	}

	busy := totalSys
	if deltaIdle < totalSys {
		busy = totalSys - deltaIdle
	} else {
		busy = 0
	}

	percent := int((busy * 100) / totalSys)
	if percent > 100 {
		percent = 100
	}
	cachedCPUPercent = percent
	return percent
}
