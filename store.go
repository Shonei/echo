package main

import (
	"encoding/json"
	"golang.org/x/exp/slog"
	"io"
	"net/http"
)

type HTTPRequest struct {
	Method  string              `json:"method"`
	URL     string              `json:"url"`
	Headers map[string][]string `json:"headers,omitempty"`
	Body    any                 `json:"body,omitempty"`
}

type Requests struct {
	Requests [][]byte
	index    int
	cap      int
}

type RequestStore struct {
	Requests map[string]*Requests
}

// Add will store the last request and return the bytes representing the request
// If there are no bytes returned there was an error encountered
func (rs *RequestStore) Add(r *http.Request) []byte {
	url := r.URL.String()

	if _, ok := rs.Requests[url]; !ok {
		req := &Requests{
			cap:   5,
			index: 0,
		}

		rs.Requests[url] = req
		rs.Requests[url].Requests = make([][]byte, req.cap)
	}
	b := rs.Requests[url].AddRequest(r)

	return b
}

func (rs *RequestStore) Print(w http.ResponseWriter, url string) {
	rs.Requests[url].WriteRequests(w)
}

func toRequests(r *http.Request) ([]byte, error) {
	h := HTTPRequest{
		Method:  r.Method,
		URL:     r.URL.String(),
		Headers: r.Header,
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		slog.Error("failed to store request body", "error", err, "request", h)
	} else {
		// We want to store the body as a structured JSOn object but if that fails we'll store it as a string
		var structuredBody any
		err := json.Unmarshal(body, &structuredBody)
		if err != nil {
			slog.Warn("failed to marshal body", "error", err, "request", h, "body", string(body))
			h.Body = string(body)
		} else {
			h.Body = structuredBody
		}

	}

	b, err := json.Marshal(h)
	if err != nil {
		slog.Error("failed to marshal request", "error", err, "request", h)
		return nil, err
	}
	return b, nil
}

// AddRequest will add the last request and return the request as a []byte
func (r *Requests) AddRequest(req *http.Request) []byte {
	httpR, err := toRequests(req)
	if err != nil {
		slog.Error("failed to convert request into []byte", "error", err, "request", req)
		return nil
	}

	if r.index == (r.cap - 1) {
		r.index = 0
	}

	r.Requests[r.index] = httpR
	r.index++

	return httpR
}

func (r *Requests) WriteRequests(w http.ResponseWriter) {
	if r == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	// We want to write the requests in the order they came in starting with the new one first
	for i := r.index - 1; i >= 0; i-- {
		_, err := w.Write(r.Requests[i])
		if err != nil {
			slog.Error("failed to write request", "error", err, "request", r.Requests[i])
			return
		}
	}

	for i := r.index; i < r.cap; i++ {
		_, err := w.Write(r.Requests[i])
		if err != nil {
			slog.Error("failed to write request", "error", err, "request", r.Requests[i])
			return
		}
	}
	w.WriteHeader(http.StatusOK)
}
