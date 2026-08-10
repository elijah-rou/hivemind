package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestOptionalAuthMiddleware_NoToken(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
	h := optionalAuthMiddleware("", ok)

	for _, path := range []string{"/v1/health", "/v1/deployments", "/metrics", "/dashboard", "/static/app.css"} {
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, httptest.NewRequest("GET", path, nil))
		if rr.Code != 200 {
			t.Fatalf("no-token: %s got %d, want 200", path, rr.Code)
		}
	}
}

func TestOptionalAuthMiddleware_HealthExempt(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
	h := optionalAuthMiddleware("secret", ok)

	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest("GET", "/v1/health", nil))
	if rr.Code != 200 {
		t.Fatalf("GET /v1/health without bearer: got %d, want 200", rr.Code)
	}

	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest("POST", "/v1/health", nil))
	if rr.Code != 401 {
		t.Fatalf("POST /v1/health without bearer: got %d, want 401", rr.Code)
	}
}

func TestOptionalAuthMiddleware_ProtectedPaths(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
	h := optionalAuthMiddleware("secret", ok)

	protected := []struct {
		method string
		path   string
	}{
		{"GET", "/metrics"},
		{"GET", "/dashboard"},
		{"GET", "/dashboard/cluster"},
		{"GET", "/dashboard/nodes"},
		{"GET", "/static/app.css"},
		{"GET", "/v1/deployments"},
		{"GET", "/v1/nodes"},
		{"POST", "/v1/deployments"},
	}

	for _, tc := range protected {
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, httptest.NewRequest(tc.method, tc.path, nil))
		if rr.Code != 401 {
			t.Errorf("no bearer: %s %s got %d, want 401", tc.method, tc.path, rr.Code)
		}
		if rr.Header().Get("WWW-Authenticate") == "" {
			t.Errorf("no bearer: %s %s missing WWW-Authenticate header", tc.method, tc.path)
		}

		rr = httptest.NewRecorder()
		req := httptest.NewRequest(tc.method, tc.path, nil)
		req.Header.Set("Authorization", "Bearer secret")
		h.ServeHTTP(rr, req)
		if rr.Code != 200 {
			t.Errorf("correct bearer: %s %s got %d, want 200", tc.method, tc.path, rr.Code)
		}

		rr = httptest.NewRecorder()
		req = httptest.NewRequest(tc.method, tc.path, nil)
		req.Header.Set("Authorization", "Bearer wrong")
		h.ServeHTTP(rr, req)
		if rr.Code != 401 {
			t.Errorf("wrong bearer: %s %s got %d, want 401", tc.method, tc.path, rr.Code)
		}
	}
}

func TestBearerTokenMatches(t *testing.T) {
	cases := []struct {
		header string
		want   bool
	}{
		{"", false},
		{"Basic secret", false},
		{"Bearer", false},
		{"Bearer ", false},
		{"Bearer wrong", false},
		{"Bearer secretx", false},
		{"Bearer secret", true},
	}
	for _, tc := range cases {
		req := httptest.NewRequest("GET", "/", nil)
		if tc.header != "" {
			req.Header.Set("Authorization", tc.header)
		}
		got := bearerTokenMatches(req, "secret")
		if got != tc.want {
			t.Errorf("header=%q got %v, want %v", tc.header, got, tc.want)
		}
	}
}
