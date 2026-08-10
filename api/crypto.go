package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
)

const (
	CryptoKeyLen   = 32
	CryptoNonceLen = chacha20poly1305.NonceSizeX // 24
	CryptoTagLen   = 16
)

type CryptoState struct {
	Enabled   bool
	ClientKey [CryptoKeyLen]byte
}

func NewCryptoState(pskHex string) (*CryptoState, error) {
	if len(pskHex) != 64 {
		return nil, fmt.Errorf("key must be 64 hex chars (32 bytes), got %d", len(pskHex))
	}
	psk, err := hex.DecodeString(pskHex)
	if err != nil {
		return nil, fmt.Errorf("invalid hex key: %w", err)
	}

	hk := hkdf.New(sha256.New, psk, []byte("hivemind-v1"), []byte("hivemind-client-v1"))
	var clientKey [CryptoKeyLen]byte
	if _, err := io.ReadFull(hk, clientKey[:]); err != nil {
		return nil, fmt.Errorf("hkdf expand failed: %w", err)
	}

	return &CryptoState{
		Enabled:   true,
		ClientKey: clientKey,
	}, nil
}

func CryptoDisabled() *CryptoState {
	return &CryptoState{Enabled: false}
}

// EncryptFrame encrypts plaintext, returns [nonce(24)][ciphertext+tag].
func EncryptFrame(key *[CryptoKeyLen]byte, plaintext, aad []byte) ([]byte, error) {
	aead, err := chacha20poly1305.NewX(key[:])
	if err != nil {
		return nil, err
	}

	nonce := make([]byte, CryptoNonceLen)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}

	ciphertext := aead.Seal(nil, nonce, plaintext, aad)

	out := make([]byte, CryptoNonceLen+len(ciphertext))
	copy(out, nonce)
	copy(out[CryptoNonceLen:], ciphertext)
	return out, nil
}

// DecryptFrame decrypts [nonce(24)][ciphertext+tag], returns plaintext.
func DecryptFrame(key *[CryptoKeyLen]byte, encryptedData, aad []byte) ([]byte, error) {
	if len(encryptedData) < CryptoNonceLen+CryptoTagLen {
		return nil, fmt.Errorf("frame too short: %d bytes", len(encryptedData))
	}

	aead, err := chacha20poly1305.NewX(key[:])
	if err != nil {
		return nil, err
	}

	nonce := encryptedData[:CryptoNonceLen]
	ciphertextAndTag := encryptedData[CryptoNonceLen:]

	return aead.Open(nil, nonce, ciphertextAndTag, aad)
}
