package main

import (
	"sort"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

// firstTag returns the value of the first tag with the given name, or "".
func firstTag(ev *nostr.Event, name string) string {
	for _, t := range ev.Tags {
		if len(t) >= 2 && t[0] == name {
			return t[1]
		}
	}
	return ""
}

// replyParent returns the parent event id from an ["e", id, ?, "reply"] tag (NIP-10),
// falling back to the first "e" tag if none is explicitly marked "reply".
func replyParent(ev *nostr.Event) string {
	fallback := ""
	for _, t := range ev.Tags {
		if len(t) >= 2 && t[0] == "e" {
			if fallback == "" {
				fallback = t[1]
			}
			if len(t) >= 4 && t[3] == "reply" {
				return t[1]
			}
		}
	}
	return fallback
}

// npubOf encodes a hex pubkey as npub, returning the hex unchanged on failure.
func npubOf(pubkeyHex string) string {
	if npub, err := nip19.EncodePublicKey(pubkeyHex); err == nil {
		return npub
	}
	return pubkeyHex
}

// sortByCreatedDesc sorts index rows newest-first by their created_at string.
func sortByCreatedDesc(rows []map[string]any) {
	sort.SliceStable(rows, func(i, j int) bool {
		return createdOf(rows[i]) > createdOf(rows[j])
	})
}

func createdOf(row map[string]any) string {
	if r, ok := row["row"].(IndexRow); ok {
		return r.CreatedAt
	}
	return ""
}
