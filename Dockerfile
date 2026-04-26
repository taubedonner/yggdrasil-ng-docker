# syntax=docker/dockerfile:1

ARG ALPINE_VERSION=3.21

FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache \
        ca-certificates \
        iproute2 \
        iptables \
        ip6tables

ARG TARGETARCH
COPY bin/${TARGETARCH}/yggdrasil /usr/bin/yggdrasil
RUN chmod +x /usr/bin/yggdrasil

VOLUME /config

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD []
