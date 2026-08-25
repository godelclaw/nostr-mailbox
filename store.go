package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// IndexRow is one message's state (per-avatar, mutable). See README/.mailbox/index.json.
type IndexRow struct {
	Status    string `json:"status"` // unread|read|considered|postponed|done|sent
	Dir       string `json:"dir"`    // in|out
	Peer      string `json:"peer"`   // from (in) or to (out), a registry name/npub
	Subject   string `json:"subject"`
	CreatedAt string `json:"created_at"`
	Received  string `json:"received_at,omitempty"`
	File      string `json:"file"`
	Note      string `json:"note,omitempty"`
	Updated   string `json:"updated_at"`
}

// Store owns .mailbox/index.json and .mailbox/cursor, plus archive-file writing.
// All mutations are serialized and persisted immediately (crash-safe enough for v1).
type Store struct {
	mu       sync.Mutex
	stateDir string
	inboxDir string
	outbox   string
	index    map[string]IndexRow // event_id → row
}

func openStore(stateDir, inbox, outbox string) (*Store, error) {
	for _, d := range []string{stateDir, inbox, outbox} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return nil, fmt.Errorf("mkdir %s: %w", d, err)
		}
	}
	s := &Store{stateDir: stateDir, inboxDir: inbox, outbox: outbox, index: map[string]IndexRow{}}
	if b, err := os.ReadFile(s.indexPath()); err == nil {
		if err := json.Unmarshal(b, &s.index); err != nil {
			return nil, fmt.Errorf("parse index: %w", err)
		}
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("read index: %w", err)
	}
	return s, nil
}

func (s *Store) indexPath() string  { return filepath.Join(s.stateDir, "index.json") }
func (s *Store) cursorPath() string { return filepath.Join(s.stateDir, "cursor") }

// has reports whether an event id is already indexed (idempotent archive / dedupe).
func (s *Store) has(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.index[id]
	return ok
}

// get returns the indexed row for an event id, if present.
func (s *Store) get(id string) (IndexRow, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	row, ok := s.index[id]
	return row, ok
}

func (s *Store) put(id string, row IndexRow) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	row.Updated = nowISO()
	s.index[id] = row
	return s.flushLocked()
}

func (s *Store) setStatus(id, status, note string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	row, ok := s.index[id]
	if !ok {
		return fmt.Errorf("unknown message %s", id)
	}
	row.Status = status
	if note != "" {
		row.Note = note
	}
	row.Updated = nowISO()
	s.index[id] = row
	return s.flushLocked()
}

// list returns rows filtered by status set (empty = all), newest-first by created_at.
func (s *Store) list(statuses map[string]bool) []map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []map[string]any{}
	for id, row := range s.index {
		if len(statuses) > 0 && !statuses[row.Status] {
			continue
		}
		out = append(out, map[string]any{"id": id, "row": row})
	}
	// simple newest-first: sort by CreatedAt string (ISO/unix both sort lexically ok here
	// only if same format; created_at is stored ISO — see archive)
	sortByCreatedDesc(out)
	return out
}

func (s *Store) flushLocked() error {
	b, err := json.MarshalIndent(s.index, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(s.indexPath(), b, 0o644)
}

// cursor: last-seen created_at (unix seconds) so a restart refetches only newer events.
func (s *Store) readCursor() int64 {
	b, err := os.ReadFile(s.cursorPath())
	if err != nil {
		return 0
	}
	var ts int64
	fmt.Sscanf(strings.TrimSpace(string(b)), "%d", &ts)
	return ts
}

func (s *Store) writeCursor(ts int64) error {
	return atomicWrite(s.cursorPath(), []byte(fmt.Sprintf("%d\n", ts)), 0o644)
}

// archive writes a message to inbox/ (dir=in) or outbox/ (dir=out) with YAML frontmatter,
// returning the repo-relative-ish file path recorded in the index.
func (s *Store) archive(dir string, m ArchiveMeta, body string) (string, error) {
	base := s.inboxDir
	verb := "from"
	peer := m.FromName
	if dir == "out" {
		base = s.outbox
		verb = "to"
		peer = m.ToName
	}
	day := m.CreatedAt.Format("2006-01-02")
	name := fmt.Sprintf("%s-%s-%s-%s.md", day, verb, slug(peer), slug(m.Subject))
	path := filepath.Join(base, name)
	if _, err := os.Stat(path); err == nil {
		// collision → append a short event-id
		name = fmt.Sprintf("%s-%s-%s-%s-%s.md", day, verb, slug(peer), slug(m.Subject), shortID(m.EventID))
		path = filepath.Join(base, name)
	}
	fm := frontmatter(m)
	if err := atomicWrite(path, []byte(fm+"\n"+body+"\n"), 0o644); err != nil {
		return "", err
	}
	return filepath.Join(filepath.Base(base), name), nil
}

// ArchiveMeta is the envelope written into an archive file's frontmatter.
type ArchiveMeta struct {
	EventID   string
	Kind      int
	From      string // npub
	FromName  string
	FromDid   string
	To        string // npub
	ToName    string
	Subject   string
	ReplyTo   string
	CreatedAt time.Time
	Received  time.Time
	Sig       string
}

func frontmatter(m ArchiveMeta) string {
	var b strings.Builder
	b.WriteString("---\n")
	fmt.Fprintf(&b, "event_id: %s\n", m.EventID)
	fmt.Fprintf(&b, "kind: %d\n", m.Kind)
	fmt.Fprintf(&b, "from: %s\n", m.From)
	fmt.Fprintf(&b, "from_name: %s\n", m.FromName)
	if m.FromDid != "" {
		fmt.Fprintf(&b, "from_did: %s\n", m.FromDid)
	}
	fmt.Fprintf(&b, "to: %s\n", m.To)
	fmt.Fprintf(&b, "to_name: %s\n", m.ToName)
	fmt.Fprintf(&b, "subject: %q\n", m.Subject)
	if m.ReplyTo != "" {
		fmt.Fprintf(&b, "reply_to: %s\n", m.ReplyTo)
	} else {
		b.WriteString("reply_to: null\n")
	}
	fmt.Fprintf(&b, "created_at: %s\n", m.CreatedAt.UTC().Format(time.RFC3339))
	if !m.Received.IsZero() {
		fmt.Fprintf(&b, "received_at: %s\n", m.Received.UTC().Format(time.RFC3339))
	}
	fmt.Fprintf(&b, "sig: %s\n", m.Sig)
	b.WriteString("---\n")
	return b.String()
}

var slugRe = regexp.MustCompile(`[^a-z0-9]+`)

func slug(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	s = slugRe.ReplaceAllString(s, "-")
	s = strings.Trim(s, "-")
	if s == "" {
		return "untitled"
	}
	if len(s) > 60 {
		s = s[:60]
	}
	return s
}

func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

func nowISO() string { return time.Now().UTC().Format(time.RFC3339) }

// atomicWrite writes to a temp file in the same dir then renames, so a crash never leaves
// a half-written index/archive.
func atomicWrite(path string, b []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
