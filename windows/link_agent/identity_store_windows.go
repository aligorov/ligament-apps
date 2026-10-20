//go:build windows

package linkagent

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"
)

const (
	commonAppDataCSIDL     = 0x23
	fileAttributeDirectory = 0x10
	fileAttributeReparse   = 0x400
	protectedDACLInfo      = 0x80000000
	daclSecurityInfo       = 0x4
	securityFileObject     = 1
	moveFileReplace        = 0x1
	moveFileWriteThrough   = 0x8
	identityStoreMaxBytes  = 128 * 1024
	identityStoreSDDL      = "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
)

type persistedIdentity struct {
	Version          int    `json:"version"`
	AgentID          string `json:"agent_id"`
	PublicKey        []byte `json:"public_key"`
	PrivateKey       []byte `json:"private_key"`
	Fingerprint      string `json:"fingerprint"`
	ServerTimeOffset int64  `json:"server_time_offset_ns"`
}

type storeSecurityAttributes struct {
	Length             uint32
	SecurityDescriptor uintptr
	InheritHandle      int32
}

var (
	storeShell32                   = syscall.NewLazyDLL("shell32.dll")
	storeSHGetFolderPath           = storeShell32.NewProc("SHGetFolderPathW")
	storeAdvapi32                  = syscall.NewLazyDLL("advapi32.dll")
	storeConvertSDDL               = storeAdvapi32.NewProc("ConvertStringSecurityDescriptorToSecurityDescriptorW")
	storeGetSecurityDescriptorDACL = storeAdvapi32.NewProc("GetSecurityDescriptorDacl")
	storeSetNamedSecurityInfo      = storeAdvapi32.NewProc("SetNamedSecurityInfoW")
	storeKernel32                  = syscall.NewLazyDLL("kernel32.dll")
	storeCreateDirectory           = storeKernel32.NewProc("CreateDirectoryW")
	storeGetFileAttributes         = storeKernel32.NewProc("GetFileAttributesW")
	storeMoveFileEx                = storeKernel32.NewProc("MoveFileExW")
	storeLocalFree                 = storeKernel32.NewProc("LocalFree")
)

// DefaultIdentityStorePath returns a path under the Windows Common AppData
// known folder; it never consults process environment variables.
func DefaultIdentityStorePath() (string, error) {
	buffer := make([]uint16, 260)
	hr, _, _ := storeSHGetFolderPath.Call(0, commonAppDataCSIDL, 0, 0, uintptr(unsafe.Pointer(&buffer[0])))
	if int32(hr) < 0 {
		return "", fmt.Errorf("link agent: resolve Common AppData folder failed (HRESULT 0x%08x)", uint32(hr))
	}
	root := syscall.UTF16ToString(buffer)
	if root == "" {
		return "", errors.New("link agent: Common AppData folder is empty")
	}
	return filepath.Join(root, "Ligament", "Link", "identity.bin"), nil
}

// SaveIdentity protects the full identity record with DPAPI and writes it
// atomically in a directory restricted to LocalSystem and Administrators.
func SaveIdentity(identity *Identity) error {
	path, err := DefaultIdentityStorePath()
	if err != nil {
		return err
	}
	directory := filepath.Dir(path)
	if err := ensureProtectedDirectory(directory); err != nil {
		return err
	}
	return saveIdentityAt(path, identity)
}

// LoadIdentity loads and validates the DPAPI-protected identity record.
func LoadIdentity() (*Identity, error) {
	path, err := DefaultIdentityStorePath()
	if err != nil {
		return nil, err
	}
	if err := ensureProtectedDirectory(filepath.Dir(path)); err != nil {
		return nil, err
	}
	if err := rejectReparsePoint(path); err != nil {
		return nil, err
	}
	return loadIdentityAt(path)
}

func saveIdentityAt(path string, identity *Identity) error {
	if err := validatePersistedIdentity(identity); err != nil {
		return err
	}
	record := persistedIdentity{
		Version: 1, AgentID: identity.AgentID,
		PublicKey:        append([]byte(nil), identity.PublicKey...),
		PrivateKey:       append([]byte(nil), identity.PrivateKey...),
		Fingerprint:      identity.Fingerprint,
		ServerTimeOffset: int64(identity.ServerTimeOffset),
	}
	payload, err := json.Marshal(record)
	clear(record.PrivateKey)
	if err != nil {
		return fmt.Errorf("link agent: encode persisted identity: %w", err)
	}
	defer clear(payload)
	sealed, err := protectDataDPAPI(payload)
	if err != nil {
		return err
	}
	defer clear(sealed)
	if len(sealed) > identityStoreMaxBytes {
		return errors.New("link agent: protected identity exceeds storage limit")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("link agent: create identity directory: %w", err)
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".identity-*.tmp")
	if err != nil {
		return fmt.Errorf("link agent: create temporary identity file: %w", err)
	}
	tmpPath := tmp.Name()
	committed := false
	defer func() {
		if !committed {
			_ = os.Remove(tmpPath)
		}
	}()
	if _, err := tmp.Write(sealed); err != nil {
		tmp.Close()
		return fmt.Errorf("link agent: write protected identity: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("link agent: flush protected identity: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("link agent: close protected identity: %w", err)
	}
	if err := moveFileReplaceWriteThrough(tmpPath, path); err != nil {
		return fmt.Errorf("link agent: atomically replace protected identity: %w", err)
	}
	committed = true
	return nil
}

func loadIdentityAt(path string) (*Identity, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("link agent: open protected identity: %w", err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("link agent: stat protected identity: %w", err)
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > identityStoreMaxBytes {
		return nil, errors.New("link agent: invalid protected identity file")
	}
	sealed, err := io.ReadAll(io.LimitReader(file, identityStoreMaxBytes+1))
	if err != nil {
		return nil, fmt.Errorf("link agent: read protected identity: %w", err)
	}
	defer clear(sealed)
	if len(sealed) > identityStoreMaxBytes {
		return nil, errors.New("link agent: protected identity exceeds storage limit")
	}
	payload, err := unprotectDataDPAPI(sealed)
	if err != nil {
		return nil, err
	}
	defer clear(payload)
	var record persistedIdentity
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&record); err != nil {
		return nil, fmt.Errorf("link agent: decode protected identity: %w", err)
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		clear(record.PrivateKey)
		return nil, errors.New("link agent: trailing data in protected identity")
	}
	privateKey := append(ed25519.PrivateKey(nil), record.PrivateKey...)
	clear(record.PrivateKey)
	identity := &Identity{
		AgentID:          record.AgentID,
		PublicKey:        append(ed25519.PublicKey(nil), record.PublicKey...),
		PrivateKey:       privateKey,
		Fingerprint:      record.Fingerprint,
		ServerTimeOffset: time.Duration(record.ServerTimeOffset),
	}
	if record.Version != 1 {
		clear(identity.PrivateKey)
		return nil, errors.New("link agent: unsupported protected identity version")
	}
	if err := validatePersistedIdentity(identity); err != nil {
		clear(identity.PrivateKey)
		return nil, err
	}
	return identity, nil
}

func ensureProtectedDirectory(directory string) error {
	sddl, err := syscall.UTF16PtrFromString(identityStoreSDDL)
	if err != nil {
		return err
	}
	var descriptor uintptr
	r1, _, callErr := storeConvertSDDL.Call(uintptr(unsafe.Pointer(sddl)), 1, uintptr(unsafe.Pointer(&descriptor)), 0)
	if r1 == 0 {
		return fmt.Errorf("link agent: create identity directory ACL: %w", callErr)
	}
	defer storeLocalFree.Call(descriptor)
	security := storeSecurityAttributes{Length: uint32(unsafe.Sizeof(storeSecurityAttributes{})), SecurityDescriptor: descriptor}
	parent := filepath.Dir(directory)
	if err := createProtectedDirectory(parent, &security); err != nil {
		return err
	}
	if err := createProtectedDirectory(directory, &security); err != nil {
		return err
	}
	var present, defaulted int32
	var dacl uintptr
	r1, _, callErr = storeGetSecurityDescriptorDACL.Call(descriptor, uintptr(unsafe.Pointer(&present)), uintptr(unsafe.Pointer(&dacl)), uintptr(unsafe.Pointer(&defaulted)))
	if r1 == 0 || present == 0 || dacl == 0 {
		return fmt.Errorf("link agent: read identity directory ACL: %w", callErr)
	}
	name, err := syscall.UTF16PtrFromString(directory)
	if err != nil {
		return err
	}
	r1, _, _ = storeSetNamedSecurityInfo.Call(uintptr(unsafe.Pointer(name)), securityFileObject,
		daclSecurityInfo|protectedDACLInfo, 0, 0, dacl, 0)
	if r1 != 0 {
		return fmt.Errorf("link agent: secure identity directory failed: %w", syscall.Errno(r1))
	}
	return nil
}

func createProtectedDirectory(path string, security *storeSecurityAttributes) error {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	r1, _, callErr := storeCreateDirectory.Call(uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(security)))
	if r1 == 0 && !errors.Is(callErr, syscall.ERROR_ALREADY_EXISTS) {
		return fmt.Errorf("link agent: create protected directory: %w", callErr)
	}
	attributes, _, attrErr := storeGetFileAttributes.Call(uintptr(unsafe.Pointer(name)))
	if uint32(attributes) == 0xFFFFFFFF {
		return fmt.Errorf("link agent: inspect identity directory: %w", attrErr)
	}
	if uint32(attributes)&fileAttributeDirectory == 0 || uint32(attributes)&fileAttributeReparse != 0 {
		return errors.New("link agent: identity directory is not a plain directory")
	}
	return nil
}

func rejectReparsePoint(path string) error {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	attributes, _, callErr := storeGetFileAttributes.Call(uintptr(unsafe.Pointer(name)))
	if uint32(attributes) == 0xFFFFFFFF {
		return fmt.Errorf("link agent: inspect identity path: %w", callErr)
	}
	if uint32(attributes)&fileAttributeReparse != 0 {
		return errors.New("link agent: identity path must not be a reparse point")
	}
	return nil
}

func moveFileReplaceWriteThrough(source, destination string) error {
	src, err := syscall.UTF16PtrFromString(source)
	if err != nil {
		return err
	}
	dst, err := syscall.UTF16PtrFromString(destination)
	if err != nil {
		return err
	}
	r1, _, callErr := storeMoveFileEx.Call(uintptr(unsafe.Pointer(src)), uintptr(unsafe.Pointer(dst)), moveFileReplace|moveFileWriteThrough)
	if r1 == 0 {
		return callErr
	}
	return nil
}
