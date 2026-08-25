package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// Contact is one identity in the shared registry. Multiaddressing: one identity, many
// bound addresses (npub, did:key, future dids); the mailbox routes on PubkeyHex.
type Contact struct {
	Npub      string   `json:"npub"`
	PubkeyHex string   `json:"pubkey_hex"`
	DidKey    string   `json:"did:key"`
	Dids      []string `json:"dids"`
	Display   string   `json:"display"`
}

// Registry is the shared name→identity map, loaded read-only.
type Registry struct {
	mu       sync.RWMutex
	path     string
	byName   map[string]Contact
	byPubkey map[string]string // pubkey_hex → name
}

func loadRegistry(path string) (*Registry, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read registry %s: %w", path, err)
	}
	var raw map[string]Contact
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, fmt.Errorf("parse registry %s: %w", path, err)
	}
	r := &Registry{path: path, byName: raw, byPubkey: map[string]string{}}
	for name, c := range raw {
		if c.PubkeyHex != "" {
			r.byPubkey[strings.ToLower(c.PubkeyHex)] = name
		}
	}
	return r, nil
}

func (r *Registry) resolveName(name string) (Contact, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	c, ok := r.byName[name]
	return c, ok
}

// nameForPubkey returns the registry name for a pubkey, or the raw npub prefix for an
// unknown (e.g. external) sender — never fails, so external mail still archives.
func (r *Registry) nameForPubkey(pubkeyHex string) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if n, ok := r.byPubkey[strings.ToLower(pubkeyHex)]; ok {
		return n
	}
	if npub, err := nip19.EncodePublicKey(pubkeyHex); err == nil && len(npub) > 12 {
		return npub[:12] // stable, human-distinguishable stand-in
	}
	return pubkeyHex
}

func (r *Registry) all() map[string]Contact {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make(map[string]Contact, len(r.byName))
	for k, v := range r.byName {
		out[k] = v
	}
	return out
}

// Identity holds this avatar's own key material, derived from the injected nsec.
type Identity struct {
	sk        string // private key, hex (kept in-process only, never logged)
	PubkeyHex string
	Npub      string
	DidKey    string
}

// loadIdentity decodes NOSTR_MAILBOX_NSEC (accepts nsec1… or 64-char hex) and asserts it
// matches this avatar's registry entry — a mismatch is a loud startup error.
func loadIdentity(nsec string, self Contact) (*Identity, error) {
	sk, err := decodeSecret(nsec)
	if err != nil {
		return nil, fmt.Errorf("decode NOSTR_MAILBOX_NSEC: %w", err)
	}
	pub, err := nostr.GetPublicKey(sk)
	if err != nil {
		return nil, fmt.Errorf("derive pubkey: %w", err)
	}
	if !strings.EqualFold(pub, self.PubkeyHex) {
		return nil, fmt.Errorf("injected key pubkey %s does not match registry entry %s", pub, self.PubkeyHex)
	}
	npub, _ := nip19.EncodePublicKey(pub)
	return &Identity{sk: sk, PubkeyHex: pub, Npub: npub, DidKey: self.DidKey}, nil
}

func decodeSecret(s string) (string, error) {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, "nsec1") {
		prefix, data, err := nip19.Decode(s)
		if err != nil {
			return "", err
		}
		if prefix != "nsec" {
			return "", fmt.Errorf("expected nsec, got %s", prefix)
		}
		return data.(string), nil
	}
	if len(s) == 64 {
		return strings.ToLower(s), nil
	}
	return "", fmt.Errorf("unrecognized secret format (expected nsec1… or 64-char hex)")
}
