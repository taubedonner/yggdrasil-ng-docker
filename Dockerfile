# syntax=docker/dockerfile:1
#
# The binary is built in CI (see .github/workflows/build.yml) with cross-rs and
# dropped into bin/<TARGETARCH>/ before this file runs, so no emulation is
# involved here. Binaries are musl-linked and static, which is what Alpine wants.

ARG ALPINE_VERSION=3.21

FROM alpine:${ALPINE_VERSION}

# iproute2 for `ip route`, iptables/ip6tables for the optional NAT rules.
#
# ca-certificates is deliberately absent: Yggdrasil's TLS peering authenticates
# the remote by the ed25519 key carried in its certificate, not by a CA chain,
# so a trust store buys nothing. Upstream's own image ships without one. It also
# unpacks into hundreds of small files, which is enough to exhaust the inodes on
# a router's overlay filesystem mid-build.
RUN apk add --no-cache \
        iproute2 \
        iptables \
        ip6tables

# amd64 | arm64 | arm  (arm covers linux/arm/v7)
ARG TARGETARCH
COPY bin/${TARGETARCH}/yggdrasil /usr/bin/yggdrasil
RUN chmod +x /usr/bin/yggdrasil

VOLUME /config

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

LABEL org.opencontainers.image.title="yggdrasil-ng" \
      org.opencontainers.image.description="Yggdrasil-ng for routers running Docker or the RouterOS container feature" \
      org.opencontainers.image.source="https://github.com/taubedonner/yggdrasil-ng-docker" \
      org.opencontainers.image.licenses="MPL-2.0"

ENTRYPOINT ["/entrypoint.sh"]
CMD []
