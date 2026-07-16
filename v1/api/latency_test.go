package main

import (
	"strings"
	"testing"
)

func TestLatencyCSVFormattingEscapesFields(t *testing.T) {
	line := formatLatencyCSV(LatencySpan{
		System:       "hivemind",
		Component:    "api",
		RunID:        "run,1",
		Scenario:     "multi",
		Entity:       "entity",
		DeploymentID: 7,
		PodID:        8,
		Name:         "name\"quoted",
		Op:           "create_deployment",
		Phase:        "api_handler_decode",
		StartMS:      100,
		EndMS:        125,
		DurationMS:   25,
		Count:        1,
		Source:       "api/test",
	})
	if !strings.Contains(line, `"run,1"`) {
		t.Fatalf("expected run_id to be csv-escaped: %q", line)
	}
	if !strings.Contains(line, `"name""quoted"`) {
		t.Fatalf("expected quote to be doubled: %q", line)
	}
}

func TestCommandTimingsToSpansKeepsCorrelation(t *testing.T) {
	timings := CommandTimings{SpansRaw: []TimedSpan{{Phase: "wire_write", StartMS: 1, EndMS: 3, Source: "api/client.go"}}}
	spans := timings.Spans("scale_deployment", "single", "entity", "name", 42, 9)
	if len(spans) != 1 {
		t.Fatalf("got %d spans, want 1", len(spans))
	}
	span := spans[0]
	if span.Op != "scale_deployment" || span.DeploymentID != 42 || span.PodID != 9 || span.Name != "name" {
		t.Fatalf("bad span correlation: %#v", span)
	}
	if span.DurationMS != 0 {
		t.Fatalf("duration should be filled by recorder, got %d", span.DurationMS)
	}
}
