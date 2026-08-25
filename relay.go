package main

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/nbd-wtf/go-nostr"
)

// RelayPool is a minimal multi-relay client: it publishes to all relays and merges their
// subscription streams. v1 uses one hub; the pool foreshadows the NuNet multi-relay
// (NIP-65) future without changing callers.
type RelayPool struct {
	urls   []string
	mu     sync.RWMutex
	relays map[string]*nostr.Relay
}

func newRelayPool(urls []string) *RelayPool {
	return &RelayPool{urls: urls, relays: map[string]*nostr.Relay{}}
}

// connectAll dials every relay; a relay that fails to connect is logged and retried by
// the caller's reconnect loop, not fatal (best-effort transport).
func (p *RelayPool) connectAll(ctx context.Context) {
	for _, url := range p.urls {
		p.connect(ctx, url)
	}
}

func (p *RelayPool) connect(ctx context.Context, url string) {
	r, err := nostr.RelayConnect(ctx, url)
	if err != nil {
		log.Printf("relay %s: connect failed: %v", url, err)
		return
	}
	p.mu.Lock()
	p.relays[url] = r
	p.mu.Unlock()
	log.Printf("relay %s: connected", url)
}

func (p *RelayPool) connected() bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return len(p.relays) > 0
}

// publish sends an event to every connected relay; returns nil if at least one accepted.
func (p *RelayPool) publish(ctx context.Context, ev nostr.Event) error {
	p.mu.RLock()
	relays := make([]*nostr.Relay, 0, len(p.relays))
	for _, r := range p.relays {
		relays = append(relays, r)
	}
	p.mu.RUnlock()

	var lastErr error
	ok := false
	for _, r := range relays {
		pctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		if err := r.Publish(pctx, ev); err != nil {
			lastErr = err
			log.Printf("relay %s: publish %s failed: %v", r.URL, ev.ID, err)
		} else {
			ok = true
		}
		cancel()
	}
	if ok {
		return nil
	}
	return lastErr
}

// subscribe opens a subscription on every relay for the given filter and fans events into
// one channel. The channel is closed when ctx is done. Reconnection is handled by the
// caller re-invoking subscribe on a fresh ctx.
func (p *RelayPool) subscribe(ctx context.Context, filter nostr.Filter) <-chan *nostr.Event {
	out := make(chan *nostr.Event, 64)
	p.mu.RLock()
	relays := make([]*nostr.Relay, 0, len(p.relays))
	for _, r := range p.relays {
		relays = append(relays, r)
	}
	p.mu.RUnlock()

	var wg sync.WaitGroup
	for _, r := range relays {
		sub, err := r.Subscribe(ctx, nostr.Filters{filter})
		if err != nil {
			log.Printf("relay %s: subscribe failed: %v", r.URL, err)
			continue
		}
		wg.Add(1)
		go func(url string, sub *nostr.Subscription) {
			defer wg.Done()
			for ev := range sub.Events {
				select {
				case out <- ev:
				case <-ctx.Done():
					return
				}
			}
		}(r.URL, sub)
	}
	go func() { wg.Wait(); close(out) }()
	return out
}
