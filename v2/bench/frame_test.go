package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

// pipeConn is a half-duplex net.Conn backed by an io.Pipe for framing tests.
type pipeConn struct {
	r *io.PipeReader
	w *io.PipeWriter
}

func (c *pipeConn) Read(b []byte) (int, error)         { return c.r.Read(b) }
func (c *pipeConn) Write(b []byte) (int, error)        { return c.w.Write(b) }
func (c *pipeConn) Close() error                       { _ = c.r.Close(); return c.w.Close() }
func (c *pipeConn) LocalAddr() net.Addr                { return pipeAddr("local") }
func (c *pipeConn) RemoteAddr() net.Addr               { return pipeAddr("remote") }
func (c *pipeConn) SetDeadline(t time.Time) error      { return nil }
func (c *pipeConn) SetReadDeadline(t time.Time) error  { return nil }
func (c *pipeConn) SetWriteDeadline(t time.Time) error { return nil }

type pipeAddr string

func (a pipeAddr) Network() string { return "pipe" }
func (a pipeAddr) String() string  { return string(a) }

func TestWorkloadBenchmarkReprobesLeaderAcrossAddressList(t *testing.T) {
	firstClient, firstServer := net.Pipe()
	secondClient, secondServer := net.Pipe()
	defer firstServer.Close()
	defer secondServer.Close()

	writeRunResponse := func(conn net.Conn, requestID uint64, status byte) {
		payload := make([]byte, 9)
		binary.LittleEndian.PutUint64(payload[:8], requestID)
		payload[8] = status
		if status == 0 {
			payload = append(payload, 0, 0, 0, 0)
		}
		_ = writeFrame(conn, ClientTagRunResponse, payload)
	}
	serve := func(conn net.Conn, status byte) {
		buf := make([]byte, MaxFrameBytes)
		frame, err := readFrame(conn, buf, time.Second)
		if err != nil || len(frame) < 11 || frame[2] != ClientTagRunRequest {
			return
		}
		writeRunResponse(conn, binary.LittleEndian.Uint64(frame[3:11]), status)
	}
	go serve(firstServer, 0)
	go serve(secondServer, 0)

	finderCalls := 0
	finder := func(addrs []string) net.Conn {
		if len(addrs) != 2 || addrs[0] != "replica-a" || addrs[1] != "replica-b" {
			t.Fatalf("finder received addresses %v", addrs)
		}
		finderCalls++
		if finderCalls == 1 {
			return firstClient
		}
		return secondClient
	}
	if err := runWorkloadBenchmarkWithFinder([]string{"replica-a", "replica-b"}, 2, "echo", 0, finder); err != nil {
		t.Fatalf("workload benchmark did not recover: %v", err)
	}
	if finderCalls != 2 {
		t.Fatalf("finder calls=%d want 2", finderCalls)
	}
}

func TestSendRunRequestRejectsOversizeBeforeWriting(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	if err := sendRunRequest(client, 1, "dep", make([]byte, MaxRunPayload+1)); err == nil {
		t.Fatal("expected oversized payload rejection")
	}
}

type boundedShortConn struct {
	bytes.Buffer
	max      int
	deadline time.Time
}

func (c *boundedShortConn) Read([]byte) (int, error) { return 0, io.EOF }
func (c *boundedShortConn) Write(p []byte) (int, error) {
	if len(p) > c.max {
		p = p[:c.max]
	}
	return c.Buffer.Write(p)
}
func (c *boundedShortConn) Close() error                       { return nil }
func (c *boundedShortConn) LocalAddr() net.Addr                { return pipeAddr("local") }
func (c *boundedShortConn) RemoteAddr() net.Addr               { return pipeAddr("remote") }
func (c *boundedShortConn) SetDeadline(t time.Time) error      { c.deadline = t; return nil }
func (c *boundedShortConn) SetReadDeadline(time.Time) error    { return nil }
func (c *boundedShortConn) SetWriteDeadline(t time.Time) error { c.deadline = t; return nil }

func TestWriteFrameLoopsOnShortWritesAndClearsDeadline(t *testing.T) {
	conn := &boundedShortConn{max: 2}
	if err := writeFrame(conn, ClientTagRequest, []byte("payload")); err != nil {
		t.Fatal(err)
	}
	if conn.Len() != 5+3+len("payload") {
		t.Fatalf("wrote %d bytes", conn.Len())
	}
	if !conn.deadline.IsZero() {
		t.Fatalf("deadline not cleared: %v", conn.deadline)
	}
}

func TestWriteFrameRejectsZeroNilWrite(t *testing.T) {
	conn := &boundedShortConn{max: 0}
	if err := writeFrame(conn, ClientTagRequest, nil); err == nil {
		t.Fatal("expected short write error")
	}
}

func TestWriteFrameBoundsStalledPipe(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	start := time.Now()
	if err := writeFrame(client, ClientTagRequest, make([]byte, 64)); err == nil {
		t.Fatal("expected deadline")
	}
	if time.Since(start) > 3*time.Second {
		t.Fatalf("write exceeded bound: %v", time.Since(start))
	}
}

func TestWriteFrameIncludesFlagsByte(t *testing.T) {
	pr, pw := io.Pipe()
	client := &pipeConn{w: pw}
	serverR := pr

	payload := []byte{0x01, 0x02, 0x03}
	done := make(chan error, 1)
	go func() {
		done <- writeFrame(client, ClientTagClusterStateRequest, payload)
	}()

	header := make([]byte, 5)
	if _, err := io.ReadFull(serverR, header); err != nil {
		t.Fatalf("read header: %v", err)
	}
	frameLen := binary.LittleEndian.Uint32(header[0:4])
	if header[4] != 0x00 {
		t.Fatalf("expected plaintext flags=0x00, got 0x%02x", header[4])
	}
	wantLen := uint32(1 + 2 + 1 + len(payload)) // flags + version + tag + payload
	if frameLen != wantLen {
		t.Fatalf("frameLen=%d want %d", frameLen, wantLen)
	}
	body := make([]byte, frameLen-1) // after flags already in header[4]
	if _, err := io.ReadFull(serverR, body); err != nil {
		t.Fatalf("read body: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("writeFrame: %v", err)
	}
	if binary.LittleEndian.Uint16(body[0:2]) != ProtocolVersion {
		t.Fatalf("bad version")
	}
	if body[2] != ClientTagClusterStateRequest {
		t.Fatalf("bad tag 0x%02x", body[2])
	}
	if !bytes.Equal(body[3:], payload) {
		t.Fatalf("payload mismatch: %v", body[3:])
	}
	_ = pw.Close()
	_ = pr.Close()
}

func TestReadFrameAcceptsSharedMaximumBoundary(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	innerLen := MaxFrameBytes - 5
	done := make(chan error, 1)
	go func() {
		inner := make([]byte, innerLen)
		binary.LittleEndian.PutUint16(inner[0:2], ProtocolVersion)
		inner[2] = ClientTagClusterStateResp
		header := make([]byte, 5)
		binary.LittleEndian.PutUint32(header[0:4], uint32(1+len(inner)))
		header[4] = 0
		if _, err := server.Write(header); err != nil {
			done <- err
			return
		}
		_, err := server.Write(inner)
		done <- err
	}()

	buf := make([]byte, MaxFrameBytes)
	frame, err := readFrame(client, buf, time.Second)
	if err != nil {
		t.Fatalf("read shared max frame: %v", err)
	}
	if len(frame) != innerLen {
		t.Fatalf("frame length=%d want %d", len(frame), innerLen)
	}
	if err := <-done; err != nil {
		t.Fatalf("write max frame: %v", err)
	}
}

func TestReadFrameRoundTrip(t *testing.T) {
	sr, cw := io.Pipe()
	cr, sw := io.Pipe()
	client := &pipeConn{r: cr, w: cw}
	// server writes a reply frame into sw; client reads via cr
	go func() {
		inner := make([]byte, 2+1+4)
		binary.LittleEndian.PutUint16(inner[0:2], ProtocolVersion)
		inner[2] = ClientTagReply
		copy(inner[3:], []byte{9, 8, 7, 6})
		frameLen := uint32(1 + len(inner))
		header := make([]byte, 5)
		binary.LittleEndian.PutUint32(header[0:4], frameLen)
		header[4] = 0x00
		_, _ = sw.Write(header)
		_, _ = sw.Write(inner)
		_ = sw.Close()
	}()

	buf := make([]byte, 256)
	frame, err := readFrame(client, buf, time.Second)
	if err != nil {
		t.Fatalf("readFrame: %v", err)
	}
	if len(frame) < 3 || frame[2] != ClientTagReply {
		t.Fatalf("unexpected frame: %v", frame)
	}
	if !bytes.Equal(frame[3:], []byte{9, 8, 7, 6}) {
		t.Fatalf("payload=%v", frame[3:])
	}
	_ = sr.Close()
	_ = cw.Close()
	_ = cr.Close()
}

func TestShortFrameErrorDoesNotPanic(t *testing.T) {
	// Flags-only plaintext body: version/tag missing — must fail closed.
	cr, sw := io.Pipe()
	client := &pipeConn{r: cr}
	go func() {
		header := make([]byte, 5)
		binary.LittleEndian.PutUint32(header[0:4], 1) // flags only
		header[4] = 0x00
		_, _ = sw.Write(header)
		_ = sw.Close()
	}()

	buf := make([]byte, 256)
	_, err := readFrame(client, buf, time.Second)
	_ = cr.Close()
	if err == nil || !strings.Contains(err.Error(), "too short") {
		t.Fatalf("expected too-short frame error, got %v", err)
	}
}

func TestFormatShortFrameError(t *testing.T) {
	frame := []byte{}
	if len(frame) < 3 {
		err := fmt.Errorf("short reply frame: %d bytes", len(frame))
		if err == nil {
			t.Fatal("expected error")
		}
		return
	}
	t.Fatalf("should not index frame[2]")
}

func TestReadFrameRejectsUnknownFlags(t *testing.T) {
	cr, sw := io.Pipe()
	client := &pipeConn{r: cr}
	go func() {
		inner := make([]byte, 2+1+1)
		binary.LittleEndian.PutUint16(inner[0:2], ProtocolVersion)
		inner[2] = ClientTagReply
		inner[3] = 0
		header := make([]byte, 5)
		binary.LittleEndian.PutUint32(header[0:4], uint32(1+len(inner)))
		header[4] = 0x02 // unknown plaintext flag bit
		_, _ = sw.Write(header)
		_, _ = sw.Write(inner)
		_ = sw.Close()
	}()
	buf := make([]byte, 256)
	_, err := readFrame(client, buf, time.Second)
	_ = cr.Close()
	if err == nil || !strings.Contains(err.Error(), "flags") {
		t.Fatalf("expected flags error, got %v", err)
	}
}

func TestReadFrameRejectsBadVersion(t *testing.T) {
	cr, sw := io.Pipe()
	client := &pipeConn{r: cr}
	go func() {
		inner := make([]byte, 2+1+1)
		binary.LittleEndian.PutUint16(inner[0:2], ProtocolVersion+1)
		inner[2] = ClientTagReply
		inner[3] = 0
		header := make([]byte, 5)
		binary.LittleEndian.PutUint32(header[0:4], uint32(1+len(inner)))
		header[4] = 0x00
		_, _ = sw.Write(header)
		_, _ = sw.Write(inner)
		_ = sw.Close()
	}()
	buf := make([]byte, 256)
	_, err := readFrame(client, buf, time.Second)
	_ = cr.Close()
	if err == nil || !strings.Contains(err.Error(), "version") {
		t.Fatalf("expected version error, got %v", err)
	}
}
