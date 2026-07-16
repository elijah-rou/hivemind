package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"math"
	"net"
	"os"
	"sort"
	"strings"
	"time"
)

const (
	ClientTagRequest             byte   = 0x20
	ClientTagReply               byte   = 0x21
	ClientTagRunRequest          byte   = 0x22
	ClientTagRunResponse         byte   = 0x23
	ClientTagClusterStateRequest byte   = 0x24
	ClientTagClusterStateResp    byte   = 0x25
	CmdCreateDeploy              byte   = 3
	ProtocolVersion              uint16 = 1

	ResultOk     byte = 0
	ResultErr    byte = 1
	ErrNotLeader byte = 5
)

func main() {
	addrs := flag.String("addrs", "127.0.0.1:9001", "comma-separated client API addresses")
	mode := flag.String("mode", "deploy", "benchmark mode: deploy or workload")
	count := flag.Int("n", 100, "number of requests")
	replicas := flag.Int("replicas", 1, "replicas per deployment (deploy mode)")
	gpuCount := flag.Int("gpus", 0, "GPUs per pod (deploy mode)")
	depName := flag.String("deployment", "bench-dep-0", "deployment name (workload mode)")
	payloadSize := flag.Int("payload", 64, "workload request payload size in bytes")
	flag.Parse()

	addrList := strings.Split(*addrs, ",")

	switch *mode {
	case "deploy":
		if err := runDeployBenchmark(addrList, *count, *replicas, *gpuCount); err != nil {
			fmt.Fprintf(os.Stderr, "hivemind-bench: %v\n", err)
			os.Exit(1)
		}
	case "workload":
		if err := runWorkloadBenchmark(addrList, *count, *depName, *payloadSize); err != nil {
			fmt.Fprintf(os.Stderr, "hivemind-bench: %v\n", err)
			os.Exit(1)
		}
	default:
		fmt.Printf("unknown mode: %s (use deploy or workload)\n", *mode)
		os.Exit(1)
	}
}

// =================================================================
// Deploy benchmark (consensus path)
// =================================================================

func runDeployBenchmark(addrList []string, count, replicas, gpuCount int) error {
	conn := findLeader(addrList)
	if conn == nil {
		return fmt.Errorf("no leader found")
	}
	defer conn.Close()

	fmt.Printf("hivemind-bench: submitting %d deployments (%d replicas, %d GPUs each)\n",
		count, replicas, gpuCount)

	latencies := make([]time.Duration, 0, count)
	recvBuf := make([]byte, 256)

	totalStart := time.Now()

	// Use timestamp-based clientID so repeated runs don't collide in the client table
	benchClientID := uint64(time.Now().UnixNano())
	for i := 0; i < count; i++ {
		clientID := benchClientID
		requestID := uint64(i + 1)
		name := fmt.Sprintf("bench-dep-%d", i)

		start := time.Now()

		if err := sendCreateDeployment(conn, clientID, requestID, name, replicas, gpuCount); err != nil {
			return fmt.Errorf("send failed at %d: %w", i, err)
		}

		if _, err := readReply(conn, recvBuf); err != nil {
			return fmt.Errorf("recv failed at %d: %w", i, err)
		}

		latencies = append(latencies, time.Since(start))
	}

	printResults("Deploy", count, time.Since(totalStart), latencies)
	return nil
}

// =================================================================
// Workload benchmark (data plane, no consensus)
// =================================================================

func runWorkloadBenchmark(addrList []string, count int, depName string, payloadSize int) error {
	addr := strings.TrimSpace(addrList[0])
	fmt.Printf("hivemind-bench: connecting to %s for workload\n", addr)

	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return fmt.Errorf("connect failed: %w", err)
	}
	defer conn.Close()

	payload := make([]byte, payloadSize)
	for i := range payload {
		payload[i] = byte(i % 256)
	}

	fmt.Printf("hivemind-bench: submitting %d workload requests (deployment=%s, payload=%d bytes)\n",
		count, depName, payloadSize)

	latencies := make([]time.Duration, 0, count)
	recvBuf := make([]byte, 8192)

	totalStart := time.Now()

	for i := 0; i < count; i++ {
		requestID := uint64(i + 1)

		start := time.Now()

		if err := sendRunRequest(conn, requestID, depName, payload); err != nil {
			return fmt.Errorf("send failed at %d: %w", i, err)
		}

		if _, err := readRunResponse(conn, recvBuf); err != nil {
			return fmt.Errorf("recv failed at %d: %w", i, err)
		}

		latencies = append(latencies, time.Since(start))
	}

	printResults("Workload", count, time.Since(totalStart), latencies)
	return nil
}

func sendRunRequest(conn net.Conn, requestID uint64, depName string, payload []byte) error {
	// Payload: request_id(u64) + deployment_name(64 bytes) + payload_len(u32) + payload
	data := make([]byte, 8+64+4+len(payload))
	binary.LittleEndian.PutUint64(data[0:8], requestID)
	copy(data[8:72], depName)
	binary.LittleEndian.PutUint32(data[72:76], uint32(len(payload)))
	copy(data[76:], payload)
	return writeFrame(conn, ClientTagRunRequest, data)
}

func readRunResponse(conn net.Conn, buf []byte) ([]byte, error) {
	frame, err := readFrame(conn, buf, 5*time.Second)
	if err != nil {
		return nil, err
	}
	if len(frame) < 3 || frame[2] != ClientTagRunResponse {
		return nil, fmt.Errorf("unexpected tag: 0x%02x", frame[2])
	}
	return frame[3:], nil
}

// =================================================================
// Shared helpers
// =================================================================

// writeFrame encodes plaintext client frames:
// [4B len][1B flags=0x00][2B version][1B tag][payload...]
func writeFrame(conn net.Conn, tag byte, payload []byte) error {
	inner := make([]byte, 2+1+len(payload))
	binary.LittleEndian.PutUint16(inner[0:2], ProtocolVersion)
	inner[2] = tag
	copy(inner[3:], payload)

	frameLen := uint32(1 + len(inner)) // flags + inner
	header := make([]byte, 5)
	binary.LittleEndian.PutUint32(header[0:4], frameLen)
	header[4] = 0x00 // plaintext
	if _, err := conn.Write(header); err != nil {
		return err
	}
	_, err := conn.Write(inner)
	return err
}

// readFrame returns [version(2)][tag(1)][payload...].
func readFrame(conn net.Conn, buf []byte, timeout time.Duration) ([]byte, error) {
	conn.SetReadDeadline(time.Now().Add(timeout))
	if _, err := readFull(conn, buf[:4]); err != nil {
		return nil, err
	}
	frameLen := binary.LittleEndian.Uint32(buf[:4])
	if frameLen < 1 || frameLen > uint32(len(buf))-4 {
		return nil, fmt.Errorf("bad frame len: %d", frameLen)
	}
	if _, err := readFull(conn, buf[4:4+frameLen]); err != nil {
		return nil, err
	}
	flags := buf[4]
	if flags&0x01 != 0 {
		return nil, fmt.Errorf("encrypted frame not supported by bench client")
	}
	return buf[5 : 4+frameLen], nil
}

func findLeader(addrList []string) net.Conn {
	for _, addr := range addrList {
		addr = strings.TrimSpace(addr)
		fmt.Printf("hivemind-bench: trying %s... ", addr)

		c, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err != nil {
			fmt.Printf("connect failed\n")
			continue
		}

		if err := sendLeaderProbe(c); err != nil {
			fmt.Printf("send failed\n")
			c.Close()
			continue
		}

		buf := make([]byte, 256)
		isLeader, err := readLeaderProbe(c, buf)
		if err != nil {
			fmt.Printf("read failed\n")
			c.Close()
			continue
		}
		if !isLeader {
			fmt.Printf("not leader\n")
			c.Close()
			continue
		}

		fmt.Printf("LEADER\n")
		return c
	}

	fmt.Println("hivemind-bench: no leader found")
	return nil
}

func sendCreateDeployment(conn net.Conn, clientID, requestID uint64, name string, replicas, gpuCount int) error {
	const cmdSize = 64 + 64 + 256 + 4 + 4 + 4 + 1 + 1
	payload := make([]byte, 8+8+1+cmdSize)

	binary.LittleEndian.PutUint64(payload[0:8], clientID)
	binary.LittleEndian.PutUint64(payload[8:16], requestID)
	payload[16] = CmdCreateDeploy

	off := 17
	copy(payload[off:off+64], name)
	off += 64
	copy(payload[off:off+64], "bench")
	off += 64
	copy(payload[off:off+256], "bench:latest")
	off += 256
	binary.LittleEndian.PutUint32(payload[off:off+4], uint32(replicas))
	off += 4
	binary.LittleEndian.PutUint32(payload[off:off+4], 2000)
	off += 4
	binary.LittleEndian.PutUint32(payload[off:off+4], 4096)
	off += 4
	if gpuCount > 0 {
		payload[off] = 3
	} else {
		payload[off] = 0
	}
	off++
	payload[off] = byte(gpuCount)

	return writeFrame(conn, ClientTagRequest, payload)
}

func sendLeaderProbe(conn net.Conn) error {
	// Read-only cluster_state_request (matches api/client.go probeIsLeader).
	return writeFrame(conn, ClientTagClusterStateRequest, []byte{0x01})
}

func readLeaderProbe(conn net.Conn, buf []byte) (bool, error) {
	frame, err := readFrame(conn, buf, 2*time.Second)
	if err != nil {
		return false, err
	}
	if len(frame) < 3 || frame[2] != ClientTagClusterStateResp {
		return false, fmt.Errorf("unexpected probe tag: 0x%02x", frame[2])
	}
	payload := frame[3:]
	// payload: query_type(1) + view(8) + commit_min(8) + op(8) + status(1) + is_leader(1)
	if len(payload) < 27 {
		return false, fmt.Errorf("probe reply too short: %d", len(payload))
	}
	return payload[26] == 1, nil
}

func readReply(conn net.Conn, buf []byte) ([]byte, error) {
	frame, err := readFrame(conn, buf, 5*time.Second)
	if err != nil {
		return nil, err
	}
	if len(frame) < 3 || frame[2] != ClientTagReply {
		return nil, fmt.Errorf("unexpected tag: 0x%02x", frame[2])
	}
	return frame[3:], nil
}

func readFull(conn net.Conn, buf []byte) (int, error) {
	total := 0
	for total < len(buf) {
		n, err := conn.Read(buf[total:])
		if err != nil {
			return total, err
		}
		total += n
	}
	return total, nil
}

func printResults(label string, count int, totalDuration time.Duration, latencies []time.Duration) {
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })

	n := len(latencies)
	p50 := latencies[min(n/2, n-1)]
	p99 := latencies[min(int(float64(n)*0.99), n-1)]
	p999 := latencies[min(int(math.Min(float64(n)*0.999, float64(n-1))), n-1)]
	throughput := float64(count) / totalDuration.Seconds()

	var sum time.Duration
	for _, l := range latencies {
		sum += l
	}
	avg := sum / time.Duration(len(latencies))

	fmt.Println()
	fmt.Printf("=== Hivemind %s Benchmark Results ===\n", label)
	fmt.Printf("Requests:     %d\n", count)
	fmt.Printf("Total time:   %s\n", totalDuration.Round(time.Microsecond))
	fmt.Printf("Throughput:   %.1f req/sec\n", throughput)
	fmt.Println()
	fmt.Printf("Latency:\n")
	fmt.Printf("  avg:  %s\n", avg.Round(time.Microsecond))
	fmt.Printf("  p50:  %s\n", p50.Round(time.Microsecond))
	fmt.Printf("  p99:  %s\n", p99.Round(time.Microsecond))
	fmt.Printf("  p999: %s\n", p999.Round(time.Microsecond))
	fmt.Printf("  min:  %s\n", latencies[0].Round(time.Microsecond))
	fmt.Printf("  max:  %s\n", latencies[len(latencies)-1].Round(time.Microsecond))
}
