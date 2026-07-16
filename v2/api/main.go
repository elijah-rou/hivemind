package main

import (
	"context"
	"crypto/subtle"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func optionalAuthMiddleware(token string, next http.Handler) http.Handler {
	if token == "" {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/v1/health" {
			next.ServeHTTP(w, r)
			return
		}
		if bearerTokenMatches(r, token) {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Set("WWW-Authenticate", `Bearer realm="hivemind-api"`)
		writeErr(w, http.StatusUnauthorized, "unauthorized")
	})
}

func bearerTokenMatches(r *http.Request, want string) bool {
	auth := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if !strings.HasPrefix(auth, prefix) {
		return false
	}
	got := strings.TrimPrefix(auth, prefix)
	if len(got) != len(want) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

func main() {
	listen := flag.String("listen", ":8080", "HTTP listen address")
	addrs := flag.String("addrs", "127.0.0.1:9001", "comma-separated Hivemind client port addresses")
	dnsTargets := flag.String("dns-targets", "", "comma-separated DNS targets to probe (e.g. api.hivemind.dev,google.com)")
	encryptionKey := flag.String("encryption-key", "", "64-char hex PSK for frame encryption")
	flag.Parse()

	addrList := strings.Split(*addrs, ",")
	for i := range addrList {
		addrList[i] = strings.TrimSpace(addrList[i])
	}

	// Encryption (optional)
	keyHex := *encryptionKey
	if keyHex == "" {
		keyHex = os.Getenv("HIVEMIND_ENCRYPTION_KEY")
	}
	var cryptoState *CryptoState
	if keyHex != "" {
		var err error
		cryptoState, err = NewCryptoState(keyHex)
		if err != nil {
			log.Fatalf("hivemind-api: invalid encryption key: %v", err)
		}
		log.Println("hivemind-api: frame encryption enabled (XChaCha20-Poly1305)")
	} else {
		cryptoState = CryptoDisabled()
	}

	client := NewClient(addrList, cryptoState)
	latencyRecorder := NewLatencyRecorderFromEnv()
	defer latencyRecorder.Close()
	if latencyRecorder.Enabled() {
		log.Println("hivemind-api: latency tracing enabled")
	}

	log.Printf("hivemind-api: connecting to hivemind at %v", addrList)
	if err := client.Connect(); err != nil {
		log.Printf("hivemind-api: initial connect failed: %v (will retry on first request)", err)
	} else {
		log.Printf("hivemind-api: connected to leader at %s", client.Leader())
	}

	mux := http.NewServeMux()
	registerRoutes(mux, client, latencyRecorder)
	registerDashboardRoutes(mux, client)

	// DNS probers (optional)
	if *dnsTargets != "" {
		targets := strings.Split(*dnsTargets, ",")
		for i := range targets {
			targets[i] = strings.TrimSpace(targets[i])
		}
		prober := NewDNSProber(targets, 30*time.Second)
		go prober.Run()
		log.Printf("hivemind-api: DNS probing %v every 30s", targets)
		mux.HandleFunc("GET /metrics", prober.ServeMetrics)
	}

	apiToken := strings.TrimSpace(os.Getenv("HIVEMIND_API_TOKEN"))
	if apiToken != "" {
		log.Println("hivemind-api: HIVEMIND_API_TOKEN is set; requiring Bearer auth (GET /v1/health exempt)")
	}

	handler := loggingMiddleware(stripTrailingSlash(optionalAuthMiddleware(apiToken, mux)))

	server := &http.Server{
		Addr:         *listen,
		Handler:      handler,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 60 * time.Second,
	}

	// Graceful shutdown on SIGTERM/SIGINT
	done := make(chan os.Signal, 1)
	signal.Notify(done, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		log.Printf("hivemind-api: listening on %s", *listen)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("hivemind-api: server error: %v", err)
		}
	}()

	<-done
	log.Println("hivemind-api: shutting down...")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	server.Shutdown(ctx)
}
