# Multi-stage: build the static Go binary, run it on a minimal base.
FROM golang:1.22-alpine AS build
WORKDIR /src
# Cache modules first.
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true
COPY *.go ./
# CGO off → a static binary that runs on scratch/alpine unchanged.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/nostr-mailbox .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && adduser -D -u 10001 mailbox
USER mailbox
COPY --from=build /out/nostr-mailbox /usr/local/bin/nostr-mailbox
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/nostr-mailbox"]
