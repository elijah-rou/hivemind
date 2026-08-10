package main

import (
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

type ProbeResult struct {
	Healthy   bool
	LatencyMs int64
	Error     string
	LastCheck time.Time
}

type DNSProber struct {
	targets  []string
	interval time.Duration
	results  sync.Map
}

func NewDNSProber(targets []string, interval time.Duration) *DNSProber {
	return &DNSProber{
		targets:  targets,
		interval: interval,
	}
}

func (p *DNSProber) Run() {
	// Initial probe immediately
	p.probeAll()

	ticker := time.NewTicker(p.interval)
	defer ticker.Stop()
	for range ticker.C {
		p.probeAll()
	}
}

func (p *DNSProber) probeAll() {
	for _, target := range p.targets {
		start := time.Now()
		_, err := net.LookupHost(target)
		elapsed := time.Since(start).Milliseconds()

		result := ProbeResult{
			Healthy:   err == nil,
			LatencyMs: elapsed,
			LastCheck: time.Now(),
		}
		if err != nil {
			result.Error = err.Error()
		}
		p.results.Store(target, result)
	}
}

func (p *DNSProber) Get(target string) (ProbeResult, bool) {
	v, ok := p.results.Load(target)
	if !ok {
		return ProbeResult{}, false
	}
	return v.(ProbeResult), true
}

func (p *DNSProber) All() map[string]ProbeResult {
	m := make(map[string]ProbeResult)
	p.results.Range(func(k, v any) bool {
		m[k.(string)] = v.(ProbeResult)
		return true
	})
	return m
}

// PrometheusMetrics returns Prometheus-formatted probe metrics.
func (p *DNSProber) PrometheusMetrics() string {
	var b strings.Builder
	b.WriteString("# HELP hivemind_dns_probe_up Whether DNS resolution succeeded\n")
	b.WriteString("# TYPE hivemind_dns_probe_up gauge\n")

	results := p.All()
	for target, r := range results {
		up := 0
		if r.Healthy {
			up = 1
		}
		fmt.Fprintf(&b, "hivemind_dns_probe_up{target=%q} %d\n", target, up)
	}

	b.WriteString("# HELP hivemind_dns_probe_latency_ms DNS resolution latency in milliseconds\n")
	b.WriteString("# TYPE hivemind_dns_probe_latency_ms gauge\n")
	for target, r := range results {
		fmt.Fprintf(&b, "hivemind_dns_probe_latency_ms{target=%q} %d\n", target, r.LatencyMs)
	}

	return b.String()
}

// ServeMetrics handles GET /metrics on the Go API with probe data.
func (p *DNSProber) ServeMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.Write([]byte(p.PrometheusMetrics()))
}
