//go:build windows

package linkagent

import (
	"crypto/ed25519"
	"errors"
	"fmt"
	"runtime"
	"syscall"
	"unsafe"
)

const (
	cryptProtectUIForbidden = 0x1
	linkKeyEntropy          = "Ligament Link agent identity key v1"
)

type dataBlob struct {
	Size uint32
	Data *byte
}

var (
	crypt32                = syscall.NewLazyDLL("crypt32.dll")
	cryptProtectData       = crypt32.NewProc("CryptProtectData")
	cryptUnprotectData     = crypt32.NewProc("CryptUnprotectData")
	keyProtectionKernel32  = syscall.NewLazyDLL("kernel32.dll")
	keyProtectionLocalFree = keyProtectionKernel32.NewProc("LocalFree")
)

// ProtectPrivateKeyDPAPI seals an Ed25519 key to the current Windows service
// identity. The protected bytes may be persisted; only that same identity can
// unseal them. It deliberately does not fall back to plaintext on error.
func ProtectPrivateKeyDPAPI(privateKey ed25519.PrivateKey) ([]byte, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return nil, errors.New("link agent: invalid Ed25519 private key size")
	}
	return protectDataDPAPI(privateKey)
}

func protectDataDPAPI(plaintext []byte) ([]byte, error) {
	if len(plaintext) == 0 || len(plaintext) > 128*1024 {
		return nil, errors.New("link agent: invalid DPAPI input size")
	}
	input := dataBlob{Size: uint32(len(plaintext)), Data: &plaintext[0]}
	entropyBytes := []byte(linkKeyEntropy)
	entropy := dataBlob{Size: uint32(len(entropyBytes)), Data: &entropyBytes[0]}
	var output dataBlob
	r1, _, callErr := cryptProtectData.Call(
		uintptr(unsafe.Pointer(&input)), 0,
		uintptr(unsafe.Pointer(&entropy)), 0, 0,
		cryptProtectUIForbidden, uintptr(unsafe.Pointer(&output)),
	)
	runtime.KeepAlive(plaintext)
	runtime.KeepAlive(entropyBytes)
	if r1 == 0 {
		return nil, fmt.Errorf("link agent: DPAPI protect failed: %w", callErr)
	}
	return takeDPAPIOutput(output, false)
}

// UnprotectPrivateKeyDPAPI unseals a key created by ProtectPrivateKeyDPAPI.
func UnprotectPrivateKeyDPAPI(ciphertext []byte) (ed25519.PrivateKey, error) {
	plain, err := unprotectDataDPAPI(ciphertext)
	if err != nil {
		return nil, err
	}
	if len(plain) != ed25519.PrivateKeySize {
		clear(plain)
		return nil, errors.New("link agent: DPAPI payload is not an Ed25519 private key")
	}
	return ed25519.PrivateKey(plain), nil
}

func unprotectDataDPAPI(ciphertext []byte) ([]byte, error) {
	if len(ciphertext) == 0 {
		return nil, errors.New("link agent: empty protected private key")
	}
	input := dataBlob{Size: uint32(len(ciphertext)), Data: &ciphertext[0]}
	entropyBytes := []byte(linkKeyEntropy)
	entropy := dataBlob{Size: uint32(len(entropyBytes)), Data: &entropyBytes[0]}
	var output dataBlob
	r1, _, callErr := cryptUnprotectData.Call(
		uintptr(unsafe.Pointer(&input)), 0,
		uintptr(unsafe.Pointer(&entropy)), 0, 0,
		cryptProtectUIForbidden, uintptr(unsafe.Pointer(&output)),
	)
	runtime.KeepAlive(ciphertext)
	runtime.KeepAlive(entropyBytes)
	if r1 == 0 {
		return nil, fmt.Errorf("link agent: DPAPI unprotect failed: %w", callErr)
	}
	return takeDPAPIOutput(output, true)
}

func takeDPAPIOutput(output dataBlob, zeroBeforeFree bool) ([]byte, error) {
	if output.Data == nil || output.Size == 0 {
		if output.Data != nil {
			keyProtectionLocalFree.Call(uintptr(unsafe.Pointer(output.Data)))
		}
		return nil, errors.New("link agent: DPAPI returned empty data")
	}
	defer func() {
		if zeroBeforeFree {
			clear(unsafe.Slice(output.Data, int(output.Size)))
		}
		keyProtectionLocalFree.Call(uintptr(unsafe.Pointer(output.Data)))
	}()
	return append([]byte(nil), unsafe.Slice(output.Data, int(output.Size))...), nil
}
