package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// Mailbox ties identity + registry + relays + store into the send/receive behaviors.
type Mailbox struct {
	cfg   *Config
	id    *Identity
	reg   *Registry
	pool  *RelayPool
	store *Store
}

// SendRequest is the API body for POST /send.
type SendRequest struct {
	To      string `json:"to"`      // recipient registry name
	Subject string `json:"subject"`
	Body    string `json:"body"`
	ReplyTo string `json:"reply_to,omitempty"` // parent event id (optional)
}

// send builds, signs, and publishes a kind-3838 message, then archives to outbox/.
func (m *Mailbox) send(ctx context.Context, req SendRequest) (string, error) {
	to, ok := m.reg.resolveName(req.To)
	if !ok {
		return "", fmt.Errorf("unknown recipient %q (not in registry)", req.To)
	}
	if !m.pool.connected() {
		// Fail loud (design §7 relay-down policy); the outbox copy below still records it.
		return "", fmt.Errorf("no relay connected; not sent")
	}

	tags := nostr.Tags{
		{"p", to.PubkeyHex},
		{"subject", req.Subject},
		{"from_name", m.cfg.Avatar},
		{"to_name", req.To},
	}
	if req.ReplyTo != "" {
		tags = append(tags, nostr.Tag{"e", req.ReplyTo, "", "reply"})
	}

	ev := nostr.Event{
		PubKey:    m.id.PubkeyHex,
		CreatedAt: nostr.Now(),
		Kind:      KindMessage,
		Tags:      tags,
		Content:   req.Body,
	}
	if err := ev.Sign(m.id.sk); err != nil {
		return "", fmt.Errorf("sign: %w", err)
	}
	if err := m.pool.publish(ctx, ev); err != nil {
		return "", fmt.Errorf("publish: %w", err)
	}

	// Archive a copy to outbox/ and index it as sent.
	meta := ArchiveMeta{
		EventID: ev.ID, Kind: KindMessage,
		From: m.id.Npub, FromName: m.cfg.Avatar, FromDid: m.id.DidKey,
		To: to.Npub, ToName: req.To,
		Subject: req.Subject, ReplyTo: req.ReplyTo,
		CreatedAt: ev.CreatedAt.Time(), Sig: ev.Sig,
	}
	file, err := m.store.archive("out", meta, req.Body)
	if err != nil {
		log.Printf("send %s: outbox archive failed: %v", ev.ID, err)
	}
	_ = m.store.put(ev.ID, IndexRow{
		Status: "sent", Dir: "out", Peer: req.To, Subject: req.Subject,
		CreatedAt: meta.CreatedAt.UTC().Format(time.RFC3339), File: file,
	})
	return ev.ID, nil
}

// handleIncoming verifies, archives, indexes, and receipts one received message event.
// Idempotent: an already-indexed event id is skipped (dedupe on refetch).
func (m *Mailbox) handleIncoming(ctx context.Context, ev *nostr.Event) {
	if ev.Kind == KindReceipt {
		m.handleReceipt(ev)
		return
	}
	if ev.Kind != KindMessage {
		return
	}
	if m.store.has(ev.ID) {
		return
	}
	ok, err := ev.CheckSignature()
	if err != nil || !ok {
		// Fail closed: never archive an event whose signature does not verify.
		log.Printf("recv %s: signature rejected (ok=%v err=%v)", ev.ID, ok, err)
		return
	}

	subject := firstTag(ev, "subject")
	fromName := m.reg.nameForPubkey(ev.PubKey)
	meta := ArchiveMeta{
		EventID: ev.ID, Kind: ev.Kind,
		From: npubOf(ev.PubKey), FromName: fromName,
		To: m.id.Npub, ToName: m.cfg.Avatar,
		Subject: subject, ReplyTo: replyParent(ev),
		CreatedAt: ev.CreatedAt.Time(), Received: time.Now(), Sig: ev.Sig,
	}
	file, err := m.store.archive("in", meta, ev.Content)
	if err != nil {
		log.Printf("recv %s: inbox archive failed: %v", ev.ID, err)
		return
	}
	if err := m.store.put(ev.ID, IndexRow{
		Status: "unread", Dir: "in", Peer: fromName, Subject: subject,
		CreatedAt: meta.CreatedAt.UTC().Format(time.RFC3339),
		Received:  meta.Received.UTC().Format(time.RFC3339), File: file,
	}); err != nil {
		log.Printf("recv %s: index failed: %v", ev.ID, err)
	}
	m.advanceCursor(ev.CreatedAt)
	m.sendReceipt(ctx, ev)
	log.Printf("recv %s: archived from %s (%q)", shortID(ev.ID), fromName, subject)
}

// sendReceipt emits a kind-3839 delivery receipt referencing the original event.
func (m *Mailbox) sendReceipt(ctx context.Context, orig *nostr.Event) {
	ev := nostr.Event{
		PubKey:    m.id.PubkeyHex,
		CreatedAt: nostr.Now(),
		Kind:      KindReceipt,
		Tags:      nostr.Tags{{"e", orig.ID}, {"p", orig.PubKey}},
		Content:   "",
	}
	if err := ev.Sign(m.id.sk); err != nil {
		log.Printf("receipt for %s: sign failed: %v", orig.ID, err)
		return
	}
	if err := m.pool.publish(ctx, ev); err != nil {
		log.Printf("receipt for %s: publish failed: %v", orig.ID, err)
	}
}

// handleReceipt records that one of our sent messages was delivered.
func (m *Mailbox) handleReceipt(ev *nostr.Event) {
	orig := firstTag(ev, "e")
	if orig == "" {
		return
	}
	if row, ok := m.store.get(orig); ok && row.Dir == "out" {
		note := row.Note
		if note == "" {
			note = "delivered " + nowISO()
		}
		_ = m.store.setStatus(orig, row.Status, note)
	}
	m.advanceCursor(ev.CreatedAt)
}

func (m *Mailbox) advanceCursor(ts nostr.Timestamp) {
	if int64(ts) > m.store.readCursor() {
		_ = m.store.writeCursor(int64(ts))
	}
}
