package main

import (
	"encoding/json"
	"golang.org/x/exp/slog"
	"net/http"
	"strings"
)

func (rs *RequestStore) rootHandler(w http.ResponseWriter, r *http.Request) {
	b := rs.Add(r)
	if b == nil {
		slog.Error("failed to store request", "url", r.URL.String())
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_, err := w.Write(b)
	if err != nil {
		slog.Error("failed to write response", "error", err)
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
}

func (rs *RequestStore) logHandler(w http.ResponseWriter, r *http.Request) {
	url := r.URL.String()
	url = strings.TrimPrefix(url, "/logs")

	// we store root requests under the / url so we need to make sure we ge those correctly as well
	if url == "" {
		url = "/"
	}

	rs.Print(w, url)
}

func (rs *RequestStore) logAllHandler(w http.ResponseWriter, r *http.Request) {
	err := json.NewEncoder(w).Encode(rs.Requests)
	if err != nil {
		slog.Error("failed to encode requests", "error", err)
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
}
