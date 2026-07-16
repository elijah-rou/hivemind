package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
)

func writeFixedStr(dst []byte, s string) {
	n := copy(dst, s)
	if n < len(dst) {
		for i := n; i < len(dst); i++ {
			dst[i] = 0
		}
	}
}

func registerRoutes(mux *http.ServeMux, client *HivemindClient, latency *LatencyRecorder) {
	mux.HandleFunc("GET /v1/health", handleHealth(client))
	mux.HandleFunc("POST /v1/deployments", handleCreateDeployment(client, latency))
	mux.HandleFunc("POST /v1/deployments/{name}/run", handleRunRequest(client))
	mux.HandleFunc("DELETE /v1/deployments/{id}", handleDeleteDeployment(client, latency))
	mux.HandleFunc("PUT /v1/deployments/{id}", handleUpdateDeployment(client))
	mux.HandleFunc("PUT /v1/deployments/{id}/scale", handleScaleDeployment(client, latency))
	mux.HandleFunc("PUT /v1/deployments/{id}/pause", handlePauseDeployment(client))
	mux.HandleFunc("PUT /v1/deployments/{id}/resume", handleResumeDeployment(client))
	mux.HandleFunc("PUT /v1/deployments/{id}/rollback", handleRollbackDeployment(client))
	mux.HandleFunc("PUT /v1/deployments/{id}/traffic", handleSetTrafficSplit(client))
}

// GET /v1/health
func handleHealth(client *HivemindClient) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := client.Refresh(); err != nil {
			log.Printf("health refresh failed: %v", err)
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"connected": client.IsConnected(),
			"leader":    client.Leader(),
		})
	}
}

// POST /v1/deployments
func handleCreateDeployment(client *HivemindClient, latency *LatencyRecorder) http.HandlerFunc {
	type request struct {
		Name     string `json:"name"`
		Image    string `json:"image"`
		Replicas uint32 `json:"replicas"`
		CPU      uint32 `json:"cpu"`
		Memory   uint32 `json:"memory"`
		GpuType  string `json:"gpu_type"`
		GpuCount uint8  `json:"gpu_count"`

		ImagePullRegistry       string `json:"image_pull_registry"`
		ImagePullUsername       string `json:"image_pull_username"`
		ImagePullPassword       string `json:"image_pull_password"`
		ImagePullPasswordSecret bool   `json:"image_pull_password_is_secret"`
	}

	return func(w http.ResponseWriter, r *http.Request) {
		handlerStart := nowWallMS()
		var req request
		decodeStart := nowWallMS()
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid json: "+err.Error())
			return
		}
		decodeEnd := nowWallMS()
		traceContext := latencyContextFromRequest(r)
		latency.Span(LatencySpan{Scenario: traceContext.scenario, Entity: traceContext.entity, Name: req.Name, Op: "create_deployment", Phase: "api_handler_decode", StartMS: decodeStart, EndMS: decodeEnd, Count: 1, Source: "api/handlers.go"})

		if req.Name == "" {
			writeErr(w, http.StatusBadRequest, "name is required")
			return
		}
		if req.Image == "" {
			writeErr(w, http.StatusBadRequest, "image is required")
			return
		}
		if req.Replicas == 0 {
			req.Replicas = 1
		}

		gpuByte := gpuTypeMap[req.GpuType] // defaults to 0 (none) if unset

		// Wire: name(64) + namespace(64) + image(256) + replicas(4) + cpu(4) + mem(4) + gpu_type(1) + gpu_count(1)
		// Optional image pull extension: registry(128) + username(64) + password(256) + password_is_secret(1)
		const baseSize = 64 + 64 + 256 + 4 + 4 + 4 + 1 + 1
		const pullExtSize = 128 + 64 + 256 + 1
		hasPullAuth := strings.TrimSpace(req.ImagePullRegistry) != "" ||
			strings.TrimSpace(req.ImagePullUsername) != "" ||
			strings.TrimSpace(req.ImagePullPassword) != ""

		total := baseSize
		if hasPullAuth {
			total += pullExtSize
		}

		buildStart := nowWallMS()
		payload := make([]byte, total)
		off := 0
		writeFixedStr(payload[off:off+64], req.Name)
		off += 64
		// namespace: leave zero (default)
		off += 64
		writeFixedStr(payload[off:off+256], req.Image)
		off += 256
		binary.LittleEndian.PutUint32(payload[off:off+4], req.Replicas)
		off += 4
		binary.LittleEndian.PutUint32(payload[off:off+4], req.CPU)
		off += 4
		binary.LittleEndian.PutUint32(payload[off:off+4], req.Memory)
		off += 4
		payload[off] = gpuByte
		off++
		payload[off] = req.GpuCount
		off++

		if hasPullAuth {
			writeFixedStr(payload[off:off+128], req.ImagePullRegistry)
			off += 128
			writeFixedStr(payload[off:off+64], req.ImagePullUsername)
			off += 64
			writeFixedStr(payload[off:off+256], req.ImagePullPassword)
			off += 256
			if req.ImagePullPasswordSecret {
				payload[off] = 1
			} else {
				payload[off] = 0
			}
		}
		buildEnd := nowWallMS()
		latency.Span(LatencySpan{Scenario: traceContext.scenario, Entity: traceContext.entity, Name: req.Name, Op: "create_deployment", Phase: "api_handler_build", StartMS: buildStart, EndMS: buildEnd, Count: 1, Source: "api/handlers.go"})

		result, timings, err := client.SendCommandTimed(CmdCreateDeployment, payload)
		for _, span := range timings.Spans("create_deployment", traceContext.scenario, traceContext.entity, req.Name, 0, 0) {
			latency.Span(span)
		}
		if err != nil {
			writeErr(w, http.StatusBadGateway, err.Error())
			return
		}

		deploymentID := result.EntityID
		latency.Span(LatencySpan{Scenario: traceContext.scenario, Entity: traceContext.entity, DeploymentID: deploymentID, Name: req.Name, Op: "create_deployment", Phase: "http_client_submit", StartMS: handlerStart, EndMS: nowWallMS(), Count: 1, Source: "api/handlers.go"})

		writeResult(w, result, map[string]any{
			"id":   deploymentID,
			"name": req.Name,
		})
	}
}

// POST /v1/deployments/:name/run
func handleRunRequest(client *HivemindClient) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if name == "" {
			writeErr(w, http.StatusBadRequest, "deployment name is required")
			return
		}

		body, err := io.ReadAll(io.LimitReader(r.Body, int64(MaxRunPayload)+1))
		if err != nil {
			writeErr(w, http.StatusBadRequest, "failed to read body: "+err.Error())
			return
		}
		if len(body) > MaxRunPayload {
			writeErr(w, http.StatusBadRequest, fmt.Sprintf("run payload exceeds max %d bytes", MaxRunPayload))
			return
		}

		resp, err := client.SendRunRequest(name, body)
		if err != nil {
			writeErr(w, http.StatusBadGateway, err.Error())
			return
		}

		if resp.Status != RunStatusOK {
			status, reason := runStatusToHTTP(resp.Status)
			body := map[string]any{
				"error":  reason,
				"status": resp.Status,
			}
			if len(resp.Body) > 0 {
				body["detail"] = string(resp.Body)
			}
			writeJSON(w, status, body)
			return
		}

		// Forward raw response body from the container. Wire metadata
		// (request_id, status, length) is stripped by parseRunResponse.
		w.Header().Set("Content-Type", "application/octet-stream")
		w.WriteHeader(http.StatusOK)
		w.Write(resp.Body)
	}
}

// runStatusToHTTP maps a nonzero run-request status to an HTTP status + reason.
// Values 1-2 come from the gateway (v2/src/connection.zig), everything else
// comes from the worker runtime.
func runStatusToHTTP(status byte) (int, string) {
	switch status {
	case RunStatusNotFound:
		return http.StatusNotFound, "deployment_not_found"
	case RunStatusQueueFull:
		return http.StatusServiceUnavailable, "queue_full"
	case RunStatusInvalidPayload:
		return http.StatusBadRequest, "invalid_payload"
	default:
		return http.StatusBadGateway, "worker_error"
	}
}

// DELETE /v1/deployments/:id
func handleDeleteDeployment(client *HivemindClient, latency *LatencyRecorder) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		depID, err := parseDeploymentID(r)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}

		payload := make([]byte, 8)
		binary.LittleEndian.PutUint64(payload[0:8], depID)

		traceContext := latencyContextFromRequest(r)
		result, timings, err := client.SendCommandTimed(CmdDeleteDeployment, payload)
		for _, span := range timings.Spans("delete_deployment", traceContext.scenario, traceContext.entity, "", depID, 0) {
			latency.Span(span)
		}
		if err != nil {
			writeErr(w, http.StatusBadGateway, err.Error())
			return
		}

		writeResult(w, result, map[string]any{"ok": true})
	}
}

// PUT /v1/deployments/:id
func handleUpdateDeployment(client *HivemindClient) http.HandlerFunc {
	type request struct {
		Image    string `json:"image"`
		CPU      uint32 `json:"cpu"`
		Memory   uint32 `json:"memory"`
		GpuType  string `json:"gpu_type"`
		GpuCount uint8  `json:"gpu_count"`
	}

	return func(w http.ResponseWriter, r *http.Request) {
		depID, err := parseDeploymentID(r)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}

		var req request
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid json: "+err.Error())
			return
		}
		if req.Image == "" {
			writeErr(w, http.StatusBadRequest, "image is required")
			return
		}

		// Wire: dep_id(8) + image(256) + entrypoint(256) + port(2) + cpu(4) + mem(4) + gpu_type(1) + gpu_count(1)
		const payloadSize = 8 + 256 + 256 + 2 + 4 + 4 + 1 + 1
		payload := make([]byte, payloadSize)
		off := 0
		binary.LittleEndian.PutUint64(payload[off:off+8], depID)
		off += 8
		writeFixedStr(payload[off:off+256], req.Image)
		off += 256
		// entrypoint: leave zero to use image default
		off += 256
		// port: leave zero to keep current deployment port
		off += 2
		binary.LittleEndian.PutUint32(payload[off:off+4], req.CPU)
		off += 4
		binary.LittleEndian.PutUint32(payload[off:off+4], req.Memory)
		off += 4
		payload[off] = gpuTypeMap[req.GpuType]
		off++
		payload[off] = req.GpuCount

		result, err := client.SendCommand(CmdUpdateDeployment, payload)
		if err != nil {
			writeErr(w, http.StatusBadGateway, err.Error())
			return
		}

		writeResult(w, result, map[string]any{"ok": true})
	}
}

// PUT /v1/deployments/:id/scale
func handleScaleDeployment(client *HivemindClient, latency *LatencyRecorder) http.HandlerFunc {
	type request struct {
		Replicas uint32 `json:"replicas"`
	}

	return func(w http.ResponseWriter, r *http.Request) {
		handlerStart := nowWallMS()
		depID, err := parseDeploymentID(r)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}

		var req request
		decodeStart := nowWallMS()
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid json: "+err.Error())
			return
		}
		decodeEnd := nowWallMS()
		traceContext := latencyContextFromRequest(r)
		latency.Span(LatencySpan{Scenario: traceContext.scenario, Entity: traceContext.entity, DeploymentID: depID, Op: "scale_deployment", Phase: "api_handler_decode", StartMS: decodeStart, EndMS: decodeEnd, Count: int64(req.Replicas), Source: "api/handlers.go"})

		buildStart := nowWallMS()
		payload := make([]byte, 12)
		binary.LittleEndian.PutUint64(payload[0:8], depID)
		binary.LittleEndian.PutUint32(payload[8:12], req.Replicas)
		buildEnd := nowWallMS()
		latency.Span(LatencySpan{Scenario: traceContext.scenario, Entity: traceContext.entity, DeploymentID: depID, Op: "scale_deployment", Phase: "api_handler_build", StartMS: buildStart, EndMS: buildEnd, Count: int64(req.Replicas), Source: "api/handlers.go"})

		result, timings, err := client.SendCommandTimed(CmdScaleDeployment, payload)
		for _, span := range timings.Spans("scale_deployment", traceContext.scenario, traceContext.entity, "", depID, 0) {
			latency.Span(span)
		}
		if err != nil {
			writeErr(w, http.StatusBadGateway, err.Error())
			return
		}
		latency.Span(LatencySpan{Scenario: traceContext.scenario, Entity: traceContext.entity, DeploymentID: depID, Op: "scale_deployment", Phase: "http_client_submit", StartMS: handlerStart, EndMS: nowWallMS(), Count: int64(req.Replicas), Source: "api/handlers.go"})

		writeResult(w, result, map[string]any{"ok": true})
	}
}

// PUT /v1/deployments/:id/pause
func handlePauseDeployment(client *HivemindClient) http.HandlerFunc {
	return simpleDeploymentCommand(client, CmdPauseDeployment)
}

// PUT /v1/deployments/:id/resume
func handleResumeDeployment(client *HivemindClient) http.HandlerFunc {
	return simpleDeploymentCommand(client, CmdResumeDeployment)
}

// PUT /v1/deployments/:id/rollback
func handleRollbackDeployment(client *HivemindClient) http.HandlerFunc {
	return simpleDeploymentCommand(client, CmdRollbackDeploy)
}

// PUT /v1/deployments/:id/traffic
func handleSetTrafficSplit(client *HivemindClient) http.HandlerFunc {
	type trafficRule struct {
		Version uint32 `json:"version"`
		Weight  uint8  `json:"weight"`
	}
	type request struct {
		Rules []trafficRule `json:"rules"`
	}

	return func(w http.ResponseWriter, r *http.Request) {
		depID, err := parseDeploymentID(r)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}

		var req request
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid json: "+err.Error())
			return
		}

		if len(req.Rules) > 4 {
			writeErr(w, http.StatusBadRequest, "max 4 traffic rules")
			return
		}

		// Wire: dep_id(8) + rules(4 * 5B) + rule_count(1) = 29B
		payload := make([]byte, 29)
		binary.LittleEndian.PutUint64(payload[0:8], depID)
		off := 8
		for i := 0; i < 4; i++ {
			if i < len(req.Rules) {
				binary.LittleEndian.PutUint32(payload[off:off+4], req.Rules[i].Version)
				payload[off+4] = req.Rules[i].Weight
			}
			off += 5
		}
		payload[28] = byte(len(req.Rules))

		result, err := client.SendCommand(CmdSetTrafficSplit, payload)
		if err != nil {
			writeErr(w, http.StatusBadGateway, err.Error())
			return
		}

		writeResult(w, result, map[string]any{"ok": true})
	}
}

// Shared handler for commands that only take a deployment ID
func simpleDeploymentCommand(client *HivemindClient, cmdTag byte) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		depID, err := parseDeploymentID(r)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}

		payload := make([]byte, 8)
		binary.LittleEndian.PutUint64(payload[0:8], depID)

		result, err := client.SendCommand(cmdTag, payload)
		if err != nil {
			writeErr(w, http.StatusBadGateway, err.Error())
			return
		}

		writeResult(w, result, map[string]any{"ok": true})
	}
}

// Helpers

type latencyContext struct {
	scenario string
	entity   string
}

func latencyContextFromRequest(r *http.Request) latencyContext {
	ctx := latencyContext{
		scenario: strings.TrimSpace(r.Header.Get("X-Hivemind-Scenario")),
		entity:   strings.TrimSpace(r.Header.Get("X-Hivemind-Entity")),
	}
	if ctx.entity == "" {
		ctx.entity = r.PathValue("name")
	}
	if ctx.entity == "" {
		ctx.entity = r.PathValue("id")
	}
	return ctx
}

func parseDeploymentID(r *http.Request) (uint64, error) {
	idStr := r.PathValue("id")
	if idStr == "" {
		return 0, fmt.Errorf("deployment id is required")
	}
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid deployment id: %s", idStr)
	}
	return id, nil
}

var errorCodeNames = map[byte]string{
	ErrCodeNotFound:          "not_found",
	ErrCodeAlreadyExists:     "already_exists",
	ErrCodeCapacityExceeded:  "capacity_exceeded",
	ErrCodeInvalidTransition: "invalid_transition",
	ErrCodeNotLeader:         "not_leader",
	ErrCodeLogFull:           "log_full",
}

var errorCodeHTTPStatus = map[byte]int{
	ErrCodeNotFound:          http.StatusNotFound,
	ErrCodeAlreadyExists:     http.StatusConflict,
	ErrCodeCapacityExceeded:  http.StatusServiceUnavailable,
	ErrCodeInvalidTransition: http.StatusConflict,
	ErrCodeNotLeader:         http.StatusServiceUnavailable,
	ErrCodeLogFull:           http.StatusInsufficientStorage,
}

func writeResult(w http.ResponseWriter, result CommandResult, successBody map[string]any) {
	if result.OK {
		writeJSON(w, http.StatusOK, successBody)
		return
	}

	name := errorCodeNames[result.ErrCode]
	if name == "" {
		name = fmt.Sprintf("error_%d", result.ErrCode)
	}
	status := errorCodeHTTPStatus[result.ErrCode]
	if status == 0 {
		status = http.StatusInternalServerError
	}

	writeJSON(w, status, map[string]any{
		"error": name,
		"code":  result.ErrCode,
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("json encode failed: %v", err)
	}
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"error": msg})
}

// loggingMiddleware wraps an http.Handler with request logging.
func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method := r.Method
		path := r.URL.Path
		log.Printf("%s %s", method, path)
		next.ServeHTTP(w, r)
	})
}

// stripTrailingSlash removes trailing slashes from the URL path for consistent routing.
func stripTrailingSlash(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" && strings.HasSuffix(r.URL.Path, "/") {
			r.URL.Path = strings.TrimRight(r.URL.Path, "/")
		}
		next.ServeHTTP(w, r)
	})
}
