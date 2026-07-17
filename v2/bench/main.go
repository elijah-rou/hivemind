package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"sort"
	"strings"
	"time"
)

type RunStatus byte

const (
	RunStatusOK                 RunStatus = 0
	RunStatusDeploymentNotFound RunStatus = 1
	RunStatusQueueFull          RunStatus = 2
	RunStatusInvalidPayload     RunStatus = 3
	RunStatusResponseTooLarge   RunStatus = 4
	RunStatusOutcomeAmbiguous   RunStatus = 5
	RunStatusForwardingFailed   RunStatus = 6
	RunStatusNoRunningPod       RunStatus = 7
	RunStatusUnavailable        RunStatus = 8
)

func runStatusName(status RunStatus) string {
	switch status {
	case RunStatusOK:
		return "ok"
	case RunStatusDeploymentNotFound:
		return "deployment_not_found"
	case RunStatusQueueFull:
		return "queue_full"
	case RunStatusInvalidPayload:
		return "invalid_payload"
	case RunStatusResponseTooLarge:
		return "response_too_large"
	case RunStatusOutcomeAmbiguous:
		return "outcome_ambiguous"
	case RunStatusForwardingFailed:
		return "forwarding_failed"
	case RunStatusNoRunningPod:
		return "no_running_pod"
	case RunStatusUnavailable:
		return "unavailable"
	default:
		return "unknown"
	}
}

const (
	ClientTagRequest             byte   = 0x20
	ClientTagReply               byte   = 0x21
	ClientTagRunRequest          byte   = 0x22
	ClientTagRunResponse         byte   = 0x23
	ClientTagClusterStateRequest byte   = 0x24
	ClientTagClusterStateResp    byte   = 0x25
	CmdCreateDeploy              byte   = 3
	ProtocolVersion              uint16 = 3
	MaxFrameBytes                       = 64 * 1024
	MaxRunPayload                       = 512
	MaxRunResponseBody                  = 16*1024 - 9

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

	if *count <= 0 {
		fmt.Fprintf(os.Stderr, "hivemind-bench: -n must be > 0\n")
		os.Exit(2)
	}
	if *payloadSize < 0 || *payloadSize > MaxRunPayload {
		fmt.Fprintf(os.Stderr, "hivemind-bench: -payload must be between 0 and %d\n", MaxRunPayload)
		os.Exit(2)
	}
	if *replicas < 0 || *gpuCount < 0 {
		fmt.Fprintf(os.Stderr, "hivemind-bench: -replicas and -gpus must be >= 0\n")
		os.Exit(2)
	}

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

		if err := readReply(conn, recvBuf, requestID); err != nil {
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
	return runWorkloadBenchmarkWithFinder(addrList, count, depName, payloadSize, findLeader)
}

func runWorkloadBenchmarkWithFinder(addrList []string, count int, depName string, payloadSize int, find func([]string) net.Conn) error {
	if payloadSize < 0 || payloadSize > MaxRunPayload {
		return fmt.Errorf("payload size must be between 0 and %d", MaxRunPayload)
	}
	if len(addrList) == 0 {
		return fmt.Errorf("no replica addresses configured")
	}

	payload := make([]byte, payloadSize)
	for i := range payload {
		payload[i] = byte(i % 256)
	}

	fmt.Printf("hivemind-bench: submitting %d workload requests (deployment=%s, payload=%d bytes)\n",
		count, depName, payloadSize)

	latencies := make([]time.Duration, 0, count)
	recvBuf := make([]byte, MaxFrameBytes)

	totalStart := time.Now()

	for i := 0; i < count; i++ {
		// Reprobe the configured list before each sample so a changed leader is
		// discovered without retrying an accepted request and risking duplicates.
		conn := find(addrList)
		if conn == nil {
			return fmt.Errorf("no leader found at workload request %d", i)
		}
		requestID := uint64(i + 1)
		start := time.Now()
		if err := sendRunRequest(conn, requestID, depName, payload); err != nil {
			_ = conn.Close()
			return fmt.Errorf("send failed at %d: %w", i, err)
		}
		if err := readRunResponse(conn, recvBuf, requestID); err != nil {
			_ = conn.Close()
			return fmt.Errorf("recv failed at %d: %w", i, err)
		}
		if err := conn.Close(); err != nil {
			return fmt.Errorf("close failed at %d: %w", i, err)
		}
		latencies = append(latencies, time.Since(start))
	}

	printResults("Workload", count, time.Since(totalStart), latencies)
	return nil
}

func sendRunRequest(conn net.Conn, requestID uint64, depName string, payload []byte) error {
	if len(payload) > MaxRunPayload {
		return fmt.Errorf("run payload exceeds max %d bytes", MaxRunPayload)
	}
	// Payload: request_id(u64) + deployment_name(64 bytes) + payload_len(u32) + payload
	data := make([]byte, 8+64+4+len(payload))
	binary.LittleEndian.PutUint64(data[0:8], requestID)
	copy(data[8:72], depName)
	binary.LittleEndian.PutUint32(data[72:76], uint32(len(payload)))
	copy(data[76:], payload)
	return writeFrame(conn, ClientTagRunRequest, data)
}

func readRunResponse(conn net.Conn, buf []byte, expectedRequestID uint64) error {
	frame, err := readFrame(conn, buf, 5*time.Second)
	if err != nil {
		return err
	}
	if len(frame) < 3 || frame[2] != ClientTagRunResponse {
		if len(frame) < 3 {
			return fmt.Errorf("short run response frame: %d bytes", len(frame))
		}
		return fmt.Errorf("unexpected tag: 0x%02x", frame[2])
	}
	return expectSuccessRunResponse(frame[3:], expectedRequestID)
}

// =================================================================
// Shared helpers
// =================================================================

// writeFrame encodes plaintext client frames:
// [4B len][1B flags=0x00][2B version][1B tag][payload...]
func writeFrame(conn net.Conn, tag byte, payload []byte) (err error) {
	if err := conn.SetWriteDeadline(time.Now().Add(2 * time.Second)); err != nil {
		return fmt.Errorf("set write deadline: %w", err)
	}
	defer func() {
		if clearErr := conn.SetWriteDeadline(time.Time{}); clearErr != nil && err == nil {
			err = fmt.Errorf("clear write deadline: %w", clearErr)
		}
	}()

	inner := make([]byte, 2+1+len(payload))
	binary.LittleEndian.PutUint16(inner[0:2], ProtocolVersion)
	inner[2] = tag
	copy(inner[3:], payload)

	frameLen := uint32(1 + len(inner)) // flags + inner
	header := make([]byte, 5)
	binary.LittleEndian.PutUint32(header[0:4], frameLen)
	header[4] = 0x00 // plaintext
	if err := writeAll(conn, header); err != nil {
		return err
	}
	return writeAll(conn, inner)
}

func writeAll(conn net.Conn, data []byte) error {
	for len(data) > 0 {
		n, err := conn.Write(data)
		if n < 0 || n > len(data) {
			return fmt.Errorf("invalid write count %d for %d bytes", n, len(data))
		}
		data = data[n:]
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}

// readFrame returns [version(2)][tag(1)][payload...].
func readFrame(conn net.Conn, buf []byte, timeout time.Duration) (frame []byte, err error) {
	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("set read deadline: %w", err)
	}
	defer func() {
		if clearErr := conn.SetReadDeadline(time.Time{}); clearErr != nil {
			_ = conn.Close()
			frame = nil
			err = fmt.Errorf("clear read deadline: %w", clearErr)
		}
	}()
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
	if flags != 0x00 {
		return nil, fmt.Errorf("unsupported frame flags: 0x%02x", flags)
	}
	if frameLen < 4 {
		return nil, fmt.Errorf("frame too short for flags+version+tag: %d", frameLen)
	}
	body := buf[5 : 4+frameLen]
	version := binary.LittleEndian.Uint16(body[0:2])
	if version != ProtocolVersion {
		return nil, fmt.Errorf("unsupported protocol version: %d", version)
	}
	return body, nil
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

		buf := make([]byte, MaxFrameBytes)
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
		if len(frame) < 3 {
			return false, fmt.Errorf("short probe frame: %d bytes", len(frame))
		}
		return false, fmt.Errorf("unexpected probe tag: 0x%02x", frame[2])
	}
	payload := frame[3:]
	// payload: query_type(1) + view(8) + commit_min(8) + op(8) + status(1) + is_leader(1)
	if len(payload) < 27 {
		return false, fmt.Errorf("probe reply too short: %d", len(payload))
	}
	return payload[26] == 1, nil
}

// CommandResult mirrors the client API wire result for deploy replies.
// Wire: [request_id(8)][result_type(1)][ok:entity_id(8) | err:code(1)].
type CommandResult struct {
	OK       bool
	EntityID uint64
	ErrCode  byte
}

// parseResult matches v2/api/client.go decode contract (bench is a separate module).
func parseResult(reply []byte, expectedRequestID uint64) (CommandResult, error) {
	if len(reply) < 9 {
		return CommandResult{}, fmt.Errorf("reply too short: %d bytes", len(reply))
	}
	replyRequestID := binary.LittleEndian.Uint64(reply[0:8])
	if replyRequestID != expectedRequestID {
		return CommandResult{}, fmt.Errorf("reply request_id mismatch: got %d want %d", replyRequestID, expectedRequestID)
	}

	switch reply[8] {
	case ResultOk:
		if len(reply) != 17 {
			return CommandResult{}, fmt.Errorf("ok reply length %d, want 17", len(reply))
		}
		return CommandResult{OK: true, EntityID: binary.LittleEndian.Uint64(reply[9:17])}, nil
	case ResultErr:
		if len(reply) != 10 {
			return CommandResult{}, fmt.Errorf("err reply length %d, want 10", len(reply))
		}
		return CommandResult{OK: false, ErrCode: reply[9]}, nil
	default:
		return CommandResult{}, fmt.Errorf("unknown result type: %d", reply[8])
	}
}

func expectSuccessResult(reply []byte, expectedRequestID uint64) error {
	result, err := parseResult(reply, expectedRequestID)
	if err != nil {
		return err
	}
	if !result.OK {
		return fmt.Errorf("reply error code %d", result.ErrCode)
	}
	return nil
}

func expectSuccessRunResponse(raw []byte, expectedRequestID uint64) error {
	if len(raw) < 9 {
		return fmt.Errorf("run response too short: %d bytes", len(raw))
	}
	replyRequestID := binary.LittleEndian.Uint64(raw[0:8])
	if replyRequestID != expectedRequestID {
		return fmt.Errorf("run response request_id mismatch: got %d want %d", replyRequestID, expectedRequestID)
	}
	status := RunStatus(raw[8])
	if status > RunStatusUnavailable {
		return fmt.Errorf("unknown run status %d", status)
	}
	if status != RunStatusOK {
		return fmt.Errorf("run status %s (%d)", runStatusName(status), status)
	}
	// Success requires explicit body length: request_id(8)+status(1)+len(4)+body.
	if len(raw) < 13 {
		return fmt.Errorf("run success truncated: %d bytes, need length field", len(raw))
	}
	bodyLen := binary.LittleEndian.Uint32(raw[9:13])
	if bodyLen > MaxRunResponseBody {
		return fmt.Errorf("run response body exceeds max %d bytes", MaxRunResponseBody)
	}
	want := 13 + int(bodyLen)
	if len(raw) != want {
		return fmt.Errorf("run success length %d, want %d", len(raw), want)
	}
	return nil
}

func readReply(conn net.Conn, buf []byte, expectedRequestID uint64) error {
	frame, err := readFrame(conn, buf, 5*time.Second)
	if err != nil {
		return err
	}
	if len(frame) < 3 || frame[2] != ClientTagReply {
		if len(frame) < 3 {
			return fmt.Errorf("short reply frame: %d bytes", len(frame))
		}
		return fmt.Errorf("unexpected tag: 0x%02x", frame[2])
	}
	return expectSuccessResult(frame[3:], expectedRequestID)
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
	if len(latencies) == 0 {
		fmt.Printf("\n=== Hivemind %s Benchmark Results ===\n", label)
		fmt.Printf("Requests:     %d\n", count)
		fmt.Printf("No completed samples\n")
		return
	}
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
