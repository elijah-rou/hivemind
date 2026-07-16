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

func TestSendRunRequestRejectsOversizeBeforeWriting(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	if err := sendRunRequest(client, 1, "dep", make([]byte, MaxRunPayload+1)); err == nil {
		t.Fatal("expected oversized payload rejection")
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
