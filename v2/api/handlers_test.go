package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRunStatusesMapToStableMachineReadableErrors(t *testing.T) {
	cases := []struct {
		status     RunStatus
		wantHTTP   int
		wantReason string
	}{
		{status: RunStatusDeploymentNotFound, wantHTTP: http.StatusNotFound, wantReason: "deployment_not_found"},
		{status: RunStatusQueueFull, wantHTTP: http.StatusServiceUnavailable, wantReason: "queue_full"},
		{status: RunStatusInvalidPayload, wantHTTP: http.StatusBadRequest, wantReason: "invalid_payload"},
		{status: RunStatusResponseTooLarge, wantHTTP: http.StatusBadGateway, wantReason: "response_too_large"},
		{status: RunStatusOutcomeAmbiguous, wantHTTP: http.StatusBadGateway, wantReason: "outcome_ambiguous"},
		{status: RunStatusForwardingFailed, wantHTTP: http.StatusBadGateway, wantReason: "forwarding_failed"},
		{status: RunStatusNoRunningPod, wantHTTP: http.StatusServiceUnavailable, wantReason: "no_running_pod"},
		{status: RunStatusUnavailable, wantHTTP: http.StatusServiceUnavailable, wantReason: "unavailable"},
	}
	for _, tc := range cases {
		status, reason := runStatusToHTTP(tc.status)
		if status != tc.wantHTTP || reason != tc.wantReason {
			t.Fatalf("status %d mapping = (%d, %q), want (%d, %q)", tc.status, status, reason, tc.wantHTTP, tc.wantReason)
		}
	}
}

func TestRunHandlerReturnsStableAmbiguousAndUnavailableErrors(t *testing.T) {
	cases := []struct {
		name       string
		client     *HivemindClient
		wantHTTP   int
		wantError  string
		wantStatus RunStatus
	}{
		{
			name: "ambiguous after write attempt",
			client: func() *HivemindClient {
				client := NewClient(nil, nil)
				client.conn = &failingWriteConn{}
				return client
			}(),
			wantHTTP: http.StatusBadGateway, wantError: "outcome_ambiguous", wantStatus: RunStatusOutcomeAmbiguous,
		},
		{
			name:     "unavailable before send",
			client:   NewClient(nil, nil),
			wantHTTP: http.StatusServiceUnavailable, wantError: "unavailable", wantStatus: RunStatusUnavailable,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			mux := http.NewServeMux()
			mux.HandleFunc("POST /v1/deployments/{name}/run", handleRunRequest(tc.client))
			req := httptest.NewRequest(http.MethodPost, "/v1/deployments/echo/run", strings.NewReader("request"))
			rr := httptest.NewRecorder()
			mux.ServeHTTP(rr, req)
			if rr.Code != tc.wantHTTP {
				t.Fatalf("status = %d, want %d: %s", rr.Code, tc.wantHTTP, rr.Body.String())
			}
			var body map[string]any
			if err := json.NewDecoder(rr.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if body["error"] != tc.wantError {
				t.Fatalf("error = %v, want %q", body["error"], tc.wantError)
			}
			if body["status"] != float64(tc.wantStatus) {
				t.Fatalf("status body = %v, want %d", body["status"], tc.wantStatus)
			}
		})
	}
}

func TestWriteResultLogFullMapsTo507(t *testing.T) {
	rr := httptest.NewRecorder()
	writeResult(rr, CommandResult{OK: false, ErrCode: ErrCodeLogFull}, nil)

	if rr.Code != http.StatusInsufficientStorage {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusInsufficientStorage)
	}

	var body map[string]any
	if err := json.NewDecoder(rr.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body["error"] != "log_full" {
		t.Fatalf("error = %v, want log_full", body["error"])
	}
	if code, ok := body["code"].(float64); !ok || byte(code) != ErrCodeLogFull {
		t.Fatalf("code = %v, want %d", body["code"], ErrCodeLogFull)
	}
}
