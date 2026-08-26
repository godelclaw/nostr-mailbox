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
# The runtime uid/gid are BUILD ARGS, defaulted to the usual host user, and the
# avatar's compose passes the real HOST_UID/HOST_GID. Two mounts make this
# necessary, and a fixed uid breaks both:
#
#   - /state is a NAMED VOLUME. Docker initialises a fresh named volume from the
#     image's content at the mount path, ownership included — so if the image has
#     no /state, the volume lands root-owned and a non-root container cannot write
#     its index.json or cursor. Creating the directory here, owned by the runtime
#     user, is the only thing that fixes it (a compose `user:` line alone does not).
#   - /mail/inbox and /mail/outbox are HOST BINDS of the avatar's real inbox/ and
#     outbox/, owned by the host user. Only a container running as that uid can
#     write the archives.
#
# So the uid is not cosmetic: it is what makes the mounts work on a host whose
# user is not 1000. See docs/design.md §13 (bind-mount uid mapping).
ARG MAILBOX_UID=1000
ARG MAILBOX_GID=1000
RUN apk add --no-cache ca-certificates tzdata \
    && mkdir -p /state \
    && chown "${MAILBOX_UID}:${MAILBOX_GID}" /state
USER ${MAILBOX_UID}:${MAILBOX_GID}
COPY --from=build /out/nostr-mailbox /usr/local/bin/nostr-mailbox
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/nostr-mailbox"]
