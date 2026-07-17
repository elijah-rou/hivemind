package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"net"
	"testing"
	"time"
)

func buildClusterStateProbeFrame(isLeader bool) []byte {
	payload := make([]byte, 27)
	payload[0] = 0x01 // query_type
	if isLeader {
		payload[26] = 1
	}

	inner := make([]byte, 3+len(payload))
	binary.LittleEndian.PutUint16(inner[0:2], ProtocolVersion)
	inner[2] = TagClusterStateResponse
	copy(inner[3:], payload)

	frame := make([]byte, 5+len(inner))
	binary.LittleEndian.PutUint32(frame[0:4], uint32(1+len(inner)))
	frame[4] = 0x00
	copy(frame[5:], inner)
	return frame
}

func TestParseResultRequiresExactVariantLengths(t *testing.T) {
	ok := make([]byte, 17)
	binary.LittleEndian.PutUint64(ok[:8], 7)
	ok[8] = 0
	errReply := make([]byte, 10)
	binary.LittleEndian.PutUint64(errReply[:8], 7)
	errReply[8] = 1

	cases := []struct {
		name  string
		reply []byte
	}{
		{name: "ok truncated", reply: ok[:16]},
		{name: "ok trailing", reply: append(ok, 0)},
		{name: "error truncated", reply: errReply[:9]},
		{name: "error trailing", reply: append(errReply, 0)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := parseResult(tc.reply, 7); err == nil {
				t.Fatalf("parseResult accepted malformed %d-byte reply", len(tc.reply))
			}
		})
	}
}

func TestParseClusterStateRejectsTruncationAndExcessCountsWithoutPanic(t *testing.T) {
	validEmpty := make([]byte, 27+2+2+2+2+40)
	validEmpty[0] = 1
	if _, err := parseClusterState(validEmpty); err != nil {
		t.Fatalf("valid empty state rejected: %v", err)
	}

	cases := []struct {
		name string
		data []byte
	}{
		{name: "header truncation", data: validEmpty[:26]},
		{name: "node record truncation", data: func() []byte {
			b := append([]byte(nil), validEmpty[:29]...)
			binary.LittleEndian.PutUint16(b[27:29], 1)
			return b
		}()},
		{name: "node count over bound", data: func() []byte {
			b := append([]byte(nil), validEmpty...)
			binary.LittleEndian.PutUint16(b[27:29], 129)
			return b
		}()},
		{name: "deployment count over bound", data: func() []byte {
			b := append([]byte(nil), validEmpty...)
			binary.LittleEndian.PutUint16(b[29:31], 65)
			return b
		}()},
		{name: "pod count over bound", data: func() []byte {
			b := append([]byte(nil), validEmpty...)
			binary.LittleEndian.PutUint16(b[31:33], 513)
			return b
		}()},
		{name: "agent count over bound", data: func() []byte {
			b := append([]byte(nil), validEmpty...)
			binary.LittleEndian.PutUint16(b[33:35], 129)
			return b
		}()},
		{name: "queue stats truncation", data: validEmpty[:len(validEmpty)-1]},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := parseClusterState(tc.data); err == nil {
				t.Fatalf("parseClusterState accepted malformed %d-byte state", len(tc.data))
			}
		})
	}
}

func TestProbeIsLeaderClearsDeadlines(t *testing.T) {
	conn := &deadlineTrackingConn{
		readBuf: bytes.NewReader(buildClusterStateProbeFrame(true)),
	}

	ok, err := probeIsLeader(conn, nil)
	if err != nil {
		t.Fatalf("probeIsLeader returned error: %v", err)
	}
	if !ok {
		t.Fatalf("expected leader probe to return true")
	}
	if !conn.lastWriteDeadline.IsZero() {
		t.Fatalf("expected write deadline cleared, got %v", conn.lastWriteDeadline)
	}
	if !conn.lastReadDeadline.IsZero() {
		t.Fatalf("expected read deadline cleared, got %v", conn.lastReadDeadline)
	}
}

func TestReadFrameGenericClearsReadDeadlineOnError(t *testing.T) {
	conn := &deadlineTrackingConn{
		readBuf: bytes.NewReader([]byte{0x01}),
	}

	buf := make([]byte, 16)
	if _, err := readFrameGeneric(conn, buf, time.Second, nil); err == nil {
		t.Fatalf("expected readFrameGeneric error")
	}
	if !conn.lastReadDeadline.IsZero() {
		t.Fatalf("expected read deadline cleared after error, got %v", conn.lastReadDeadline)
	}
}

func buildTestFrame(t *testing.T, flags byte, version uint16, tag byte, payload []byte, crypto *CryptoState) []byte {
	t.Helper()
	inner := make([]byte, 3+len(payload))
	binary.LittleEndian.PutUint16(inner[:2], version)
	inner[2] = tag
	copy(inner[3:], payload)

	if flags == 0x01 {
		if crypto == nil || !crypto.Enabled {
			t.Fatal("encrypted test frame requires configured crypto")
		}
		frameLen := 1 + CryptoNonceLen + len(inner) + CryptoTagLen
		frame := make([]byte, 5, 4+frameLen)
		binary.LittleEndian.PutUint32(frame[:4], uint32(frameLen))
		frame[4] = flags
		encrypted, err := EncryptFrame(&crypto.ClientKey, inner, frame)
		if err != nil {
			t.Fatalf("encrypt test frame: %v", err)
		}
		return append(frame, encrypted...)
	}

	frame := make([]byte, 5+len(inner))
	binary.LittleEndian.PutUint32(frame[:4], uint32(1+len(inner)))
	frame[4] = flags
	copy(frame[5:], inner)
	return frame
}

func TestReadFrameGenericContract(t *testing.T) {
	crypto, err := NewCryptoState("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	if err != nil {
		t.Fatal(err)
	}

	oversize := make([]byte, 4)
	binary.LittleEndian.PutUint32(oversize, 16)
	plaintextBoundary := buildTestFrame(t, 0x00, ProtocolVersion, TagReply, bytes.Repeat([]byte{0x5a}, 56), nil)
	encryptedBoundary := buildTestFrame(t, 0x01, ProtocolVersion, TagReply, bytes.Repeat([]byte{0x5a}, 16), crypto)
	if len(plaintextBoundary) != 64 || len(encryptedBoundary) != 64 {
		t.Fatal("test boundary frames must exactly fill their receive buffers")
	}
	cases := []struct {
		name      string
		frame     []byte
		readBuf   int
		crypto    *CryptoState
		wantError bool
	}{
		{name: "unknown flags", frame: buildTestFrame(t, 0x02, ProtocolVersion, TagReply, nil, nil), readBuf: 64, wantError: true},
		{name: "bad plaintext version", frame: buildTestFrame(t, 0x00, ProtocolVersion+1, TagReply, nil, nil), readBuf: 64, wantError: true},
		{name: "bad encrypted version", frame: buildTestFrame(t, 0x01, ProtocolVersion+1, TagReply, nil, crypto), readBuf: 128, crypto: crypto, wantError: true},
		{name: "plaintext while key configured", frame: buildTestFrame(t, 0x00, ProtocolVersion, TagReply, nil, nil), readBuf: 64, crypto: crypto, wantError: true},
		{name: "encrypted without key", frame: buildTestFrame(t, 0x01, ProtocolVersion, TagReply, nil, crypto), readBuf: 128, wantError: true},
		{name: "short plaintext", frame: []byte{1, 0, 0, 0, 0x00}, readBuf: 64, wantError: true},
		{name: "short encrypted", frame: []byte{1, 0, 0, 0, 0x01}, readBuf: 64, crypto: crypto, wantError: true},
		{name: "oversize declaration", frame: oversize, readBuf: 16, wantError: true},
		{name: "valid plaintext minimum", frame: buildTestFrame(t, 0x00, ProtocolVersion, TagReply, nil, nil), readBuf: 8},
		{name: "valid encrypted minimum", frame: buildTestFrame(t, 0x01, ProtocolVersion, TagReply, nil, crypto), readBuf: 64, crypto: crypto},
		{name: "valid plaintext receive-buffer boundary", frame: plaintextBoundary, readBuf: 64},
		{name: "valid encrypted receive-buffer boundary", frame: encryptedBoundary, readBuf: 64, crypto: crypto},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			conn := &deadlineTrackingConn{readBuf: bytes.NewReader(tc.frame)}
			frame, err := readFrameGeneric(conn, make([]byte, tc.readBuf), time.Second, tc.crypto)
			if tc.wantError {
				if err == nil {
					t.Fatalf("expected rejection, got frame %x", frame)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected rejection: %v", err)
			}
			if len(frame) < 3 || frame[2] != TagReply {
				t.Fatalf("decoded frame = %x", frame)
			}
		})
	}
}

func TestReadFrameGenericLeavesTrailingFrameForNextRead(t *testing.T) {
	first := buildTestFrame(t, 0x00, ProtocolVersion, TagReply, []byte{0xaa}, nil)
	second := buildTestFrame(t, 0x00, ProtocolVersion, TagRunResponse, []byte{0xbb}, nil)
	conn := &deadlineTrackingConn{readBuf: bytes.NewReader(append(first, second...))}

	frame, err := readFrameGeneric(conn, make([]byte, 64), time.Second, nil)
	if err != nil || frame[2] != TagReply || frame[3] != 0xaa {
		t.Fatalf("first frame = %x, err = %v", frame, err)
	}
	frame, err = readFrameGeneric(conn, make([]byte, 64), time.Second, nil)
	if err != nil || frame[2] != TagRunResponse || frame[3] != 0xbb {
		t.Fatalf("second frame = %x, err = %v", frame, err)
	}
}

func buildCommandReplyFrame(requestID uint64, entityID uint64) []byte {
	payload := make([]byte, 17)
	binary.LittleEndian.PutUint64(payload[0:8], requestID)
	payload[8] = 0
	binary.LittleEndian.PutUint64(payload[9:17], entityID)

	inner := make([]byte, 3+len(payload))
	binary.LittleEndian.PutUint16(inner[0:2], ProtocolVersion)
	inner[2] = TagReply
	copy(inner[3:], payload)

	frame := make([]byte, 5+len(inner))
	binary.LittleEndian.PutUint32(frame[0:4], uint32(1+len(inner)))
	frame[4] = 0x00
	copy(frame[5:], inner)
	return frame
}

func TestSendCommandTimedAllowsConcurrentConsensusCommands(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	type seenRequest struct {
		conn      net.Conn
		requestID uint64
	}
	seen := make(chan seenRequest, 2)
	done := make(chan struct{})

	go func() {
		defer close(done)
		for i := 0; i < 2; i++ {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				buf := make([]byte, 1024)
				frame, err := readFrameGeneric(conn, buf, time.Second, nil)
				if err != nil || len(frame) < 3 || frame[2] != TagClusterStateRequest {
					conn.Close()
					return
				}
				if _, err := conn.Write(buildClusterStateProbeFrame(true)); err != nil {
					conn.Close()
					return
				}
				frame, err = readFrameGeneric(conn, buf, time.Second, nil)
				if err != nil || len(frame) < 20 || frame[2] != TagRequest {
					conn.Close()
					return
				}
				payload := frame[3:]
				seen <- seenRequest{conn: conn, requestID: binary.LittleEndian.Uint64(payload[8:16])}
			}(conn)
		}
	}()

	client := NewClient([]string{listener.Addr().String()}, nil)
	results := make(chan CommandResult, 2)
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() {
			result, _, err := client.SendCommandTimed(CmdNoop, nil)
			if err != nil {
				errs <- err
				return
			}
			results <- result
		}()
	}

	first := <-seen
	select {
	case second := <-seen:
		if first.requestID == second.requestID {
			t.Fatalf("request IDs must be unique")
		}
		// Reply in reverse arrival order to prove commands are independent and not
		// serialized behind the first request's response.
		if _, err := second.conn.Write(buildCommandReplyFrame(second.requestID, 200)); err != nil {
			t.Fatalf("reply second: %v", err)
		}
		if _, err := first.conn.Write(buildCommandReplyFrame(first.requestID, 100)); err != nil {
			t.Fatalf("reply first: %v", err)
		}
		second.conn.Close()
		first.conn.Close()
	case <-time.After(500 * time.Millisecond):
		t.Fatalf("second concurrent command was not sent before first reply")
	}

	for i := 0; i < 2; i++ {
		select {
		case err := <-errs:
			t.Fatalf("command failed: %v", err)
		case result := <-results:
			if !result.OK {
				t.Fatalf("expected OK result: %+v", result)
			}
		case <-time.After(time.Second):
			t.Fatalf("timed out waiting for command result")
		}
	}

	listener.Close()
	<-done
}

func TestParseResultRejectsMismatchedRequestID(t *testing.T) {
	reply := make([]byte, 9)
	binary.LittleEndian.PutUint64(reply[0:8], 41)
	reply[8] = 0

	if _, err := parseResult(reply, 42); err == nil {
		t.Fatalf("expected request_id mismatch error")
	}
}

func buildRunResponseRaw(requestID uint64, status RunStatus, body []byte, extraTrailing bool) []byte {
	if body == nil && status != RunStatusOK {
		raw := make([]byte, 9)
		binary.LittleEndian.PutUint64(raw[0:8], requestID)
		raw[8] = byte(status)
		return raw
	}
	raw := make([]byte, 13+len(body))
	binary.LittleEndian.PutUint64(raw[0:8], requestID)
	raw[8] = byte(status)
	binary.LittleEndian.PutUint32(raw[9:13], uint32(len(body)))
	copy(raw[13:], body)
	if extraTrailing {
		raw = append(raw, 0xff)
	}
	return raw
}

func TestParseRunResponseExactLengthContract(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name    string
		raw     []byte
		wantErr string
		wantLen int
	}{
		{
			name:    "ok empty body",
			raw:     buildRunResponseRaw(7, RunStatusOK, nil, false),
			wantLen: 0,
		},
		{
			name:    "ok max body",
			raw:     buildRunResponseRaw(7, RunStatusOK, bytes.Repeat([]byte{1}, MaxRunResponseBody), false),
			wantLen: MaxRunResponseBody,
		},
		{
			name:    "body over max",
			raw:     buildRunResponseRaw(7, RunStatusOK, bytes.Repeat([]byte{1}, MaxRunResponseBody+1), false),
			wantErr: "exceeds max",
		},
		{
			name: "gateway error without length",
			raw:  buildRunResponseRaw(7, RunStatusDeploymentNotFound, nil, false),
		},
		{
			name: "ambiguous gateway error without length",
			raw:  buildRunResponseRaw(7, RunStatusOutcomeAmbiguous, nil, false),
		},
		{
			name:    "missing response length",
			raw:     []byte{7, 0, 0, 0, 0, 0, 0, 0, byte(RunStatusOK)},
			wantErr: "missing length",
		},
		{
			name:    "truncated response body",
			raw:     buildRunResponseRaw(7, RunStatusOK, []byte("hi"), false)[:14],
			wantErr: "length mismatch",
		},
		{
			name:    "extra response body",
			raw:     buildRunResponseRaw(7, RunStatusOK, []byte("hi"), true),
			wantErr: "length mismatch",
		},
		{
			name:    "partial length field",
			raw:     []byte{7, 0, 0, 0, 0, 0, 0, 0, byte(RunStatusOK), 1, 0},
			wantErr: "missing length",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resp, err := parseRunResponse(tc.raw)
			if tc.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q", tc.wantErr)
				}
				if !bytes.Contains([]byte(err.Error()), []byte(tc.wantErr)) {
					t.Fatalf("error = %v, want substring %q", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(resp.Body) != tc.wantLen {
				t.Fatalf("body len = %d, want %d", len(resp.Body), tc.wantLen)
			}
		})
	}
}

type failingWriteConn struct {
	writeCalls int
	closed     bool
}

func (c *failingWriteConn) Read([]byte) (int, error)         { return 0, net.ErrClosed }
func (c *failingWriteConn) Write([]byte) (int, error)        { c.writeCalls++; return 0, net.ErrClosed }
func (c *failingWriteConn) Close() error                     { c.closed = true; return nil }
func (c *failingWriteConn) LocalAddr() net.Addr              { return dummyAddr("local") }
func (c *failingWriteConn) RemoteAddr() net.Addr             { return dummyAddr("remote") }
func (c *failingWriteConn) SetDeadline(time.Time) error      { return nil }
func (c *failingWriteConn) SetReadDeadline(time.Time) error  { return nil }
func (c *failingWriteConn) SetWriteDeadline(time.Time) error { return nil }

type shortWriteConn struct {
	deadlineTrackingConn
	max int
}

func (c *shortWriteConn) Write(p []byte) (int, error) {
	if len(p) > c.max {
		p = p[:c.max]
	}
	return c.writeBuf.Write(p)
}

func TestWriteFrameLoopsOnShortWritesAndClearsDeadline(t *testing.T) {
	conn := &shortWriteConn{deadlineTrackingConn: deadlineTrackingConn{readBuf: bytes.NewReader(nil)}, max: 2}
	if err := writeFrame(conn, TagRequest, []byte("payload")); err != nil {
		t.Fatalf("writeFrame: %v", err)
	}
	if conn.writeBuf.Len() != 5+3+len("payload") {
		t.Fatalf("written bytes = %d", conn.writeBuf.Len())
	}
	if !conn.lastWriteDeadline.IsZero() {
		t.Fatalf("write deadline not cleared: %v", conn.lastWriteDeadline)
	}
}

type zeroWriteConn struct{ failingWriteConn }

func (c *zeroWriteConn) Write([]byte) (int, error) { c.writeCalls++; return 0, nil }

func TestSendRunRequestZeroNilWriteIsAmbiguousAndReleasesMutex(t *testing.T) {
	conn := &zeroWriteConn{}
	client := NewClient(nil, nil)
	client.conn = conn
	_, err := client.SendRunRequest("dep", []byte("x"))
	if !errors.Is(err, ErrRunOutcomeAmbiguous) {
		t.Fatalf("error = %v", err)
	}
	done := make(chan struct{})
	go func() { _ = client.IsConnected(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("client mutex remained locked after write failure")
	}
}

func TestWriteFrameDeadlineBoundsStalledPipe(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	start := time.Now()
	err := writeFrame(client, TagRequest, make([]byte, 64))
	if err == nil {
		t.Fatal("expected stalled write deadline")
	}
	if time.Since(start) > 3*time.Second {
		t.Fatalf("write exceeded bound: %v", time.Since(start))
	}
}

func TestSendRunRequestDoesNotResendAfterWriteFailure(t *testing.T) {
	conn := &failingWriteConn{}
	client := NewClient([]string{"127.0.0.1:1"}, nil)
	client.conn = conn

	_, err := client.SendRunRequest("dep", []byte("attempted"))
	if !errors.Is(err, ErrRunOutcomeAmbiguous) {
		t.Fatalf("error = %v, want ErrRunOutcomeAmbiguous", err)
	}
	if conn.writeCalls != 1 {
		t.Fatalf("write calls = %d, want exactly 1", conn.writeCalls)
	}
	if !conn.closed || client.conn != nil {
		t.Fatalf("failed connection was not closed and cleared")
	}
}

func TestSendRunRequestDoesNotResendAfterServerAcceptsRequest(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	requests := make(chan struct{}, 2)
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		for accepted := 0; accepted < 2; accepted++ {
			if tcpListener, ok := listener.(*net.TCPListener); ok {
				_ = tcpListener.SetDeadline(time.Now().Add(500 * time.Millisecond))
			}
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			buf := make([]byte, 1024)
			frame, err := readFrameGeneric(conn, buf, time.Second, nil)
			if err != nil || len(frame) < 3 || frame[2] != TagClusterStateRequest {
				conn.Close()
				return
			}
			if _, err := conn.Write(buildClusterStateProbeFrame(true)); err != nil {
				conn.Close()
				return
			}
			frame, err = readFrameGeneric(conn, buf, time.Second, nil)
			if err != nil || len(frame) < 3 || frame[2] != TagRunRequest {
				conn.Close()
				return
			}
			requests <- struct{}{}
			conn.Close()
		}
	}()

	client := NewClient([]string{listener.Addr().String()}, nil)
	_, err = client.SendRunRequest("dep", []byte("accepted"))
	if !errors.Is(err, ErrRunOutcomeAmbiguous) {
		t.Fatalf("error = %v, want ErrRunOutcomeAmbiguous", err)
	}
	<-serverDone
	close(requests)
	if got := len(requests); got != 1 {
		t.Fatalf("server received %d run requests, want exactly 1", got)
	}
}

func TestSendRunRequestParsesExplicitAmbiguousStatusAsSentinel(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 1024)
		if _, err := readFrameGeneric(conn, buf, time.Second, nil); err != nil {
			return
		}
		if _, err := conn.Write(buildClusterStateProbeFrame(true)); err != nil {
			return
		}
		frame, err := readFrameGeneric(conn, buf, time.Second, nil)
		if err != nil || len(frame) < 11 || frame[2] != TagRunRequest {
			return
		}
		requestID := binary.LittleEndian.Uint64(frame[3:11])
		raw := buildRunResponseRaw(requestID, RunStatusOutcomeAmbiguous, nil, false)
		inner := make([]byte, 3+len(raw))
		binary.LittleEndian.PutUint16(inner[:2], ProtocolVersion)
		inner[2] = TagRunResponse
		copy(inner[3:], raw)
		out := make([]byte, 5+len(inner))
		binary.LittleEndian.PutUint32(out[:4], uint32(1+len(inner)))
		copy(out[5:], inner)
		_, _ = conn.Write(out)
	}()

	client := NewClient([]string{listener.Addr().String()}, nil)
	resp, err := client.SendRunRequest("dep", []byte("request"))
	if !errors.Is(err, ErrRunOutcomeAmbiguous) {
		t.Fatalf("error = %v, want ErrRunOutcomeAmbiguous", err)
	}
	if resp == nil || resp.Status != RunStatusOutcomeAmbiguous {
		t.Fatalf("response = %+v, want explicit ambiguous status", resp)
	}
}

func TestRunStatusWireGolden(t *testing.T) {
	want := []string{
		"ok", "deployment_not_found", "queue_full", "invalid_payload",
		"response_too_large", "outcome_ambiguous", "forwarding_failed",
		"no_running_pod", "unavailable",
	}
	for wire, name := range want {
		status := RunStatus(wire)
		if status.String() != name {
			t.Fatalf("wire %d = %q, want %q", wire, status.String(), name)
		}
	}
}

func TestSendRunRequestRejectsOversizedPayloadAndRequestIDMismatch(t *testing.T) {
	t.Parallel()

	client := NewClient([]string{"127.0.0.1:1"}, nil)
	if _, err := client.SendRunRequest("dep", make([]byte, MaxRunPayload+1)); err == nil {
		t.Fatalf("expected oversized payload rejection")
	}

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()

	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 1024)
		// Leader probe first (dialLeader / reconnect).
		frame, err := readFrameGeneric(conn, buf, time.Second, nil)
		if err != nil || len(frame) < 3 || frame[2] != TagClusterStateRequest {
			return
		}
		if _, err := conn.Write(buildClusterStateProbeFrame(true)); err != nil {
			return
		}
		if _, err := readFrameGeneric(conn, buf, time.Second, nil); err != nil {
			return
		}
		// Reply with mismatched request_id.
		raw := buildRunResponseRaw(999, RunStatusOK, []byte("x"), false)
		inner := make([]byte, 3+len(raw))
		binary.LittleEndian.PutUint16(inner[0:2], ProtocolVersion)
		inner[2] = TagRunResponse
		copy(inner[3:], raw)
		out := make([]byte, 5+len(inner))
		binary.LittleEndian.PutUint32(out[0:4], uint32(1+len(inner)))
		out[4] = 0x00
		copy(out[5:], inner)
		_, _ = conn.Write(out)
	}()

	client = NewClient([]string{listener.Addr().String()}, nil)
	if _, err := client.SendRunRequest("dep", []byte("ok")); err == nil {
		t.Fatalf("expected request_id mismatch error")
	} else if !errors.Is(err, ErrRunOutcomeAmbiguous) {
		t.Fatalf("error = %v, want ErrRunOutcomeAmbiguous", err)
	} else if !bytes.Contains([]byte(err.Error()), []byte("request_id mismatch")) {
		t.Fatalf("error = %v, want request_id mismatch", err)
	}
}
