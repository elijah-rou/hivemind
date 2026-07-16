package main

import (
	"encoding/binary"
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
		if len(request) != 4 || request[2] != ClientTagClusterStateRequest || request[3] != 0x01 {
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
		inner[2] = ClientTagClusterStateResp
		inner[3+26] = 1
		if _, err := conn.Write(inner); err != nil {
			done <- fmt.Errorf("write response body: %w", err)
			return
		}
		done <- nil
	}()

	return listener.Addr().String(), done
}

func TestFindLeaderAcceptsProbeResponseLargerThan256Bytes(t *testing.T) {
	const frameLen = 300
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

func TestFindLeaderAcceptsMaximumFrameBoundary(t *testing.T) {
	addr, done := startLeaderProbeServer(t, MaxFrameBytes-4)

	conn := findLeader([]string{addr})
	if conn == nil {
		t.Fatal("findLeader rejected valid maximum-sized frame")
	}
	if err := conn.Close(); err != nil {
		t.Fatalf("close leader connection: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestFindLeaderRejectsFrameOverMaximum(t *testing.T) {
	addr, done := startLeaderProbeServer(t, MaxFrameBytes-3)

	if conn := findLeader([]string{addr}); conn != nil {
		conn.Close()
		t.Fatal("findLeader accepted frame larger than MaxFrameBytes")
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
