#!/bin/sh
#
# Entrypoint for yggdrasil-ng in a container.
#
# Two modes:
#   1. A config mounted at /config/yggdrasil.toml is used as-is. Environment
#      variables are ignored, and a warning is logged if any are set.
#   2. No config file: an ephemeral one is generated and populated from the
#      environment. Nothing is persisted, so the node identity changes on every
#      start unless YGGDRASIL_PRIVATE_KEY is set.
#
# Config keys follow yggdrasil-ng 0.3.x. Note that `ipv4_address` under
# [tunnel_routing] is deprecated upstream in favour of the `ip_addresses` array.

set -e

CONFIG_FILE="/config/yggdrasil.toml"
GENERATED_CONFIG="/tmp/yggdrasil-generated.toml"
YGG_BIN=/usr/bin/yggdrasil

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] WARN: $*" >&2; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# Quote a whitespace-separated list into a TOML array body: a b -> "a", "b"
toml_list() {
    echo "$1" | tr ' ' '\n' | sed '/^$/d; s/.*/"&"/' | paste -sd ',' -
}

# Set a top-level scalar key, whether the template has it live or commented out.
#
# Two traps this avoids:
#   - several template keys ship commented, so a plain 's|^key = .*|...|'
#     silently matches nothing (this is why YGG_ADMIN_LISTEN used to be ignored);
#   - the same key name reappears inside tables with a different type -
#     [[multicast_interfaces]] has a boolean `listen`, and a global substitution
#     would rewrite it into an array. Only lines above the first table header
#     are touched; if the key is absent it is inserted just before that header.
set_key() {
    key=$1; value=$2; file=$3
    awk -v k="$key" -v v="$value" '
        BEGIN { done = 0; intable = 0 }
        {
            if (!intable && $0 ~ /^[[:space:]]*\[/) {
                if (!done) { print k " = " v; print ""; done = 1 }
                intable = 1
            }
            if (!intable && !done && $0 ~ "^[[:space:]]*#?[[:space:]]*" k "[[:space:]]*=") {
                print k " = " v
                done = 1
                next
            }
            print
        }
        END { if (!done) print k " = " v }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

## Config file

if [ -f "$CONFIG_FILE" ]; then
    log "Using mounted config: $CONFIG_FILE"
    ACTIVE_CONFIG="$CONFIG_FILE"

    for var in YGG_PEERS YGG_LISTEN YGG_ADMIN_LISTEN YGG_TUN_NAME CKR_ENABLE; do
        eval "value=\$$var"
        [ -n "$value" ] && warn "$var is set but ignored: the mounted config wins"
    done
else
    log "No config at $CONFIG_FILE - generating an ephemeral one"
    # Note the "=": --genconf and --normalize take an OPTIONAL argument, and
    # getopts only binds those in the --opt=VALUE form. With a space the path
    # becomes a free argument and is parsed as a control command, which fails
    # with "Failed to connect to admin socket".
    "$YGG_BIN" --genconf="$GENERATED_CONFIG"
    ACTIVE_CONFIG="$GENERATED_CONFIG"

    # private_key is read natively from YGGDRASIL_PRIVATE_KEY by the daemon.
    [ -n "$YGGDRASIL_PRIVATE_KEY" ] || warn "no YGGDRASIL_PRIVATE_KEY: this node gets a new identity on every start"

    [ -n "$YGG_PEERS" ]        && set_key peers        "[$(toml_list "$YGG_PEERS")]"  "$ACTIVE_CONFIG"
    [ -n "$YGG_LISTEN" ]       && set_key listen       "[$(toml_list "$YGG_LISTEN")]" "$ACTIVE_CONFIG"
    [ -n "$YGG_ADMIN_LISTEN" ] && set_key admin_listen "\"$YGG_ADMIN_LISTEN\""        "$ACTIVE_CONFIG"
    [ -n "$YGG_TUN_NAME" ]     && set_key if_name      "\"$YGG_TUN_NAME\""            "$ACTIVE_CONFIG"
    [ -n "$YGG_MTU" ]          && set_key if_mtu       "$YGG_MTU"                     "$ACTIVE_CONFIG"

    ## Crypto-Key Routing
    #
    # remote_subnets is a longest-prefix-match table mapping a destination
    # prefix to the public key that owns it. The same table gates inbound
    # traffic: a packet is accepted only if the route for its SOURCE address
    # points at the peer that actually sent it. Both ends therefore need
    # matching entries, or one direction is silently dropped.
    if [ "$CKR_ENABLE" = "true" ]; then
        log "CKR: building [tunnel_routing] from the environment"

        CKR_ADDRS="${CKR_IP_ADDRESSES:-${CKR_IPV4_ADDRESS:-10.99.0.1/24}}"
        [ -n "$CKR_IPV4_ADDRESS" ] && [ -z "$CKR_IP_ADDRESSES" ] && \
            warn "CKR_IPV4_ADDRESS is kept for compatibility; prefer CKR_IP_ADDRESSES (space-separated, dual-stack)"

        cat >> "$ACTIVE_CONFIG" <<TOML

[tunnel_routing]
enable = true
yggdrasil_routing = ${CKR_YGGDRASIL_ROUTING:-true}
install_system_routes = ${CKR_INSTALL_SYSTEM_ROUTES:-true}
ip_addresses = [$(toml_list "$CKR_ADDRS")]

[tunnel_routing.remote_subnets]
TOML

        # CKR_REMOTE_SUBNETS="key1:cidr1,cidr2 key2:cidr3"
        for entry in $CKR_REMOTE_SUBNETS; do
            pubkey="${entry%%:*}"
            cidrs="${entry#*:}"
            [ "$pubkey" = "$entry" ] && die "malformed CKR_REMOTE_SUBNETS entry (expected key:cidr[,cidr]): $entry"
            echo "\"$pubkey\" = [$(echo "$cidrs" | tr ',' ' ' | { read -r l; toml_list "$l"; })]" >> "$ACTIVE_CONFIG"
        done
    fi

    # Fail here rather than after the daemon has already reconfigured the host.
    "$YGG_BIN" --normalize="$ACTIVE_CONFIG" >/dev/null 2>&1 || die "generated config is not valid TOML"
fi

## System configuration

log "Enabling IP forwarding"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || warn "could not set net.ipv4.ip_forward (needs NET_ADMIN, or --privileged with host networking)"
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || warn "could not set net.ipv6.conf.all.forwarding"

## NAT
#
# Rules are added idempotently and removed on exit. Without this, a container
# using host networking leaves a MASQUERADE rule behind on every restart, and
# they accumulate in the host's tables.

NAT_APPLIED=""

nat_rule() {
    # nat_rule <cmd> <table-args...> — add unless an identical rule exists
    cmd=$1; shift
    if "$cmd" -C "$@" 2>/dev/null; then
        return 0
    fi
    "$cmd" -A "$@" 2>/dev/null || { warn "$cmd -A $* failed (missing NET_ADMIN?)"; return 1; }
    NAT_APPLIED="$NAT_APPLIED
$cmd $*"
}

nat_cleanup() {
    [ -n "$NAT_APPLIED" ] || return 0
    log "Removing NAT rules"
    echo "$NAT_APPLIED" | while read -r cmd args; do
        [ -n "$cmd" ] || continue
        # shellcheck disable=SC2086
        "$cmd" -D $args 2>/dev/null || true
    done
}

if [ "$NAT_ENABLE" = "true" ]; then
    SRC="${NAT_SOURCE_CIDR:-10.99.0.0/24}"
    OUT="${NAT_OUT_IFACE:-eth0}"
    TUN="${YGG_TUN_NAME:-ygg0}"
    log "NAT: MASQUERADE $SRC via $OUT"

    trap 'nat_cleanup' EXIT INT TERM

    nat_rule iptables -t nat POSTROUTING -s "$SRC" -o "$OUT" -j MASQUERADE
    nat_rule iptables FORWARD -i "$TUN" -o "$OUT" -j ACCEPT
    nat_rule iptables FORWARD -i "$OUT" -o "$TUN" -m state --state RELATED,ESTABLISHED -j ACCEPT

    if [ "$NAT_IPV6" = "true" ]; then
        SRC6="${NAT_SOURCE_CIDR6:-200::/7}"
        log "NAT: IPv6 MASQUERADE $SRC6 via $OUT"
        nat_rule ip6tables -t nat POSTROUTING -s "$SRC6" -o "$OUT" -j MASQUERADE
        nat_rule ip6tables FORWARD -i "$TUN" -o "$OUT" -j ACCEPT
        nat_rule ip6tables FORWARD -i "$OUT" -o "$TUN" -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi

    # The tunnel adds overhead; without clamping, large transfers stall while
    # pings succeed. Upstream documents this as the usual MTU symptom.
    if [ "$NAT_CLAMP_MSS" = "true" ]; then
        log "NAT: clamping TCP MSS to path MTU"
        nat_rule iptables -t mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        [ "$NAT_IPV6" = "true" ] && nat_rule ip6tables -t mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    fi
fi

## Additional host routes
# HOST_ROUTES="192.168.88.0/24:172.17.0.1 10.0.0.0/8:172.17.0.1"

for route in $HOST_ROUTES; do
    cidr="${route%%:*}"
    gw="${route#*:}"
    [ "$cidr" = "$route" ] && die "malformed HOST_ROUTES entry (expected CIDR:gateway): $route"
    log "Route: $cidr via $gw"
    ip route replace "$cidr" via "$gw" || warn "could not add route $cidr via $gw"
done

## Run

log "Starting yggdrasil-ng with $ACTIVE_CONFIG"
exec "$YGG_BIN" -c "$ACTIVE_CONFIG" "$@"
