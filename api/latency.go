package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const latencyCSVHeader = "system,component,run_id,scenario,entity,deployment_id,pod_id,name,op,phase,start_ms,end_ms,duration_ms,count,source\n"

type LatencySpan struct {
	System       string `json:"system"`
	Component    string `json:"component"`
	RunID        string `json:"run_id"`
	Scenario     string `json:"scenario"`
	Entity       string `json:"entity"`
	DeploymentID uint64 `json:"deployment_id"`
	PodID        uint64 `json:"pod_id"`
	Name         string `json:"name"`
	Op           string `json:"op"`
	Phase        string `json:"phase"`
	StartMS      int64  `json:"start_ms"`
	EndMS        int64  `json:"end_ms"`
	DurationMS   int64  `json:"duration_ms"`
	Count        int64  `json:"count"`
	Source       string `json:"source"`
}

type LatencyRecorder struct {
	enabled bool
	runID   string

	mu       sync.Mutex
	csvFile  *os.File
	jsonFile *os.File
}

func NewLatencyRecorderFromEnv() *LatencyRecorder {
	enabled := parseBoolEnv(os.Getenv("HIVEMIND_LATENCY_TRACE"))
	outDir := strings.TrimSpace(os.Getenv("HIVEMIND_LATENCY_OUT_DIR"))
	if outDir == "" {
		outDir = strings.TrimSpace(os.Getenv("OUT_DIR"))
	}
	runID := strings.TrimSpace(os.Getenv("HIVEMIND_LATENCY_RUN_ID"))
	if runID == "" {
		runID = strings.TrimSpace(os.Getenv("RUN_ID"))
	}
	if runID == "" {
		runID = fmt.Sprintf("%d", time.Now().Unix())
	}

	recorder := &LatencyRecorder{enabled: enabled, runID: runID}
	if !enabled || outDir == "" {
		return recorder
	}

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		log.Printf("latency trace disabled: mkdir %s: %v", outDir, err)
		recorder.enabled = false
		return recorder
	}

	csvPath := filepath.Join(outDir, "api-latency-events.csv")
	csvFile, err := os.Create(csvPath)
	if err != nil {
		log.Printf("latency trace disabled: create %s: %v", csvPath, err)
		recorder.enabled = false
		return recorder
	}
	if _, err := csvFile.WriteString(latencyCSVHeader); err != nil {
		log.Printf("latency trace disabled: write header %s: %v", csvPath, err)
		_ = csvFile.Close()
		recorder.enabled = false
		return recorder
	}
	recorder.csvFile = csvFile

	jsonPath := filepath.Join(outDir, "api-latency-events.jsonl")
	jsonFile, err := os.Create(jsonPath)
	if err != nil {
		log.Printf("latency trace json disabled: create %s: %v", jsonPath, err)
	} else {
		recorder.jsonFile = jsonFile
	}

	return recorder
}

func (r *LatencyRecorder) Close() {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.csvFile != nil {
		_ = r.csvFile.Close()
		r.csvFile = nil
	}
	if r.jsonFile != nil {
		_ = r.jsonFile.Close()
		r.jsonFile = nil
	}
}

func (r *LatencyRecorder) Enabled() bool {
	return r != nil && r.enabled
}

func (r *LatencyRecorder) Span(span LatencySpan) {
	if !r.Enabled() {
		return
	}
	if span.System == "" {
		span.System = "hivemind"
	}
	if span.Component == "" {
		span.Component = "api"
	}
	if span.RunID == "" {
		span.RunID = r.runID
	}
	if span.EndMS == 0 {
		span.EndMS = nowWallMS()
	}
	if span.StartMS == 0 {
		span.StartMS = span.EndMS
	}
	if span.EndMS < span.StartMS {
		span.EndMS = span.StartMS
	}
	span.DurationMS = span.EndMS - span.StartMS

	r.mu.Lock()
	defer r.mu.Unlock()
	if r.csvFile != nil {
		_, _ = r.csvFile.WriteString(formatLatencyCSV(span))
	}
	if r.jsonFile != nil {
		b, err := json.Marshal(span)
		if err == nil {
			_, _ = r.jsonFile.Write(append(b, '\n'))
		}
	} else {
		log.Printf("hivemind_latency_span system=%s component=%s run_id=%s scenario=%s entity=%s deployment_id=%d pod_id=%d name=%s op=%s phase=%s start_ms=%d end_ms=%d duration_ms=%d count=%d source=%s",
			span.System, span.Component, span.RunID, span.Scenario, span.Entity, span.DeploymentID, span.PodID, safeLogValue(span.Name), span.Op, span.Phase, span.StartMS, span.EndMS, span.DurationMS, span.Count, span.Source)
	}
}

func nowWallMS() int64 {
	return time.Now().UnixMilli()
}

func parseBoolEnv(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func formatLatencyCSV(span LatencySpan) string {
	return fmt.Sprintf("%s,%s,%s,%s,%s,%d,%d,%s,%s,%s,%d,%d,%d,%d,%s\n",
		csvEscape(span.System),
		csvEscape(span.Component),
		csvEscape(span.RunID),
		csvEscape(span.Scenario),
		csvEscape(span.Entity),
		span.DeploymentID,
		span.PodID,
		csvEscape(span.Name),
		csvEscape(span.Op),
		csvEscape(span.Phase),
		span.StartMS,
		span.EndMS,
		span.DurationMS,
		span.Count,
		csvEscape(span.Source),
	)
}

func csvEscape(s string) string {
	if !strings.ContainsAny(s, ",\"\n\r") {
		return s
	}
	return "\"" + strings.ReplaceAll(s, "\"", "\"\"") + "\""
}

func safeLogValue(s string) string {
	s = strings.ReplaceAll(s, " ", "_")
	s = strings.ReplaceAll(s, "\n", "_")
	s = strings.ReplaceAll(s, "\r", "_")
	if s == "" {
		return "-"
	}
	return s
}
