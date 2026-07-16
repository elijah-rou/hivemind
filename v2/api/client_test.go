package main

import (
	"bytes"
	"encoding/binary"
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

func buildRunResponseRaw(requestID uint64, status byte, body []byte, extraTrailing bool) []byte {
	if body == nil && status != RunStatusOK {
		raw := make([]byte, 9)
		binary.LittleEndian.PutUint64(raw[0:8], requestID)
		raw[8] = status
		return raw
	}
	raw := make([]byte, 13+len(body))
	binary.LittleEndian.PutUint64(raw[0:8], requestID)
	raw[8] = status
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
			raw:     buildRunResponseRaw(7, RunStatusOK, bytes.Repeat([]byte{1}, MaxRunPayload), false),
			wantLen: MaxRunPayload,
		},
		{
			name: "gateway error without length",
			raw:  buildRunResponseRaw(7, RunStatusNotFound, nil, false),
		},
		{
			name:    "missing response length",
			raw:     []byte{7, 0, 0, 0, 0, 0, 0, 0, RunStatusOK},
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
			raw:     []byte{7, 0, 0, 0, 0, 0, 0, 0, RunStatusOK, 1, 0},
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
	} else if !bytes.Contains([]byte(err.Error()), []byte("request_id mismatch")) {
		t.Fatalf("error = %v, want request_id mismatch", err)
	}
}
