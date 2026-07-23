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
	"runtime"
	"slices"
	"testing"
	"time"
)

type benchWireContractStatus struct {
	Byte    byte     `json:"byte"`
	Name    string   `json:"name"`
	Origins []string `json:"origins"`
}

type benchWireContractVector struct {
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

type benchWireContractEncoding struct {
	ByteOrder      string `json:"byte_order"`
	Hex            string `json:"hex"`
	PlaintextFrame string `json:"plaintext_frame"`
	EncryptedFrame string `json:"encrypted_frame"`
	AAD            string `json:"aad"`
	PeerBody       string `json:"peer_body"`
}

type benchWireContractTestMaterial struct {
	Warning  string `json:"warning"`
	PSKHex   string `json:"psk_hex"`
	NonceHex string `json:"nonce_hex"`
}

type benchWireContract struct {
	Schema          string                        `json:"schema"`
	ProtocolVersion uint16                        `json:"protocol_version"`
	Encoding        benchWireContractEncoding     `json:"encoding"`
	TestMaterial    benchWireContractTestMaterial `json:"test_material"`
	Statuses        []benchWireContractStatus     `json:"statuses"`
	Vectors         []benchWireContractVector     `json:"vectors"`
}

func loadBenchWireContract(t *testing.T) benchWireContract {
	t.Helper()
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve wire contract test source")
	}
	path := filepath.Join(filepath.Dir(sourceFile), "..", "tests", "wire", "contract-v6.json")
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
	var contract benchWireContract
	if err := decoder.Decode(&contract); err != nil {
		t.Fatalf("decode wire contract: %v", err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		t.Fatalf("wire contract trailing JSON: %v", err)
	}
	return contract
}

func benchContractBytes(t *testing.T, value string, maxBytes int) []byte {
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

func benchContractHasConsumer(vector benchWireContractVector, consumer string) bool {
	return slices.Contains(vector.Consumers, consumer)
}

func decodeBenchContractFrame(t *testing.T, frame []byte) []byte {
	t.Helper()
	reader, writer := net.Pipe()
	done := make(chan error, 1)
	go func() {
		_, err := writer.Write(frame)
		done <- err
	}()
	decoded, err := readFrame(reader, make([]byte, MaxFrameBytes), time.Second)
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

func encodeBenchContractFrame(t *testing.T, tag byte, payload []byte, frameBytes int) []byte {
	t.Helper()
	writer, reader := net.Pipe()
	done := make(chan error, 1)
	go func() { done <- writeFrame(writer, tag, payload) }()
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
	contract := loadBenchWireContract(t)
	if contract.Schema != "hivemind-wire-contract-v1" || contract.ProtocolVersion != ProtocolVersion {
		t.Fatalf("wire contract identity/version mismatch")
	}
	statusNames := []string{"ok", "deployment_not_found", "queue_full", "invalid_payload", "response_too_large", "outcome_ambiguous", "forwarding_failed", "no_running_pod", "unavailable", "not_leader"}
	if len(contract.Statuses) != len(statusNames) {
		t.Fatalf("status count: %d", len(contract.Statuses))
	}
	for index, status := range contract.Statuses {
		if int(status.Byte) != index || status.Name != statusNames[index] || runStatusName(RunStatus(status.Byte)) != status.Name {
			t.Fatalf("status %d mismatch: %#v", index, status)
		}
	}
	if len(contract.Vectors) == 0 || len(contract.Vectors) > 32 {
		t.Fatalf("wire contract vector bound: %d", len(contract.Vectors))
	}

	for _, vector := range contract.Vectors {
		if !benchContractHasConsumer(vector, "go-bench") {
			continue
		}
		t.Run(vector.ID, func(t *testing.T) {
			if vector.Flags != 0 || vector.KeyPurpose != nil {
				t.Fatalf("bench supports only plaintext fixtures")
			}
			frame := benchContractBytes(t, vector.FrameHex, MaxFrameBytes)
			plaintext := benchContractBytes(t, vector.PlaintextHex, MaxFrameBytes)
			payload := benchContractBytes(t, vector.PayloadHex, MaxFrameBytes)
			decoded := decodeBenchContractFrame(t, frame)
			if !bytes.Equal(decoded, plaintext) || decoded[2] != vector.Tag || !bytes.Equal(decoded[3:], payload) {
				t.Fatalf("decoded bytes differ from contract")
			}
			reencoded := encodeBenchContractFrame(t, vector.Tag, payload, len(frame))
			if !bytes.Equal(reencoded, frame) {
				t.Fatalf("re-encoded frame differs from contract")
			}

			switch vector.Message {
			case "run-request":
				if len(payload) < 76 || binary.LittleEndian.Uint32(payload[72:76]) != uint32(len(payload)-76) {
					t.Fatalf("invalid client run request")
				}
			case "run-response":
				if err := expectSuccessRunResponse(payload, 0x0102030405060708); err != nil {
					t.Fatalf("invalid run response: %v", err)
				}
			case "leader-probe-request":
				if len(payload) != 0 {
					t.Fatalf("leader probe request payload length %d", len(payload))
				}
			case "leader-probe-response":
				if len(payload) != LeaderProbeResponseBytes || payload[0] != 0 || payload[1] != 1 || binary.LittleEndian.Uint64(payload[4:12]) != 0x0102030405060708 {
					t.Fatalf("invalid leader response")
				}
			default:
				t.Fatalf("unexpected bench fixture message %q", vector.Message)
			}
		})
	}
}
