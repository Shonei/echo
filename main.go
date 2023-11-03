package main

import (
	"log"
	"net/http"
	"os"

	"golang.org/x/exp/slog"
)

func main() {

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
		slog.Info("using default port", "port", port)
	}

	l := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(l)

	rs := &RequestStore{}
	rs.Requests = make(map[string]*Requests)

	// configure handlers
	http.HandleFunc("/logs/", rs.logHandler)
	http.HandleFunc("/log-all", rs.logAllHandler)
	http.HandleFunc("/", rs.rootHandler)

	log.Printf("Listening on port %s", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		slog.Error("failed to listen and serve", "error", err)
		os.Exit(1)
	}
}
