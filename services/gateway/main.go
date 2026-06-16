// gateway — thin HTTP reverse proxy in front of the vote and result services.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
)

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func newProxy(target string) *httputil.ReverseProxy {
	u, err := url.Parse(target)
	if err != nil {
		log.Fatalf("invalid upstream %q: %v", target, err)
	}
	return httputil.NewSingleHostReverseProxy(u)
}

func main() {
	voteSvc   := getenv("VOTE_SERVICE",   "http://localhost:5000")
	resultSvc := getenv("RESULT_SERVICE", "http://localhost:3000")
	port      := getenv("PORT",           "8080")

	voteProxy   := newProxy(voteSvc)
	resultProxy := newProxy(resultSvc)

	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok", "service": "gateway"})
	})

	// /vote/** → vote service
	mux.HandleFunc("/vote", func(w http.ResponseWriter, r *http.Request) {
		voteProxy.ServeHTTP(w, r)
	})
	mux.HandleFunc("/vote/", func(w http.ResponseWriter, r *http.Request) {
		r.URL.Path = strings.TrimPrefix(r.URL.Path, "/vote")
		voteProxy.ServeHTTP(w, r)
	})

	// /results/** and / → result service
	mux.HandleFunc("/results", func(w http.ResponseWriter, r *http.Request) {
		resultProxy.ServeHTTP(w, r)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		resultProxy.ServeHTTP(w, r)
	})

	addr := fmt.Sprintf("0.0.0.0:%s", port)
	log.Printf("gateway listening on %s  (vote→%s  result→%s)", addr, voteSvc, resultSvc)
	log.Fatal(http.ListenAndServe(addr, mux))
}
