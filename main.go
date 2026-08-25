// nostr-mailbox: a per-avatar mailbox container. Holds the avatar's Nostr key, signs and
// publishes messages, fetches + archives incoming mail into inbox/, maintains a
// message-state index, and serves a token-guarded local HTTP API for the CLI.
//
// On-demand lifecycle: it comes up with the avatar, fetches everything missed since its
// cursor, then serves + subscribes live until stopped. Only the relay is always-on.
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)

	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	reg, err := loadRegistry(cfg.Registry)
	if err != nil {
		log.Fatalf("registry: %v", err)
	}
	self, ok := reg.resolveName(cfg.Avatar)
	if !ok {
		log.Fatalf("registry has no entry for MAILBOX_AVATAR=%q", cfg.Avatar)
	}
	id, err := loadIdentity(cfg.Nsec, self)
	if err != nil {
		log.Fatalf("identity: %v", err)
	}
	store, err := openStore(cfg.StateDir, cfg.Inbox, cfg.Outbox)
	if err != nil {
		log.Fatalf("store: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pool := newRelayPool(cfg.Relays)
	pool.connectAll(ctx)
	mb := &Mailbox{cfg: cfg, id: id, reg: reg, pool: pool, store: store}

	log.Printf("nostr-mailbox up: avatar=%s npub=%s relays=%v", cfg.Avatar, id.Npub, cfg.Relays)

	// Receive loop: fetch-since-cursor + live subscription, with reconnect.
	go mb.receiveLoop(ctx)

	// Local HTTP API.
	api := &API{cfg: cfg, mb: mb}
	srv := &http.Server{Addr: cfg.APIAddr, Handler: api.routes()}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
	}()
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("api: %v", err)
	}
	log.Printf("nostr-mailbox stopped")
	_ = os.Stdout.Sync()
}

// receiveLoop subscribes for this avatar's mail (kinds 3838/3839, #p == my pubkey) from
// the cursor onward, and keeps the subscription live, reconnecting on drop. Archiving is
// idempotent (dedupe by event id), so a refetch after reconnect is harmless.
func (mb *Mailbox) receiveLoop(ctx context.Context) {
	for ctx.Err() == nil {
		if !mb.pool.connected() {
			mb.pool.connectAll(ctx)
			if !mb.pool.connected() {
				sleep(ctx, 5*time.Second)
				continue
			}
		}
		since := nostr.Timestamp(mb.store.readCursor())
		filter := nostr.Filter{
			Kinds: []int{KindMessage, KindReceipt},
			Tags:  nostr.TagMap{"p": []string{mb.id.PubkeyHex}},
			Since: &since,
		}
		log.Printf("subscribing since=%d", since)
		for ev := range mb.pool.subscribe(ctx, filter) {
			mb.handleIncoming(ctx, ev)
		}
		// channel closed => ctx done or all relays dropped; loop reconnects.
		if ctx.Err() == nil {
			log.Printf("subscription ended; reconnecting")
			sleep(ctx, 2*time.Second)
		}
	}
}

func sleep(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}
