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

func TestMutationEndpointsRejectUnboundedAndAmbiguousJSON(t *testing.T) {
	client := NewClient(nil, nil)
	latency := &LatencyRecorder{}
	cases := []struct {
		name, method, path, minimal, oversized string
		limit                                  int
		handler                                http.HandlerFunc
	}{
		{"create", http.MethodPost, "/v1/deployments", `{"name":"n","image":"i"}`, `{"name":"` + strings.Repeat("n", 65) + `","image":"i"}`, createDeploymentJSONMax, handleCreateDeployment(client, latency)},
		{"update", http.MethodPut, "/v1/deployments/1", `{"image":"i"}`, `{"image":"` + strings.Repeat("i", 257) + `"}`, updateDeploymentJSONMax, handleUpdateDeployment(client)},
		{"scale", http.MethodPut, "/v1/deployments/1/scale", `{"replicas":1}`, strings.Repeat(" ", scaleDeploymentJSONMax+1), scaleDeploymentJSONMax, handleScaleDeployment(client, latency)},
		{"traffic", http.MethodPut, "/v1/deployments/1/traffic", `{"rules":[]}`, `{"rules":[{},{},{},{},{}]}`, trafficSplitJSONMax, handleSetTrafficSplit(client)},
	}
	for _, tc := range cases {
		t.Run(tc.name+" second value", func(t *testing.T) {
			r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.minimal+` {}`))
			r.SetPathValue("id", "1")
			w := httptest.NewRecorder()
			tc.handler(w, r)
			if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "multiple JSON values") {
				t.Fatalf("status/body = %d %s", w.Code, w.Body.String())
			}
		})
		t.Run(tc.name+" exact bound", func(t *testing.T) {
			body := tc.minimal + strings.Repeat(" ", tc.limit-len(tc.minimal))
			r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(body))
			r.SetPathValue("id", "1")
			w := httptest.NewRecorder()
			tc.handler(w, r)
			if w.Code == http.StatusRequestEntityTooLarge || w.Code == http.StatusBadRequest {
				t.Fatalf("exact-bound body rejected: %d %s", w.Code, w.Body.String())
			}
		})
		t.Run(tc.name+" oversized domain", func(t *testing.T) {
			r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.oversized))
			r.SetPathValue("id", "1")
			w := httptest.NewRecorder()
			tc.handler(w, r)
			if w.Code != http.StatusBadRequest && w.Code != http.StatusRequestEntityTooLarge {
				t.Fatalf("oversized domain accepted: %d %s", w.Code, w.Body.String())
			}
		})
		t.Run(tc.name+" over body limit", func(t *testing.T) {
			body := tc.minimal + strings.Repeat(" ", tc.limit-len(tc.minimal)+1)
			r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(body))
			r.SetPathValue("id", "1")
			w := httptest.NewRecorder()
			tc.handler(w, r)
			if w.Code != http.StatusRequestEntityTooLarge {
				t.Fatalf("status = %d, want 413: %s", w.Code, w.Body.String())
			}
		})
	}
}

func TestDecodeBoundedJSONRejectsMalformedTrailingData(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{} garbage`))
	w := httptest.NewRecorder()
	var value map[string]any
	if decodeBoundedJSON(w, r, &value, 64) {
		t.Fatal("malformed trailing data accepted")
	}
	if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "trailing data") {
		t.Fatalf("status/body = %d %s", w.Code, w.Body.String())
	}
}
