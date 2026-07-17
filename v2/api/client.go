package main

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Wire protocol tags
const (
	TagRequest              byte = 0x20
	TagReply                byte = 0x21
	TagRunRequest           byte = 0x22
	TagRunResponse          byte = 0x23
	TagClusterStateRequest  byte = 0x24
	TagClusterStateResponse byte = 0x25
)

// Command tags (consensus operations)
const (
	CmdRegisterNode     byte = 0
	CmdDeregisterNode   byte = 1
	CmdUpdateNodeStatus byte = 2
	CmdCreateDeployment byte = 3
	CmdBindPodToNode    byte = 4
	CmdUpdatePodStatus  byte = 5
	CmdScaleDeployment  byte = 6
	CmdUnbindPod        byte = 7
	CmdSetKillswitch    byte = 8
	CmdNoop             byte = 9
	CmdUpdateDeployment byte = 10
	CmdSetTrafficSplit  byte = 11
	CmdRollbackDeploy   byte = 12
	CmdDeleteDeployment byte = 13
	CmdPauseDeployment  byte = 14
	CmdResumeDeployment byte = 15
)

// Error codes from Hivemind
const (
	ErrCodeOk                byte = 0
	ErrCodeNotFound          byte = 1
	ErrCodeAlreadyExists     byte = 2
	ErrCodeCapacityExceeded  byte = 3
	ErrCodeInvalidTransition byte = 4
	ErrCodeNotLeader         byte = 5
	ErrCodeLogFull           byte = 6
)

// GPU types matching Zig enum
var gpuTypeMap = map[string]byte{
	"none":      0,
	"a100_40":   1,
	"a100_80":   2,
	"h100_sxm":  3,
	"h100_pcie": 4,
	"h200":      5,
	"l40s":      6,
	"a10g":      7,
	"t4":        8,
}

type CommandResult struct {
	OK       bool
	EntityID uint64
	ErrCode  byte
}

type TimedSpan struct {
	Phase   string
	StartMS int64
	EndMS   int64
	Source  string
}

type CommandTimings struct {
	RequestID uint64
	SpansRaw  []TimedSpan
}

func (t CommandTimings) Spans(op, scenario, entity, name string, deploymentID, podID uint64) []LatencySpan {
	out := make([]LatencySpan, 0, len(t.SpansRaw))
	for _, raw := range t.SpansRaw {
		out = append(out, LatencySpan{
			Scenario:     scenario,
			Entity:       entity,
			DeploymentID: deploymentID,
			PodID:        podID,
			Name:         name,
			Op:           op,
			Phase:        raw.Phase,
			StartMS:      raw.StartMS,
			EndMS:        raw.EndMS,
			Count:        1,
			Source:       raw.Source,
		})
	}
	return out
}

const commandInFlightMax = 32

type HivemindClient struct {
	mu        sync.Mutex
	conn      net.Conn
	addrs     []string
	leader    string
	requestID atomic.Uint64
	clientID  uint64
	crypto    *CryptoState

	commandSlots chan struct{}
}

func NewClient(addrs []string, crypto *CryptoState) *HivemindClient {
	var idBuf [8]byte
	if _, err := rand.Read(idBuf[:]); err != nil {
		panic(fmt.Sprintf("hivemind-api: failed to seed client id: %v", err))
	}
	id := binary.LittleEndian.Uint64(idBuf[:]) | (1 << 63)
	return &HivemindClient{
		addrs:        addrs,
		clientID:     id,
		crypto:       crypto,
		commandSlots: make(chan struct{}, commandInFlightMax),
	}
}

func (c *HivemindClient) Connect() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connectLocked(nil)
}

func (c *HivemindClient) connectLocked(spans *[]TimedSpan) error {
	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
	}

	conn, leader, err := c.dialLeader(spans)
	if err != nil {
		return err
	}
	c.conn = conn
	c.leader = leader
	return nil
}

func (c *HivemindClient) dialLeader(spans *[]TimedSpan) (net.Conn, string, error) {
	for _, addr := range c.addrs {
		conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err != nil {
			continue
		}

		// Read-only leader probe via cluster_state_request. Does NOT mutate state.
		probeStart := nowWallMS()
		isLeader, err := probeIsLeader(conn, c.crypto)
		probeEnd := nowWallMS()
		if spans != nil {
			*spans = append(*spans, TimedSpan{Phase: "reconnect_probe", StartMS: probeStart, EndMS: probeEnd, Source: "api/client.go"})
		}
		if err != nil || !isLeader {
			conn.Close()
			continue
		}

		return conn, addr, nil
	}

	return nil, "", fmt.Errorf("no leader found among %v", c.addrs)
}

func (c *HivemindClient) reconnect(spans *[]TimedSpan) error {
	return c.connectLocked(spans)
}

func (c *HivemindClient) closeLocked() {
	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
	}
	c.leader = ""
}

func (c *HivemindClient) refreshLocked() error {
	if c.conn != nil {
		if ok, err := probeIsLeader(c.conn, c.crypto); err == nil && ok {
			return nil
		}
	}
	return c.reconnect(nil)
}

// Refresh reconnects to the current leader if the existing connection is stale.
func (c *HivemindClient) Refresh() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.refreshLocked()
}

// SendCommand sends a consensus request and waits for the reply.
func (c *HivemindClient) SendCommand(cmdTag byte, cmdPayload []byte) (CommandResult, error) {
	result, _, err := c.SendCommandTimed(cmdTag, cmdPayload)
	return result, err
}

func (c *HivemindClient) SendCommandTimed(cmdTag byte, cmdPayload []byte) (CommandResult, CommandTimings, error) {
	slotStart := nowWallMS()
	c.commandSlots <- struct{}{}
	slotEnd := nowWallMS()
	defer func() { <-c.commandSlots }()

	timings := CommandTimings{}
	timings.SpansRaw = append(timings.SpansRaw, TimedSpan{Phase: "api_command_slot_wait", StartMS: slotStart, EndMS: slotEnd, Source: "api/client.go"})

	reqID := c.requestID.Add(1)
	timings.RequestID = reqID

	// Build payload: client_id(8) + request_id(8) + cmd_tag(1) + cmd_payload.
	// Each consensus command uses its own short-lived TCP connection and unique
	// client_id so concurrent request_id commit order cannot make older in-flight
	// requests look stale in the VRR client table.
	commandClientID := c.clientID ^ (reqID * 0x9E3779B97F4A7C15)
	payload := make([]byte, 8+8+1+len(cmdPayload))
	binary.LittleEndian.PutUint64(payload[0:8], commandClientID)
	binary.LittleEndian.PutUint64(payload[8:16], reqID)
	payload[16] = cmdTag
	copy(payload[17:], cmdPayload)

	connectStart := nowWallMS()
	conn, leader, err := c.dialLeader(&timings.SpansRaw)
	connectEnd := nowWallMS()
	timings.SpansRaw = append(timings.SpansRaw, TimedSpan{Phase: "command_connect", StartMS: connectStart, EndMS: connectEnd, Source: "api/client.go"})
	if err != nil {
		return CommandResult{}, timings, err
	}
	defer conn.Close()

	c.mu.Lock()
	c.leader = leader
	c.mu.Unlock()

	writeStart := nowWallMS()
	if err := writeFrameEncrypted(conn, TagRequest, payload, c.crypto); err != nil {
		return CommandResult{}, timings, fmt.Errorf("send failed: %w", err)
	}
	writeEnd := nowWallMS()
	timings.SpansRaw = append(timings.SpansRaw, TimedSpan{Phase: "wire_write", StartMS: writeStart, EndMS: writeEnd, Source: "api/client.go"})

	buf := make([]byte, 256)
	replyStart := nowWallMS()
	reply, err := readReplyEncrypted(conn, buf, c.crypto)
	replyEnd := nowWallMS()
	timings.SpansRaw = append(timings.SpansRaw, TimedSpan{Phase: "reply_wait", StartMS: replyStart, EndMS: replyEnd, Source: "api/client.go"})
	if err != nil {
		return CommandResult{}, timings, fmt.Errorf("recv failed: %w", err)
	}

	result, err := parseResult(reply, reqID)
	return result, timings, err
}

// RunStatus is the stable cross-language /run wire enum.
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

func (s RunStatus) String() string {
	switch s {
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

// MaxRunPayload is the shared run-request body bound (matches core request_queue.MAX_PAYLOAD).
const MaxRunPayload = 512

// MaxRunResponseBody matches the Rust worker and Zig gateway response bound.
const MaxRunResponseBody = 16*1024 - 9

// ErrRunOutcomeAmbiguous means the gateway attempted to write a run request but
// could not prove whether the worker executed it. Callers must not retry unless
// the workload operation is independently idempotent.
var ErrRunOutcomeAmbiguous = errors.New("run outcome ambiguous")

// ErrRunUnavailable means no request bytes were sent. Retrying is safe.
var ErrRunUnavailable = errors.New("run unavailable before send")

// RunResponse is the decoded worker reply to a /run request.
type RunResponse struct {
	RequestID uint64
	Status    RunStatus // ok or one explicit error outcome
	Body      []byte    // status==0: container response body; status!=0: error detail (may be empty)
}

// SendRunRequest sends a workload request (no consensus) and returns the
// decoded response. The caller is responsible for translating Status into an
// appropriate HTTP (or other) outcome; Body is the raw container payload with
// the wire header already stripped.
func (c *HivemindClient) SendRunRequest(depName string, payload []byte) (*RunResponse, error) {
	if len(depName) > 64 {
		return nil, fmt.Errorf("run deployment name exceeds wire maximum 64 bytes")
	}
	if strings.ContainsRune(depName, '\x00') {
		return nil, fmt.Errorf("run deployment name contains NUL")
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	if len(payload) > MaxRunPayload {
		return nil, fmt.Errorf("run payload exceeds max %d bytes", MaxRunPayload)
	}

	reqID := c.requestID.Add(1)

	// request_id(8) + dep_name(64) + payload_len(4) + payload
	data := make([]byte, 8+64+4+len(payload))
	binary.LittleEndian.PutUint64(data[0:8], reqID)
	copy(data[8:72], depName)
	binary.LittleEndian.PutUint32(data[72:76], uint32(len(payload)))
	copy(data[76:], payload)

	var connectErr error
	for attempt := 0; attempt < 2 && c.conn == nil; attempt++ {
		if err := c.reconnect(nil); err != nil {
			connectErr = err
		}
	}
	if c.conn == nil {
		if connectErr == nil {
			connectErr = errors.New("no leader connection")
		}
		return nil, fmt.Errorf("%w: %v", ErrRunUnavailable, connectErr)
	}

	// Calling writeFrameEncrypted may partially write before returning an error.
	// From this boundary onward, resending could execute the request twice.
	if err := writeFrameEncrypted(c.conn, TagRunRequest, data, c.crypto); err != nil {
		c.closeLocked()
		var writeErr *frameWriteError
		if errors.As(err, &writeErr) && writeErr.attempted {
			return nil, fmt.Errorf("%w: send failed: %w", ErrRunOutcomeAmbiguous, err)
		}
		return nil, fmt.Errorf("%w: send failed before write: %v", ErrRunUnavailable, err)
	}

	buf := make([]byte, 65536)
	raw, err := readRunResponseEncrypted(c.conn, buf, c.crypto)
	if err != nil {
		c.closeLocked()
		return nil, fmt.Errorf("%w: recv failed: %w", ErrRunOutcomeAmbiguous, err)
	}

	resp, err := parseRunResponse(raw)
	if err != nil {
		c.closeLocked()
		return nil, fmt.Errorf("%w: invalid response: %w", ErrRunOutcomeAmbiguous, err)
	}
	if resp.RequestID != reqID {
		c.closeLocked()
		return nil, fmt.Errorf("%w: run response request_id mismatch: got %d want %d", ErrRunOutcomeAmbiguous, resp.RequestID, reqID)
	}
	if resp.Status == RunStatusOutcomeAmbiguous {
		return resp, ErrRunOutcomeAmbiguous
	}
	return resp, nil
}

// parseRunResponse decodes a run_response payload: [request_id(8)][status(1)][len(4)?][data?].
// Gateway sendRunError replies are exactly 9 bytes (no length/body) and require nonzero status.
// All other replies require an exact length prefix: declared body length == trailing bytes.
func parseRunResponse(raw []byte) (*RunResponse, error) {
	if len(raw) < 9 {
		return nil, fmt.Errorf("run response too short: %d", len(raw))
	}
	resp := &RunResponse{
		RequestID: binary.LittleEndian.Uint64(raw[0:8]),
		Status:    RunStatus(raw[8]),
	}
	if resp.Status > RunStatusUnavailable {
		return nil, fmt.Errorf("unknown run status: %d", resp.Status)
	}
	if len(raw) == 9 {
		if resp.Status == RunStatusOK {
			return nil, fmt.Errorf("run response missing length")
		}
		return resp, nil
	}
	if len(raw) < 13 {
		return nil, fmt.Errorf("run response missing length")
	}
	bodyLen := binary.LittleEndian.Uint32(raw[9:13])
	// Overflow-safe exact equality: compare body slice length to declared length.
	body := raw[13:]
	if bodyLen > MaxRunResponseBody {
		return nil, fmt.Errorf("run response body exceeds max %d bytes", MaxRunResponseBody)
	}
	if uint64(len(body)) != uint64(bodyLen) {
		return nil, fmt.Errorf("run response length mismatch: declared %d have %d", bodyLen, len(body))
	}
	if bodyLen > 0 {
		// Copy out so the caller can outlive the shared read buffer.
		resp.Body = append([]byte(nil), body...)
	}
	return resp, nil
}

func (c *HivemindClient) IsConnected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.conn != nil
}

func (c *HivemindClient) Leader() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.leader
}

// Wire helpers

const ProtocolVersion uint16 = 1
const frameWriteTimeout = 2 * time.Second

type frameWriteError struct {
	attempted bool
	err       error
}

func (e *frameWriteError) Error() string { return e.err.Error() }
func (e *frameWriteError) Unwrap() error { return e.err }

func writeAll(conn net.Conn, data []byte) error {
	for len(data) > 0 {
		n, err := conn.Write(data)
		if n < 0 || n > len(data) {
			return &frameWriteError{attempted: true, err: fmt.Errorf("invalid write count %d for %d bytes", n, len(data))}
		}
		if n > 0 {
			data = data[n:]
		}
		if err != nil {
			return &frameWriteError{attempted: true, err: err}
		}
		if n == 0 {
			return &frameWriteError{attempted: true, err: io.ErrShortWrite}
		}
	}
	return nil
}

func writeFrame(conn net.Conn, tag byte, payload []byte) error {
	return writeFrameEncrypted(conn, tag, payload, nil)
}

func writeFrameEncrypted(conn net.Conn, tag byte, payload []byte, crypto *CryptoState) (err error) {
	if err := conn.SetWriteDeadline(time.Now().Add(frameWriteTimeout)); err != nil {
		return fmt.Errorf("set write deadline: %w", err)
	}
	attempted := false
	defer func() {
		if clearErr := conn.SetWriteDeadline(time.Time{}); clearErr != nil && err == nil {
			err = &frameWriteError{attempted: attempted, err: fmt.Errorf("clear write deadline: %w", clearErr)}
		}
	}()

	// Build inner: [version(2)][tag(1)][payload...]
	inner := make([]byte, 2+1+len(payload))
	binary.LittleEndian.PutUint16(inner[0:2], ProtocolVersion)
	inner[2] = tag
	copy(inner[3:], payload)

	if crypto != nil && crypto.Enabled {
		// Compute frame length: flags(1) + nonce(24) + ciphertext(=inner) + tag(16)
		encPayloadLen := CryptoNonceLen + len(inner) + CryptoTagLen
		frameLen := uint32(1 + encPayloadLen)
		header := make([]byte, 5)
		binary.LittleEndian.PutUint32(header[0:4], frameLen)
		header[4] = 0x01 // encrypted

		// AAD = header (len + flags) -- must match Zig decodeFrame
		encrypted, err := EncryptFrame(&crypto.ClientKey, inner, header)
		if err != nil {
			return err
		}

		attempted = true
		if err := writeAll(conn, header); err != nil {
			return err
		}
		return writeAll(conn, encrypted)
	}

	frameLen := uint32(1 + len(inner)) // flags + inner
	header := make([]byte, 5)
	binary.LittleEndian.PutUint32(header[0:4], frameLen)
	header[4] = 0x00 // plaintext

	attempted = true
	if err := writeAll(conn, header); err != nil {
		return err
	}
	return writeAll(conn, inner)
}

// probeIsLeader sends a read-only cluster_state_request and returns whether
// the peer self-identifies as the current VRR leader. No consensus, no state
// mutation, no client_table entry — safe to call on every reconnect.
func probeIsLeader(conn net.Conn, crypto *CryptoState) (bool, error) {
	if err := writeFrameEncrypted(conn, TagClusterStateRequest, []byte{0x01}, crypto); err != nil {
		return false, err
	}

	buf := make([]byte, 131072)
	frame, err := readFrameGeneric(conn, buf, 2*time.Second, crypto)
	if err != nil {
		return false, err
	}
	if len(frame) < 3 || frame[2] != TagClusterStateResponse {
		return false, fmt.Errorf("unexpected probe tag: 0x%02x", frame[2])
	}

	// payload layout: query_type(1) + view(8) + commit_min(8) + op(8) + status(1) + is_leader(1)
	payload := frame[3:]
	if len(payload) < 27 {
		return false, fmt.Errorf("probe reply too short: %d", len(payload))
	}
	return payload[26] == 1, nil
}

// readFrameGeneric reads exactly one frame and returns [version(2)][tag(1)][payload...].
func readFrameGeneric(conn net.Conn, buf []byte, timeout time.Duration, crypto *CryptoState) (frame []byte, err error) {
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

	if len(buf) < 4 {
		return nil, fmt.Errorf("frame buffer too small: %d", len(buf))
	}
	if _, err := readFull(conn, buf[:4]); err != nil {
		return nil, err
	}
	frameLen := binary.LittleEndian.Uint32(buf[:4])
	if frameLen < 1 || uint64(frameLen) > uint64(len(buf)-4) {
		return nil, fmt.Errorf("bad frame len: %d", frameLen)
	}

	if _, err := readFull(conn, buf[4:4+int(frameLen)]); err != nil {
		return nil, err
	}

	flags := buf[4]
	if flags != 0x00 && flags != 0x01 {
		return nil, fmt.Errorf("unknown frame flags: 0x%02x", flags)
	}
	keyConfigured := crypto != nil && crypto.Enabled
	if (flags == 0x01) != keyConfigured {
		if flags == 0x01 {
			return nil, fmt.Errorf("encrypted frame but no key")
		}
		return nil, fmt.Errorf("plaintext frame while key configured")
	}

	var plaintext []byte
	if flags == 0x01 {
		const encryptedMinimum = CryptoNonceLen + 3 + CryptoTagLen
		if frameLen < 1+encryptedMinimum {
			return nil, fmt.Errorf("encrypted frame too short: %d", frameLen)
		}
		encData := buf[5 : 4+int(frameLen)]
		aad := buf[0:5]
		var err error
		plaintext, err = DecryptFrame(&crypto.ClientKey, encData, aad)
		if err != nil {
			return nil, fmt.Errorf("decrypt failed: %w", err)
		}
	} else {
		if frameLen < 1+3 {
			return nil, fmt.Errorf("plaintext frame too short: %d", frameLen)
		}
		plaintext = buf[5 : 4+int(frameLen)]
	}

	if len(plaintext) < 3 {
		return nil, fmt.Errorf("frame payload too short: %d", len(plaintext))
	}
	version := binary.LittleEndian.Uint16(plaintext[:2])
	if version != ProtocolVersion {
		return nil, fmt.Errorf("unsupported protocol version: %d", version)
	}
	return plaintext, nil
}

func readReply(conn net.Conn, buf []byte) ([]byte, error) {
	return readReplyEncrypted(conn, buf, nil)
}

func readReplyEncrypted(conn net.Conn, buf []byte, crypto *CryptoState) ([]byte, error) {
	frame, err := readFrameGeneric(conn, buf, 5*time.Second, crypto)
	if err != nil {
		return nil, err
	}
	if len(frame) < 3 || frame[2] != TagReply {
		return nil, fmt.Errorf("unexpected tag: 0x%02x", frame[2])
	}
	return frame[3:], nil
}

func readRunResponse(conn net.Conn, buf []byte) ([]byte, error) {
	return readRunResponseEncrypted(conn, buf, nil)
}

func readRunResponseEncrypted(conn net.Conn, buf []byte, crypto *CryptoState) ([]byte, error) {
	frame, err := readFrameGeneric(conn, buf, 30*time.Second, crypto)
	if err != nil {
		return nil, err
	}
	if len(frame) < 3 || frame[2] != TagRunResponse {
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

func parseResult(reply []byte, expectedRequestID uint64) (CommandResult, error) {
	// reply: [8B request_id][1B result_type][...]
	if len(reply) < 9 {
		return CommandResult{}, fmt.Errorf("reply too short: %d bytes", len(reply))
	}
	replyRequestID := binary.LittleEndian.Uint64(reply[0:8])
	if replyRequestID != expectedRequestID {
		return CommandResult{}, fmt.Errorf("reply request_id mismatch: got %d want %d", replyRequestID, expectedRequestID)
	}

	resultType := reply[8]
	switch resultType {
	case 0: // ok
		if len(reply) != 17 {
			return CommandResult{}, fmt.Errorf("ok reply length %d, want 17", len(reply))
		}
		return CommandResult{OK: true, EntityID: binary.LittleEndian.Uint64(reply[9:17])}, nil
	case 1: // error
		if len(reply) != 10 {
			return CommandResult{}, fmt.Errorf("err reply length %d, want 10", len(reply))
		}
		return CommandResult{OK: false, ErrCode: reply[9]}, nil
	default:
		return CommandResult{}, fmt.Errorf("unknown result type: %d", resultType)
	}
}

// ---------------------------------------------------------------------------
// Cluster state query (read-only, no consensus)
// ---------------------------------------------------------------------------

type ClusterState struct {
	ViewNumber uint64
	CommitMin  uint64
	OpNumber   uint64
	Status     byte
	IsLeader   bool

	Nodes       []NodeInfo
	Deployments []DeploymentInfo
	Pods        []PodInfo
	Agents      []WorkerInfo

	QueueDepth    uint64
	InFlight      uint64
	EnqueueTotal  uint64
	DispatchTotal uint64
	ResolveTotal  uint64
}

type NodeInfo struct {
	ID             uint64
	Name           string
	Status         byte
	GpuType        byte
	GpuCount       byte
	AllocatableGpu byte
	CPU            uint32
	Memory         uint32
	Region         string
	Provider       string
}

type DeploymentInfo struct {
	ID            uint64
	Name          string
	Image         string
	Replicas      uint32
	ReadyReplicas uint32
	Paused        bool
	Version       uint32
	GpuType       byte
	GpuCount      byte
}

type PodInfo struct {
	ID           uint64
	DeploymentID uint64
	NodeID       uint64
	Phase        byte
}

type WorkerInfo struct {
	Hostname          string
	NodeID            uint64
	Connected         bool
	LastHeartbeatTick int64
	GpuType           byte
	GpuCount          byte
}

func (c *HivemindClient) SendClusterStateRequest() (*ClusterState, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		if c.conn == nil {
			if err := c.reconnect(nil); err != nil {
				lastErr = err
				continue
			}
		}

		// Send 0x24 with query_type=0x01 (full snapshot)
		if err := writeFrameEncrypted(c.conn, TagClusterStateRequest, []byte{0x01}, c.crypto); err != nil {
			lastErr = fmt.Errorf("send failed: %w", err)
			c.closeLocked()
			continue
		}

		// Read response frame
		buf := make([]byte, 131072)
		frame, err := readFrameGeneric(c.conn, buf, 5*time.Second, c.crypto)
		if err != nil {
			lastErr = fmt.Errorf("recv failed: %w", err)
			c.closeLocked()
			continue
		}
		if len(frame) < 3 || frame[2] != TagClusterStateResponse {
			lastErr = fmt.Errorf("unexpected tag")
			c.closeLocked()
			continue
		}

		return parseClusterState(frame[3:])
	}

	return nil, lastErr
}

func parseClusterState(data []byte) (*ClusterState, error) {
	const (
		headerSize     = 29
		nodeSize       = 148
		deploymentSize = 215
		podSize        = 25
		agentSize      = 83
		queueStatsSize = 40
		maxNodes       = 128
		maxDeployments = 64
		maxPods        = 512
		maxAgents      = 128
	)
	if len(data) < headerSize {
		return nil, fmt.Errorf("cluster state too short: %d", len(data))
	}

	cs := &ClusterState{}
	pos := 1
	cs.ViewNumber = binary.LittleEndian.Uint64(data[pos:])
	pos += 8
	cs.CommitMin = binary.LittleEndian.Uint64(data[pos:])
	pos += 8
	cs.OpNumber = binary.LittleEndian.Uint64(data[pos:])
	pos += 8
	cs.Status = data[pos]
	pos++
	cs.IsLeader = data[pos] == 1
	pos++

	readCount := func(kind string, max int, recordSize int) (int, error) {
		if pos+2 > len(data) {
			return 0, fmt.Errorf("cluster state truncated before %s count", kind)
		}
		count := int(binary.LittleEndian.Uint16(data[pos:]))
		pos += 2
		if count > max {
			return 0, fmt.Errorf("cluster state %s count %d exceeds max %d", kind, count, max)
		}
		if count > (len(data)-pos)/recordSize {
			return 0, fmt.Errorf("cluster state truncated %s records: count=%d remaining=%d", kind, count, len(data)-pos)
		}
		return count, nil
	}

	nodeCount, err := readCount("node", maxNodes, nodeSize)
	if err != nil {
		return nil, err
	}
	cs.Nodes = make([]NodeInfo, nodeCount)
	for i := range cs.Nodes {
		n := &cs.Nodes[i]
		n.ID = binary.LittleEndian.Uint64(data[pos:])
		pos += 8
		n.Name = trimNull(data[pos : pos+64])
		pos += 64
		n.Status = data[pos]
		pos++
		n.GpuType = data[pos]
		pos++
		n.GpuCount = data[pos]
		pos++
		n.AllocatableGpu = data[pos]
		pos++
		n.CPU = binary.LittleEndian.Uint32(data[pos:])
		pos += 4
		n.Memory = binary.LittleEndian.Uint32(data[pos:])
		pos += 4
		n.Region = trimNull(data[pos : pos+32])
		pos += 32
		n.Provider = trimNull(data[pos : pos+32])
		pos += 32
	}

	deploymentCount, err := readCount("deployment", maxDeployments, deploymentSize)
	if err != nil {
		return nil, err
	}
	cs.Deployments = make([]DeploymentInfo, deploymentCount)
	for i := range cs.Deployments {
		d := &cs.Deployments[i]
		d.ID = binary.LittleEndian.Uint64(data[pos:])
		pos += 8
		d.Name = trimNull(data[pos : pos+64])
		pos += 64
		d.Image = trimNull(data[pos : pos+128])
		pos += 128
		d.Replicas = binary.LittleEndian.Uint32(data[pos:])
		pos += 4
		d.ReadyReplicas = binary.LittleEndian.Uint32(data[pos:])
		pos += 4
		d.Paused = data[pos] == 1
		pos++
		d.Version = binary.LittleEndian.Uint32(data[pos:])
		pos += 4
		d.GpuType = data[pos]
		pos++
		d.GpuCount = data[pos]
		pos++
	}

	podCount, err := readCount("pod", maxPods, podSize)
	if err != nil {
		return nil, err
	}
	cs.Pods = make([]PodInfo, podCount)
	for i := range cs.Pods {
		p := &cs.Pods[i]
		p.ID = binary.LittleEndian.Uint64(data[pos:])
		pos += 8
		p.DeploymentID = binary.LittleEndian.Uint64(data[pos:])
		pos += 8
		p.NodeID = binary.LittleEndian.Uint64(data[pos:])
		pos += 8
		p.Phase = data[pos]
		pos++
	}

	agentCount, err := readCount("agent", maxAgents, agentSize)
	if err != nil {
		return nil, err
	}
	cs.Agents = make([]WorkerInfo, agentCount)
	for i := range cs.Agents {
		a := &cs.Agents[i]
		a.Hostname = trimNull(data[pos : pos+64])
		pos += 64
		a.NodeID = binary.LittleEndian.Uint64(data[pos:])
		pos += 8
		a.Connected = data[pos] == 1
		pos++
		a.LastHeartbeatTick = int64(binary.LittleEndian.Uint64(data[pos:]))
		pos += 8
		a.GpuType = data[pos]
		pos++
		a.GpuCount = data[pos]
		pos++
	}

	if len(data)-pos != queueStatsSize {
		return nil, fmt.Errorf("cluster state queue stats length %d, want %d", len(data)-pos, queueStatsSize)
	}
	cs.QueueDepth = binary.LittleEndian.Uint64(data[pos:])
	pos += 8
	cs.InFlight = binary.LittleEndian.Uint64(data[pos:])
	pos += 8
	cs.EnqueueTotal = binary.LittleEndian.Uint64(data[pos:])
	pos += 8
	cs.DispatchTotal = binary.LittleEndian.Uint64(data[pos:])
	pos += 8
	cs.ResolveTotal = binary.LittleEndian.Uint64(data[pos:])
	pos += 8
	if pos != len(data) {
		panic("cluster state parser length invariant")
	}
	return cs, nil
}

func trimNull(b []byte) string {
	for i, c := range b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}

type deadlineTrackingConn struct {
	readBuf           *bytes.Reader
	writeBuf          bytes.Buffer
	lastReadDeadline  time.Time
	lastWriteDeadline time.Time
}

func (c *deadlineTrackingConn) Read(p []byte) (int, error)  { return c.readBuf.Read(p) }
func (c *deadlineTrackingConn) Write(p []byte) (int, error) { return c.writeBuf.Write(p) }
func (c *deadlineTrackingConn) Close() error                { return nil }
func (c *deadlineTrackingConn) LocalAddr() net.Addr         { return dummyAddr("local") }
func (c *deadlineTrackingConn) RemoteAddr() net.Addr        { return dummyAddr("remote") }
func (c *deadlineTrackingConn) SetDeadline(t time.Time) error {
	c.lastReadDeadline = t
	c.lastWriteDeadline = t
	return nil
}
func (c *deadlineTrackingConn) SetReadDeadline(t time.Time) error {
	c.lastReadDeadline = t
	return nil
}
func (c *deadlineTrackingConn) SetWriteDeadline(t time.Time) error {
	c.lastWriteDeadline = t
	return nil
}

type dummyAddr string

func (a dummyAddr) Network() string { return "tcp" }
func (a dummyAddr) String() string  { return string(a) }
