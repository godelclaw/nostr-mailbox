package main

import (
	"fmt"
	"os"
	"strings"
)

// Kind numbers (see design §6 / README wire spec). The message kind doubles as the
// payload-format-version marker.
const (
	KindMessage = 3838
	KindReceipt = 3839
)

// Config is the container's runtime configuration, entirely from env (harness-injected).
type Config struct {
	Avatar   string   // MAILBOX_AVATAR       — this avatar's registry name
	Nsec     string   // NOSTR_MAILBOX_NSEC   — private key (nsec or hex); never logged
	APIToken string   // MAILBOX_API_TOKEN    — bearer token shared with the CLI
	Relays   []string // NOSTR_MAILBOX_RELAYS — comma-separated relay URLs
	Registry string   // MAILBOX_REGISTRY     — path to registry.json (ro)
	StateDir string   // MAILBOX_STATE_DIR    — path to .mailbox/ (rw)
	Inbox    string   // MAILBOX_INBOX        — inbox archive dir (rw)
	Outbox   string   // MAILBOX_OUTBOX       — outbox archive dir (rw)
	APIAddr  string   // MAILBOX_API_ADDR     — listen addr (default :8787)
}

func loadConfig() (*Config, error) {
	c := &Config{
		Avatar:   os.Getenv("MAILBOX_AVATAR"),
		Nsec:     os.Getenv("NOSTR_MAILBOX_NSEC"),
		APIToken: os.Getenv("MAILBOX_API_TOKEN"),
		Registry: os.Getenv("MAILBOX_REGISTRY"),
		StateDir: os.Getenv("MAILBOX_STATE_DIR"),
		Inbox:    os.Getenv("MAILBOX_INBOX"),
		Outbox:   os.Getenv("MAILBOX_OUTBOX"),
		APIAddr:  envOr("MAILBOX_API_ADDR", ":8787"),
	}
	for _, r := range strings.Split(os.Getenv("NOSTR_MAILBOX_RELAYS"), ",") {
		if r = strings.TrimSpace(r); r != "" {
			c.Relays = append(c.Relays, r)
		}
	}

	// Fail loud on anything missing rather than silently mis-binding (harness convention).
	missing := []string{}
	req := map[string]string{
		"MAILBOX_AVATAR": c.Avatar, "NOSTR_MAILBOX_NSEC": c.Nsec,
		"MAILBOX_API_TOKEN": c.APIToken, "MAILBOX_REGISTRY": c.Registry,
		"MAILBOX_STATE_DIR": c.StateDir, "MAILBOX_INBOX": c.Inbox, "MAILBOX_OUTBOX": c.Outbox,
	}
	for k, v := range req {
		if v == "" {
			missing = append(missing, k)
		}
	}
	if len(c.Relays) == 0 {
		missing = append(missing, "NOSTR_MAILBOX_RELAYS")
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("missing required env: %s", strings.Join(missing, ", "))
	}
	return c, nil
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
