//go:build windows

package linkagent

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"testing"
)

func TestDPAPIProtectRoundTripAndRejectTampering(t *testing.T) {
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	protected, err := ProtectPrivateKeyDPAPI(privateKey)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(protected, privateKey) {
		t.Fatal("protected DPAPI blob contains the plaintext private key")
	}
	restored, err := UnprotectPrivateKeyDPAPI(protected)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(restored, privateKey) {
		t.Fatal("DPAPI round-trip changed the private key")
	}
	tampered := append([]byte(nil), protected...)
	tampered[len(tampered)/2] ^= 0x80
	if _, err := UnprotectPrivateKeyDPAPI(tampered); err == nil {
		t.Fatal("tampered DPAPI blob unexpectedly decrypted")
	}
}

func TestDPAPIProtectRejectsInvalidPrivateKeyLength(t *testing.T) {
	if _, err := ProtectPrivateKeyDPAPI([]byte("not a private key")); err == nil {
		t.Fatal("expected invalid key size to be rejected")
	}
}
