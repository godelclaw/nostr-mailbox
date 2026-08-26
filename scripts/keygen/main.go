// keygen prints one fresh Nostr keypair. Run by scripts/mint-avatar-keys, which
// pipes the private key straight into pass -- it is never meant to be read off a
// screen. Deliberately uses only what identity.go already calls (GetPublicKey,
// nip19.EncodePublicKey) plus stdlib, so it cannot drift from the container.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip19"
)

func main() {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	sk := hex.EncodeToString(b)
	pk, err := nostr.GetPublicKey(sk)
	if err != nil {
		panic(err)
	}
	npub, err := nip19.EncodePublicKey(pk)
	if err != nil {
		panic(err)
	}
	fmt.Println("sk_hex     =", sk)
	fmt.Println("pubkey_hex =", pk)
	fmt.Println("npub       =", npub)
}
