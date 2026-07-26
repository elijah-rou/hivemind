package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"testing"
	"time"
)

func startLeaderProbeServer(t *testing.T, frameLen int) (string, <-chan error) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		defer listener.Close()
		conn, err := listener.Accept()
		if err != nil {
			done <- fmt.Errorf("accept: %w", err)
			return
		}
		defer conn.Close()

		requestBuf := make([]byte, MaxFrameBytes)
		request, err := readFrame(conn, requestBuf, time.Second)
		if err != nil {
			done <- fmt.Errorf("read probe: %w", err)
			return
		}
		if len(request) != 3 || request[2] != ClientTagLeaderProbeRequest {
			done <- fmt.Errorf("unexpected probe request: %x", request)
			return
		}

		header := make([]byte, 5)
		binary.LittleEndian.PutUint32(header[:4], uint32(frameLen))
		header[4] = 0x00
		if _, err := conn.Write(header); err != nil {
			done <- fmt.Errorf("write response header: %w", err)
			return
		}
		if frameLen > MaxFrameBytes-4 {
			done <- nil
			return
		}

		inner := make([]byte, frameLen-1)
		binary.LittleEndian.PutUint16(inner[:2], ProtocolVersion)
		inner[2] = ClientTagLeaderProbeResponse
		if len(inner) >= 3+LeaderProbeResponseBytes {
			inner[4] = 1
		}
		if _, err := conn.Write(inner); err != nil {
			done <- fmt.Errorf("write response body: %w", err)
			return
		}
		done <- nil
	}()

	return listener.Addr().String(), done
}

func TestFindLeaderAcceptsFixedProbeResponse(t *testing.T) {
	const frameLen = 1 + 3 + LeaderProbeResponseBytes
	addr, done := startLeaderProbeServer(t, frameLen)

	conn := findLeader([]string{addr})
	if conn == nil {
		t.Fatal("findLeader rejected valid framed cluster-state response larger than 256 bytes")
	}
	if err := conn.Close(); err != nil {
		t.Fatalf("close leader connection: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestFindLeaderRejectsNonFixedProbeResponse(t *testing.T) {
	addr, done := startLeaderProbeServer(t, 1+3+LeaderProbeResponseBytes+1)

	if conn := findLeader([]string{addr}); conn != nil {
		conn.Close()
		t.Fatal("findLeader accepted non-fixed leader response")
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

type failingReadDeadlineConn struct {
	reader    *bytes.Reader
	failSet   bool
	failClear bool
	closed    bool
	readCalls int
}

func (c *failingReadDeadlineConn) Read(p []byte) (int, error)  { c.readCalls++; return c.reader.Read(p) }
func (c *failingReadDeadlineConn) Write(p []byte) (int, error) { return len(p), nil }
func (c *failingReadDeadlineConn) Close() error                { c.closed = true; return nil }
func (c *failingReadDeadlineConn) LocalAddr() net.Addr         { return pipeAddr("local") }
func (c *failingReadDeadlineConn) RemoteAddr() net.Addr        { return pipeAddr("remote") }
func (c *failingReadDeadlineConn) SetDeadline(time.Time) error { return nil }
func (c *failingReadDeadlineConn) SetReadDeadline(deadline time.Time) error {
	if !deadline.IsZero() && c.failSet {
		return errors.New("injected set failure")
	}
	if deadline.IsZero() && c.failClear {
		return errors.New("injected clear failure")
	}
	return nil
}
func (c *failingReadDeadlineConn) SetWriteDeadline(time.Time) error { return nil }

func benchFrame(tag byte, payload []byte) []byte {
	inner := make([]byte, 3+len(payload))
	binary.LittleEndian.PutUint16(inner[:2], ProtocolVersion)
	inner[2] = tag
	copy(inner[3:], payload)
	frame := make([]byte, 5+len(inner))
	binary.LittleEndian.PutUint32(frame[:4], uint32(1+len(inner)))
	copy(frame[5:], inner)
	return frame
}

func TestBenchReceiversFailClosedOnReadDeadlineErrors(t *testing.T) {
	cases := []struct {
		name  string
		frame []byte
		call  func(net.Conn) error
	}{
		{name: "command", frame: benchFrame(ClientTagReply, make([]byte, 17)), call: func(c net.Conn) error { return readReply(c, make([]byte, 256), 0) }},
		{name: "run", frame: benchFrame(ClientTagRunResponse, make([]byte, 13)), call: func(c net.Conn) error { _, err := readRunResponse(c, make([]byte, 256), 0); return err }},
		{name: "leader probe", frame: benchFrame(ClientTagLeaderProbeResponse, make([]byte, LeaderProbeResponseBytes)), call: func(c net.Conn) error { _, err := readLeaderProbe(c, make([]byte, 256)); return err }},
	}
	for _, tc := range cases {
		for _, failure := range []string{"set", "clear"} {
			t.Run(tc.name+"/"+failure, func(t *testing.T) {
				conn := &failingReadDeadlineConn{reader: bytes.NewReader(tc.frame), failSet: failure == "set", failClear: failure == "clear"}
				if err := tc.call(conn); err == nil {
					t.Fatal("expected deadline failure")
				}
				if !conn.closed {
					t.Fatal("deadline failure did not close connection")
				}
				if failure == "set" && conn.readCalls != 0 {
					t.Fatalf("read calls = %d, want 0", conn.readCalls)
				}
			})
		}
	}
}
