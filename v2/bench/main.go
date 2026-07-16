package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"math"
	"net"
	"sort"
	"strings"
	"time"
)

const (
	ClientTagRequest     byte   = 0x20
	ClientTagReply       byte   = 0x21
	ClientTagRunRequest  byte   = 0x22
	ClientTagRunResponse byte   = 0x23
	CmdCreateDeploy      byte   = 3
	ProtocolVersion      uint16 = 1

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
		runDeployBenchmark(addrList, *count, *replicas, *gpuCount)
	case "workload":
		runWorkloadBenchmark(addrList, *count, *depName, *payloadSize)
	default:
		fmt.Printf("unknown mode: %s (use deploy or workload)\n", *mode)
	}
}

// =================================================================
// Deploy benchmark (consensus path)
// =================================================================

func runDeployBenchmark(addrList []string, count, replicas, gpuCount int) {
	conn := findLeader(addrList)
	if conn == nil {
		return
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
			fmt.Printf("send failed at %d: %v\n", i, err)
			return
		}

		if _, err := readReply(conn, recvBuf); err != nil {
			fmt.Printf("recv failed at %d: %v\n", i, err)
			return
		}

		latencies = append(latencies, time.Since(start))
	}

	printResults("Deploy", count, time.Since(totalStart), latencies)
}

// =================================================================
// Workload benchmark (data plane, no consensus)
// =================================================================

func runWorkloadBenchmark(addrList []string, count int, depName string, payloadSize int) {
	// Connect directly (workload doesn't need leader discovery via consensus probe)
	addr := strings.TrimSpace(addrList[0])
	fmt.Printf("hivemind-bench: connecting to %s for workload\n", addr)

	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		fmt.Printf("connect failed: %v\n", err)
		return
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
			fmt.Printf("send failed at %d: %v\n", i, err)
			return
		}

		if _, err := readRunResponse(conn, recvBuf); err != nil {
			fmt.Printf("recv failed at %d: %v\n", i, err)
			return
		}

		latencies = append(latencies, time.Since(start))
	}

	printResults("Workload", count, time.Since(totalStart), latencies)
}

func sendRunRequest(conn net.Conn, requestID uint64, depName string, payload []byte) error {
	// Payload: request_id(u64) + deployment_name(64 bytes) + payload_len(u32) + payload
	data := make([]byte, 8+64+4+len(payload))
	binary.LittleEndian.PutUint64(data[0:8], requestID)
	copy(data[8:72], depName)
	binary.LittleEndian.PutUint32(data[72:76], uint32(len(payload)))
	copy(data[76:], payload)

	frame := make([]byte, 4+2+1+len(data))
	binary.LittleEndian.PutUint32(frame[0:4], uint32(2+1+len(data)))
	binary.LittleEndian.PutUint16(frame[4:6], ProtocolVersion)
	frame[6] = ClientTagRunRequest
	copy(frame[7:], data)

	_, err := conn.Write(frame)
	return err
}

func readRunResponse(conn net.Conn, buf []byte) ([]byte, error) {
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := readFull(conn, buf[:4]); err != nil {
		return nil, err
	}
	frameLen := binary.LittleEndian.Uint32(buf[:4])
	if frameLen > uint32(len(buf)) {
		return nil, fmt.Errorf("frame too large: %d", frameLen)
	}
	if frameLen < 3 {
		return nil, fmt.Errorf("frame too short: %d", frameLen)
	}
	if _, err := readFull(conn, buf[:frameLen]); err != nil {
		return nil, err
	}
	// buf[0:2] = version, buf[2] = tag
	if buf[2] != ClientTagRunResponse {
		return nil, fmt.Errorf("unexpected tag: 0x%02x", buf[2])
	}
	return buf[3:frameLen], nil
}

// =================================================================
// Shared helpers
// =================================================================

func findLeader(addrList []string) net.Conn {
	for _, addr := range addrList {
		addr = strings.TrimSpace(addr)
		fmt.Printf("hivemind-bench: trying %s... ", addr)

		c, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err != nil {
			fmt.Printf("connect failed\n")
			continue
		}

		probeClientID := uint64(time.Now().UnixNano())
		if err := sendProbe(c, probeClientID, 1); err != nil {
			fmt.Printf("send failed\n")
			c.Close()
			continue
		}

		buf := make([]byte, 256)
		reply, err := readReply(c, buf)
		if err != nil {
			fmt.Printf("read failed\n")
			c.Close()
			continue
		}

		if len(reply) >= 9 && reply[8] == ResultErr && len(reply) >= 10 && reply[9] == ErrNotLeader {
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

	frame := make([]byte, 4+2+1+len(payload))
	binary.LittleEndian.PutUint32(frame[0:4], uint32(2+1+len(payload)))
	binary.LittleEndian.PutUint16(frame[4:6], ProtocolVersion)
	frame[6] = ClientTagRequest
	copy(frame[7:], payload)

	_, err := conn.Write(frame)
	return err
}

func sendProbe(conn net.Conn, clientID, requestID uint64) error {
	const cmdSize = 138
	payload := make([]byte, 8+8+1+cmdSize)
	binary.LittleEndian.PutUint64(payload[0:8], clientID)
	binary.LittleEndian.PutUint64(payload[8:16], requestID)
	payload[16] = 0
	copy(payload[17:17+64], "bench-probe")

	frame := make([]byte, 4+2+1+len(payload))
	binary.LittleEndian.PutUint32(frame[0:4], uint32(2+1+len(payload)))
	binary.LittleEndian.PutUint16(frame[4:6], ProtocolVersion)
	frame[6] = ClientTagRequest
	copy(frame[7:], payload)

	_, err := conn.Write(frame)
	return err
}

func readReply(conn net.Conn, buf []byte) ([]byte, error) {
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := readFull(conn, buf[:4]); err != nil {
		return nil, err
	}
	frameLen := binary.LittleEndian.Uint32(buf[:4])
	if frameLen > uint32(len(buf)) {
		return nil, fmt.Errorf("frame too large: %d", frameLen)
	}
	if frameLen < 3 {
		return nil, fmt.Errorf("frame too short: %d", frameLen)
	}
	if _, err := readFull(conn, buf[:frameLen]); err != nil {
		return nil, err
	}
	// buf[0:2] = version, buf[2] = tag
	if buf[2] != ClientTagReply {
		return nil, fmt.Errorf("unexpected tag: 0x%02x", buf[2])
	}
	return buf[3:frameLen], nil
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
