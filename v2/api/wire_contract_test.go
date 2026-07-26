package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
)

type wireContractStatus struct {
	Byte    byte     `json:"byte"`
	Name    string   `json:"name"`
	Origins []string `json:"origins"`
}

type wireContractVector struct {
	ID           string   `json:"id"`
	Channel      string   `json:"channel"`
	Direction    string   `json:"direction"`
	Message      string   `json:"message"`
	Flags        byte     `json:"flags"`
	Tag          byte     `json:"tag"`
	KeyPurpose   *string  `json:"key_purpose"`
	PayloadHex   string   `json:"payload_hex"`
	PlaintextHex string   `json:"plaintext_hex"`
	FrameHex     string   `json:"frame_hex"`
	Consumers    []string `json:"consumers"`
}

type wireContractEncoding struct {
	ByteOrder      string `json:"byte_order"`
	Hex            string `json:"hex"`
	PlaintextFrame string `json:"plaintext_frame"`
	EncryptedFrame string `json:"encrypted_frame"`
	AAD            string `json:"aad"`
	PeerBody       string `json:"peer_body"`
}

type wireContractTestMaterial struct {
	Warning  string `json:"warning"`
	PSKHex   string `json:"psk_hex"`
	NonceHex string `json:"nonce_hex"`
}

type wireContract struct {
	Schema          string                   `json:"schema"`
	ProtocolVersion uint16                   `json:"protocol_version"`
	Encoding        wireContractEncoding     `json:"encoding"`
	TestMaterial    wireContractTestMaterial `json:"test_material"`
	Statuses        []wireContractStatus     `json:"statuses"`
	Vectors         []wireContractVector     `json:"vectors"`
}

func loadWireContract(t *testing.T) wireContract {
	t.Helper()
	workingDirectory, err := os.Getwd()
	if err != nil {
		t.Fatalf("resolve test working directory: %v", err)
	}
	path := filepath.Join(workingDirectory, "..", "tests", "wire", "contract-v6.json")
	file, err := os.Open(path)
	if err != nil {
		t.Fatalf("open wire contract: %v", err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		t.Fatalf("wire contract stat: %v", err)
	}
	if info.Size() <= 0 || info.Size() > 256*1024 {
		t.Fatalf("wire contract size: %d", info.Size())
	}
	decoder := json.NewDecoder(io.LimitReader(file, 256*1024))
	decoder.DisallowUnknownFields()
	var contract wireContract
	if err := decoder.Decode(&contract); err != nil {
		t.Fatalf("decode wire contract: %v", err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		t.Fatalf("wire contract trailing JSON: %v", err)
	}
	return contract
}

func contractBytes(t *testing.T, value string, maxBytes int) []byte {
	t.Helper()
	if len(value)%2 != 0 || len(value)/2 > maxBytes {
		t.Fatalf("invalid bounded hex length %d", len(value))
	}
	decoded, err := hex.DecodeString(value)
	if err != nil {
		t.Fatalf("decode fixture hex: %v", err)
	}
	return decoded
}

func contractHasConsumer(vector wireContractVector, consumer string) bool {
	return slices.Contains(vector.Consumers, consumer)
}

func decodeAPIContractFrame(t *testing.T, frame []byte, crypto *CryptoState) []byte {
	t.Helper()
	reader, writer := net.Pipe()
	done := make(chan error, 1)
	go func() {
		_, err := writer.Write(frame)
		done <- err
	}()
	decoded, err := readFrameGeneric(reader, make([]byte, 64*1024), time.Second, crypto)
	writer.Close()
	reader.Close()
	if err != nil {
		t.Fatalf("decode contract frame: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("write contract frame: %v", err)
	}
	return decoded
}

func encodeAPIPlaintextFrame(t *testing.T, tag byte, payload []byte, frameBytes int) []byte {
	t.Helper()
	writer, reader := net.Pipe()
	done := make(chan error, 1)
	go func() {
		done <- writeFrameEncrypted(writer, tag, payload, nil)
	}()
	frame := make([]byte, frameBytes)
	if _, err := io.ReadFull(reader, frame); err != nil {
		t.Fatalf("read re-encoded frame: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("re-encode frame: %v", err)
	}
	writer.Close()
	reader.Close()
	return frame
}

func TestWireContract(t *testing.T) {
	contract := loadWireContract(t)
	if contract.Schema != "hivemind-wire-contract-v1" || contract.ProtocolVersion != ProtocolVersion {
		t.Fatalf("wire contract identity/version mismatch: %#v", contract)
	}
	if len(contract.Vectors) == 0 || len(contract.Vectors) > 32 {
		t.Fatalf("wire contract vector bound: %d", len(contract.Vectors))
	}
	statusNames := []string{"ok", "deployment_not_found", "queue_full", "invalid_payload", "response_too_large", "outcome_ambiguous", "forwarding_failed", "no_running_pod", "unavailable", "not_leader"}
	if len(contract.Statuses) != len(statusNames) {
		t.Fatalf("status count: %d", len(contract.Statuses))
	}
	for index, status := range contract.Statuses {
		if int(status.Byte) != index || status.Name != statusNames[index] || RunStatus(status.Byte).String() != status.Name {
			t.Fatalf("status %d mismatch: %#v", index, status)
		}
	}

	crypto, err := NewCryptoState(contract.TestMaterial.PSKHex)
	if err != nil {
		t.Fatalf("derive fixture key: %v", err)
	}
	nonce := contractBytes(t, contract.TestMaterial.NonceHex, CryptoNonceLen)
	if len(nonce) != CryptoNonceLen {
		t.Fatalf("nonce length: %d", len(nonce))
	}

	for _, vector := range contract.Vectors {
		if !contractHasConsumer(vector, "go-api") {
			continue
		}
		t.Run(vector.ID, func(t *testing.T) {
			frame := contractBytes(t, vector.FrameHex, 64*1024)
			plaintext := contractBytes(t, vector.PlaintextHex, 64*1024)
			payload := contractBytes(t, vector.PayloadHex, 16*1024)
			var decoderCrypto *CryptoState
			if vector.Flags == 1 {
				if vector.KeyPurpose == nil || *vector.KeyPurpose != "client" {
					t.Fatalf("invalid client key purpose: %v", vector.KeyPurpose)
				}
				decoderCrypto = crypto
			}
			decoded := decodeAPIContractFrame(t, frame, decoderCrypto)
			if !bytes.Equal(decoded, plaintext) || decoded[2] != vector.Tag || !bytes.Equal(decoded[3:], payload) {
				t.Fatalf("decoded bytes differ from contract")
			}

			if vector.Flags == 0 {
				reencoded := encodeAPIPlaintextFrame(t, vector.Tag, payload, len(frame))
				if !bytes.Equal(reencoded, frame) {
					t.Fatalf("plaintext re-encoding differs")
				}
			} else {
				aead, err := chacha20poly1305.NewX(crypto.ClientKey[:])
				if err != nil {
					t.Fatal(err)
				}
				sealed := aead.Seal(nil, nonce, plaintext, frame[:5])
				reencoded := append(append(append([]byte{}, frame[:5]...), nonce...), sealed...)
				if !bytes.Equal(reencoded, frame) {
					t.Fatalf("encrypted re-encoding differs")
				}
			}

			switch vector.Message {
			case "run-request":
				if len(payload) < 76 || binary.LittleEndian.Uint32(payload[72:76]) != uint32(len(payload)-76) {
					t.Fatalf("invalid client run request")
				}
			case "run-response":
				response, err := parseRunResponse(payload)
				if err != nil || response.RequestID != 0x0102030405060708 || byte(response.Status) != payload[8] {
					t.Fatalf("invalid run response: %#v %v", response, err)
				}
				if response.Status == RunStatusOK && string(response.Body) != "pong" {
					t.Fatalf("invalid successful run response body: %q", response.Body)
				}
			case "leader-probe-request":
				if len(payload) != 0 {
					t.Fatalf("leader probe request payload length %d", len(payload))
				}
			case "leader-probe-response":
				probe, err := parseLeaderProbe(payload)
				if err != nil || !probe.IsLeader || probe.ViewNumber != 0x0102030405060708 {
					t.Fatalf("invalid leader response: %#v %v", probe, err)
				}
			default:
				t.Fatalf("unexpected API fixture message %q", vector.Message)
			}
		})
	}
}
