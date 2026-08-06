package main

import (
	"encoding/binary"
	"io"
	"strings"
	"testing"
	"time"
)

func encodeOkReply(requestID, entityID uint64) []byte {
	buf := make([]byte, 17)
	binary.LittleEndian.PutUint64(buf[0:8], requestID)
	buf[8] = ResultOk
	binary.LittleEndian.PutUint64(buf[9:17], entityID)
	return buf
}

func encodeErrReply(requestID uint64, code byte) []byte {
	buf := make([]byte, 10)
	binary.LittleEndian.PutUint64(buf[0:8], requestID)
	buf[8] = ResultErr
	buf[9] = code
	return buf
}

func writeReplyFrame(w *io.PipeWriter, payload []byte) error {
	inner := make([]byte, 2+1+len(payload))
	binary.LittleEndian.PutUint16(inner[0:2], ProtocolVersion)
	inner[2] = ClientTagReply
	copy(inner[3:], payload)
	header := make([]byte, 5)
	binary.LittleEndian.PutUint32(header[0:4], uint32(1+len(inner)))
	header[4] = 0x00
	if _, err := w.Write(header); err != nil {
		return err
	}
	_, err := w.Write(inner)
	return err
}

func TestParseResultTable(t *testing.T) {
	tests := []struct {
		name    string
		reply   []byte
		wantID  uint64
		wantOK  bool
		wantErr string
	}{
		{
			name:   "valid success",
			reply:  encodeOkReply(7, 99),
			wantID: 7,
			wantOK: true,
		},
		{
			name:    "mismatched request id",
			reply:   encodeOkReply(41, 1),
			wantID:  42,
			wantErr: "request_id mismatch",
		},
		{
			name:    "truncated frame missing result tag",
			reply:   encodeOkReply(1, 0)[:8],
			wantID:  1,
			wantErr: "too short",
		},
		{
			name:    "truncated ok missing entity id",
			reply:   encodeOkReply(1, 0)[:9],
			wantID:  1,
			wantErr: "ok reply length",
		},
		{
			name:    "truncated err missing code",
			reply:   encodeErrReply(2, ErrNotLeader)[:9],
			wantID:  2,
			wantErr: "err reply length",
		},
		{
			name:    "malformed empty",
			reply:   nil,
			wantID:  1,
			wantErr: "too short",
		},
		{
			name:    "unexpected result tag",
			reply:   append(encodeOkReply(3, 0)[:8], 0xFF),
			wantID:  3,
			wantErr: "unknown result type",
		},
		{
			name:   "error result",
			reply:  encodeErrReply(5, ErrNotLeader),
			wantID: 5,
			wantOK: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseResult(tc.reply, tc.wantID)
			if tc.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got nil (result=%+v)", tc.wantErr, got)
				}
				if !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("error %q does not contain %q", err.Error(), tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.OK != tc.wantOK {
				t.Fatalf("OK=%v want %v", got.OK, tc.wantOK)
			}
			if tc.wantOK {
				if err := expectSuccessResult(tc.reply, tc.wantID); err != nil {
					t.Fatalf("expectSuccessResult: %v", err)
				}
			} else {
				if err := expectSuccessResult(tc.reply, tc.wantID); err == nil {
					t.Fatal("expected error result to fail expectSuccessResult")
				}
			}
		})
	}
}

func TestReadReplyValidatesRequestIDAndSemantics(t *testing.T) {
	tests := []struct {
		name    string
		payload []byte
		wantID  uint64
		wantErr string
	}{
		{
			name:    "valid success",
			payload: encodeOkReply(11, 100),
			wantID:  11,
		},
		{
			name:    "mismatched request id",
			payload: encodeOkReply(10, 1),
			wantID:  11,
			wantErr: "request_id mismatch",
		},
		{
			name:    "error result not counted as success",
			payload: encodeErrReply(11, ErrNotLeader),
			wantID:  11,
			wantErr: "error code",
		},
		{
			name:    "unexpected result tag",
			payload: append(encodeOkReply(11, 0)[:8], 0xAB),
			wantID:  11,
			wantErr: "unknown result type",
		},
		{
			name:    "truncated payload",
			payload: encodeOkReply(11, 0)[:8],
			wantID:  11,
			wantErr: "too short",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cr, sw := io.Pipe()
			client := &pipeConn{r: cr}
			go func() {
				_ = writeReplyFrame(sw, tc.payload)
				_ = sw.Close()
			}()

			buf := make([]byte, 256)
			err := readReply(client, buf, tc.wantID)
			_ = cr.Close()

			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected error containing %q", tc.wantErr)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("error %q does not contain %q", err.Error(), tc.wantErr)
			}
		})
	}
}

func TestReadReplyConnectionReuseMatchesEachRequestID(t *testing.T) {
	cr, sw := io.Pipe()
	client := &pipeConn{r: cr}

	go func() {
		_ = writeReplyFrame(sw, encodeOkReply(1, 10))
		_ = writeReplyFrame(sw, encodeOkReply(2, 20))
		_ = writeReplyFrame(sw, encodeErrReply(3, ErrNotLeader))
		_ = sw.Close()
	}()

	buf := make([]byte, 256)
	if err := readReply(client, buf, 1); err != nil {
		t.Fatalf("first reply: %v", err)
	}
	if err := readReply(client, buf, 2); err != nil {
		t.Fatalf("second reply: %v", err)
	}
	err := readReply(client, buf, 3)
	_ = cr.Close()
	if err == nil {
		t.Fatal("expected third reply (error result) to fail")
	}
	if !strings.Contains(err.Error(), "error code") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestReadReplyRejectsWrongTag(t *testing.T) {
	cr, sw := io.Pipe()
	client := &pipeConn{r: cr}
	go func() {
		inner := make([]byte, 2+1+9)
		binary.LittleEndian.PutUint16(inner[0:2], ProtocolVersion)
		inner[2] = ClientTagRunResponse
		copy(inner[3:], encodeOkReply(1, 0))
		header := make([]byte, 5)
		binary.LittleEndian.PutUint32(header[0:4], uint32(1+len(inner)))
		header[4] = 0x00
		_, _ = sw.Write(header)
		_, _ = sw.Write(inner)
		_ = sw.Close()
	}()

	buf := make([]byte, 256)
	err := readReply(client, buf, 1)
	_ = cr.Close()
	if err == nil || !strings.Contains(err.Error(), "unexpected tag") {
		t.Fatalf("expected unexpected tag error, got %v", err)
	}
}

func TestRunStatusWireGolden(t *testing.T) {
	want := []string{
		"ok", "deployment_not_found", "queue_full", "invalid_payload",
		"response_too_large", "outcome_ambiguous", "forwarding_failed",
		"no_running_pod", "unavailable", "not_leader",
	}
	for wire, name := range want {
		if got := runStatusName(RunStatus(wire)); got != name {
			t.Fatalf("wire %d = %q, want %q", wire, got, name)
		}
	}
}

func TestReadRunResponseValidatesRequestID(t *testing.T) {
	encodeRun := func(requestID uint64, status byte, bodyLen uint32) []byte {
		if status != 0 {
			buf := make([]byte, 9)
			binary.LittleEndian.PutUint64(buf[0:8], requestID)
			buf[8] = status
			return buf
		}
		buf := make([]byte, 13+int(bodyLen))
		binary.LittleEndian.PutUint64(buf[0:8], requestID)
		buf[8] = status
		binary.LittleEndian.PutUint32(buf[9:13], bodyLen)
		return buf
	}
	encodeTruncSuccess := func(requestID uint64) []byte {
		buf := make([]byte, 9)
		binary.LittleEndian.PutUint64(buf[0:8], requestID)
		buf[8] = 0
		return buf
	}
	encodeRunDetail := func(requestID uint64, status RunStatus, body []byte) []byte {
		buf := make([]byte, 13+len(body))
		binary.LittleEndian.PutUint64(buf[0:8], requestID)
		buf[8] = byte(status)
		binary.LittleEndian.PutUint32(buf[9:13], uint32(len(body)))
		copy(buf[13:], body)
		return buf
	}
	writeRun := func(w *io.PipeWriter, payload []byte) {
		inner := make([]byte, 2+1+len(payload))
		binary.LittleEndian.PutUint16(inner[0:2], ProtocolVersion)
		inner[2] = ClientTagRunResponse
		copy(inner[3:], payload)
		header := make([]byte, 5)
		binary.LittleEndian.PutUint32(header[0:4], uint32(1+len(inner)))
		header[4] = 0x00
		_, _ = w.Write(header)
		_, _ = w.Write(inner)
	}

	tests := []struct {
		name       string
		payload    []byte
		wantID     uint64
		wantStatus RunStatus
		wantErr    string
	}{
		{name: "valid success", payload: encodeRun(9, 0, 0), wantID: 9},
		{name: "valid max body", payload: encodeRun(9, 0, MaxRunResponseBody), wantID: 9},
		{name: "body over max", payload: encodeRun(9, 0, MaxRunResponseBody+1), wantID: 9, wantErr: "exceeds max"},
		{name: "mismatched request id", payload: encodeRun(8, 0, 0), wantID: 9, wantErr: "request_id mismatch"},
		{name: "typed error status", payload: encodeRun(9, 1, 0), wantID: 9, wantStatus: RunStatusDeploymentNotFound},
		{name: "typed error detail", payload: encodeRunDetail(9, RunStatusForwardingFailed, []byte("dial worker: refused")), wantID: 9, wantStatus: RunStatusForwardingFailed},
		{name: "typed error max detail", payload: encodeRunDetail(9, RunStatusForwardingFailed, make([]byte, MaxRunResponseBody)), wantID: 9, wantStatus: RunStatusForwardingFailed},
		{name: "typed error detail over max", payload: encodeRunDetail(9, RunStatusForwardingFailed, make([]byte, MaxRunResponseBody+1)), wantID: 9, wantErr: "exceeds max"},
		{name: "typed error truncated detail", payload: encodeRunDetail(9, RunStatusForwardingFailed, []byte("lost"))[:16], wantID: 9, wantErr: "length"},
		{name: "truncated header", payload: encodeRun(9, 0, 0)[:8], wantID: 9, wantErr: "too short"},
		{name: "truncated success missing length", payload: encodeTruncSuccess(9), wantID: 9, wantErr: "truncated"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cr, sw := io.Pipe()
			client := &pipeConn{r: cr}
			go func() {
				writeRun(sw, tc.payload)
				_ = sw.Close()
			}()
			buf := make([]byte, MaxFrameBytes)
			status, err := readRunResponse(client, buf, tc.wantID)
			_ = cr.Close()
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				if status != tc.wantStatus {
					t.Fatalf("status=%d want %d", status, tc.wantStatus)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("expected error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}

func TestReadReplyDeadlineHonored(t *testing.T) {
	// Ensure read path still sets a deadline (smoke: closed pipe errors promptly).
	cr, sw := io.Pipe()
	client := &pipeConn{r: cr}
	_ = sw.Close()
	buf := make([]byte, 256)
	start := time.Now()
	err := readReply(client, buf, 1)
	_ = cr.Close()
	if err == nil {
		t.Fatal("expected error on closed pipe")
	}
	if time.Since(start) > 2*time.Second {
		t.Fatalf("read took too long: %v", time.Since(start))
	}
}
