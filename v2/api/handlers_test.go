package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRunStatusResponseTooLargeMapsExplicitly(t *testing.T) {
	status, reason := runStatusToHTTP(RunStatusResponseTooLarge)
	if status != http.StatusBadGateway || reason != "response_too_large" {
		t.Fatalf("mapping = (%d, %q), want (%d, %q)", status, reason, http.StatusBadGateway, "response_too_large")
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
