package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
)

// API is the local HTTP surface the CLI drives. It listens only on the avatar network and
// requires the bearer token — two layers of access control (design §4.5).
type API struct {
	cfg *Config
	mb  *Mailbox
}

func (a *API) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", a.auth(a.health))
	mux.HandleFunc("/send", a.auth(a.send))
	mux.HandleFunc("/contacts", a.auth(a.contacts))
	mux.HandleFunc("/messages", a.auth(a.messages))    // GET list (?status=)
	mux.HandleFunc("/messages/", a.auth(a.messageByID)) // GET one, POST .../status
	return mux
}

func (a *API) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if subtleEqual(got, a.cfg.APIToken) {
			next(w, r)
			return
		}
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	}
}

func (a *API) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":              true,
		"avatar":          a.cfg.Avatar,
		"relay_connected": a.mb.pool.connected(),
		"cursor":          a.mb.store.readCursor(),
	})
}

func (a *API) send(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var req SendRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if req.To == "" || req.Body == "" {
		http.Error(w, "to and body are required", http.StatusBadRequest)
		return
	}
	id, err := a.mb.send(context.Background(), req)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"event_id": id})
}

func (a *API) contacts(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, a.mb.reg.all())
}

func (a *API) messages(w http.ResponseWriter, r *http.Request) {
	statuses := map[string]bool{}
	if q := r.URL.Query().Get("status"); q != "" {
		for _, s := range strings.Split(q, ",") {
			if s = strings.TrimSpace(s); s != "" {
				statuses[s] = true
			}
		}
	}
	writeJSON(w, http.StatusOK, a.mb.store.list(statuses))
}

// messageByID handles GET /messages/{id} and POST /messages/{id}/status.
func (a *API) messageByID(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/messages/")
	if rest == "" {
		http.NotFound(w, r)
		return
	}
	if id, ok := strings.CutSuffix(rest, "/status"); ok {
		a.setStatus(w, r, id)
		return
	}
	row, ok := a.mb.store.get(rest)
	if !ok {
		http.NotFound(w, r)
		return
	}
	body := ""
	if row.File != "" {
		// File is stored relative to the avatar root's inbox/outbox base name; resolve
		// against the configured dirs.
		if b, err := os.ReadFile(a.resolveFile(row.File)); err == nil {
			body = string(b)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": rest, "row": row, "content": body})
}

func (a *API) setStatus(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Status string `json:"status"`
		Note   string `json:"note"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Status == "" {
		http.Error(w, "status is required", http.StatusBadRequest)
		return
	}
	if err := a.mb.store.setStatus(id, body.Status, body.Note); err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"ok": "true"})
}

func (a *API) resolveFile(rel string) string {
	// rel is like "inbox/2026-…md" or "outbox/…"; map the leading segment to the config.
	if strings.HasPrefix(rel, "outbox/") {
		return a.cfg.Outbox + "/" + strings.TrimPrefix(rel, "outbox/")
	}
	return a.cfg.Inbox + "/" + strings.TrimPrefix(rel, "inbox/")
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// subtleEqual is a constant-time-ish string compare for the token.
func subtleEqual(a, b string) bool {
	if len(a) != len(b) || a == "" {
		return false
	}
	var v byte
	for i := 0; i < len(a); i++ {
		v |= a[i] ^ b[i]
	}
	return v == 0
}
