//go:build ignore

// K8s scheduling benchmark - measures create deployment -> pod scheduled.
// Run: go run k8s_bench.go [-n 50] [-namespace bench] [-image nginx:latest]
//
// Uses kubectl proxy for auth. Measures the same thing as the Hivemind bench:
// submit deployment -> pod bound to node.

package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"syscall"
	"time"
)

func main() {
	count := flag.Int("n", 50, "number of deployments")
	namespace := flag.String("namespace", "bench", "kubernetes namespace")
	image := flag.String("image", "nginx:latest", "container image (should be pre-pulled)")
	cleanup := flag.Bool("cleanup", true, "delete namespace after benchmark")
	flag.Parse()

	// Start kubectl proxy
	proxy := exec.Command("kubectl", "proxy", "--port=18443")
	proxy.Stdout = nil
	proxy.Stderr = os.Stderr
	if err := proxy.Start(); err != nil {
		fmt.Printf("failed to start kubectl proxy: %v\n", err)
		return
	}
	defer func() {
		proxy.Process.Signal(syscall.SIGTERM)
		proxy.Wait()
	}()
	time.Sleep(1 * time.Second) // wait for proxy to start

	api := "http://127.0.0.1:18443"
	client := &http.Client{Timeout: 30 * time.Second}

	// Create namespace
	fmt.Printf("k8s-bench: creating namespace %s\n", *namespace)
	if !createNamespace(client, api, *namespace) {
		fmt.Println("failed to create namespace")
		return
	}

	fmt.Printf("k8s-bench: scheduling %d deployments (image=%s)\n", *count, *image)

	latencies := make([]time.Duration, 0, *count)
	totalStart := time.Now()

	for i := 0; i < *count; i++ {
		name := fmt.Sprintf("bench-dep-%d", i)

		start := time.Now()

		if !createDeployment(client, api, *namespace, name, *image) {
			fmt.Printf("create failed at %d\n", i)
			return
		}

		if !waitForScheduled(client, api, *namespace, name, 10*time.Second) {
			fmt.Printf("pod not scheduled at %d (timeout)\n", i)
			latencies = append(latencies, time.Since(start))
			continue
		}

		latencies = append(latencies, time.Since(start))
	}

	printResults("K8s Deploy", *count, time.Since(totalStart), latencies)

	if *cleanup {
		fmt.Printf("\nk8s-bench: cleaning up namespace %s\n", *namespace)
		deleteNamespace(client, api, *namespace)
	}
}

func apiRequest(client *http.Client, method, url string, body []byte) ([]byte, int) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		return nil, 0
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, 0
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return data, resp.StatusCode
}

func createNamespace(client *http.Client, api, ns string) bool {
	body := fmt.Sprintf(`{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"%s"}}`, ns)
	_, status := apiRequest(client, "POST", api+"/api/v1/namespaces", []byte(body))
	return status == 201 || status == 409
}

func deleteNamespace(client *http.Client, api, ns string) {
	apiRequest(client, "DELETE", api+"/api/v1/namespaces/"+ns, nil)
}

func createDeployment(client *http.Client, api, ns, name, image string) bool {
	dep := map[string]any{
		"apiVersion": "apps/v1",
		"kind":       "Deployment",
		"metadata":   map[string]any{"name": name, "namespace": ns},
		"spec": map[string]any{
			"replicas": 1,
			"selector": map[string]any{
				"matchLabels": map[string]string{"app": name},
			},
			"template": map[string]any{
				"metadata": map[string]any{
					"labels": map[string]string{"app": name},
				},
				"spec": map[string]any{
					"terminationGracePeriodSeconds": 0,
					"containers": []map[string]any{
						{
							"name":  "main",
							"image": image,
							"resources": map[string]any{
								"requests": map[string]string{
									"cpu":    "10m",
									"memory": "16Mi",
								},
								"limits": map[string]string{
									"cpu":    "10m",
									"memory": "16Mi",
								},
							},
						},
					},
				},
			},
		},
	}

	body, _ := json.Marshal(dep)
	_, status := apiRequest(client, "POST", fmt.Sprintf("%s/apis/apps/v1/namespaces/%s/deployments", api, ns), body)
	return status == 201
}

func waitForScheduled(client *http.Client, api, ns, depName string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	url := fmt.Sprintf("%s/api/v1/namespaces/%s/pods?labelSelector=app=%s", api, ns, depName)

	for time.Now().Before(deadline) {
		data, status := apiRequest(client, "GET", url, nil)
		if status != 200 {
			time.Sleep(5 * time.Millisecond)
			continue
		}

		var podList struct {
			Items []struct {
				Spec struct {
					NodeName string `json:"nodeName"`
				} `json:"spec"`
			} `json:"items"`
		}

		if err := json.Unmarshal(data, &podList); err != nil {
			time.Sleep(5 * time.Millisecond)
			continue
		}

		for _, pod := range podList.Items {
			if pod.Spec.NodeName != "" {
				return true
			}
		}

		time.Sleep(5 * time.Millisecond)
	}
	return false
}

func printResults(label string, count int, totalDuration time.Duration, latencies []time.Duration) {
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })

	n := len(latencies)
	if n == 0 {
		fmt.Println("no results")
		return
	}
	p50 := latencies[min(n/2, n-1)]
	p99 := latencies[min(int(float64(n)*0.99), n-1)]
	p999 := latencies[min(int(math.Min(float64(n)*0.999, float64(n-1))), n-1)]
	throughput := float64(count) / totalDuration.Seconds()

	var sum time.Duration
	for _, l := range latencies {
		sum += l
	}
	avg := sum / time.Duration(n)

	fmt.Println()
	fmt.Printf("=== %s Benchmark Results ===\n", label)
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
	fmt.Printf("  max:  %s\n", latencies[n-1].Round(time.Microsecond))
}
