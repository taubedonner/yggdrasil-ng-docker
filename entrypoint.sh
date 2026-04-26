#!/bin/sh

set -e

CONFIG_FILE="/config/yggdrasil.toml"
GENERATED_CONFIG="/tmp/yggdrasil-generated.toml"

log() { echo "[entrypoint] $*"; }

## Config file

if [ -f "$CONFIG_FILE" ]; then
    log "Using config file: $CONFIG_FILE"
    ACTIVE_CONFIG="$CONFIG_FILE"
else
    log "Config file was not found in /config/ - creating a temporary config"
    /usr/bin/yggdrasil --genconf "$GENERATED_CONFIG"
    ACTIVE_CONFIG="$GENERATED_CONFIG"

    # Apply ENV parameters to the generated config

    # private_key is overridden via YGGDRASIL_PRIVATE_KEY (native support)
    # if [ -n "$YGGDRASIL_PRIVATE_KEY" ]; then
    #     sed -i "s|^private_key = .*|private_key = \"$YGGDRASIL_PRIVATE_KEY\"|" "$ACTIVE_CONFIG"
    #     log "Applied YGGDRASIL_PRIVATE_KEY"
    # fi

    if [ -n "$YGG_PEERS" ]; then
        PEERS_TOML=$(echo "$YGG_PEERS" | tr ' ' '\n' | sed 's/.*/"&"/' | paste -sd ',' -)
        sed -i "s|^peers = .*|peers = [$PEERS_TOML]|" "$ACTIVE_CONFIG"
    fi

    if [ -n "$YGG_LISTEN" ]; then
        sed -i "s|^listen = .*|listen = [\"$YGG_LISTEN\"]|" "$ACTIVE_CONFIG"
    fi

    if [ -n "$YGG_ADMIN_LISTEN" ]; then
        sed -i "s|^admin_listen = .*|admin_listen = \"$YGG_ADMIN_LISTEN\"|" "$ACTIVE_CONFIG"
    fi

    if [ -n "$YGG_TUN_NAME" ]; then
        sed -i "s|^if_name = .*|if_name = \"$YGG_TUN_NAME\"|" "$ACTIVE_CONFIG"
    fi

    # CKR section
    if [ "$CKR_ENABLE" = "true" ]; then
        log "CKR: Enabling tunnel_routing from environment variables"

        IPV4_ADDR="${CKR_IPV4_ADDRESS:-10.99.0.1/24}"
        YGG_ROUTING="${CKR_YGGDRASIL_ROUTING:-true}"

        cat >> "$ACTIVE_CONFIG" <<TOML

[tunnel_routing]
enable = true
yggdrasil_routing = $YGG_ROUTING
ipv4_address = "$IPV4_ADDR"

[tunnel_routing.remote_subnets]
TOML

        # Parse CKR_REMOTE_SUBNETS="key1:cidr1,cidr2 key2:cidr3"
        if [ -n "$CKR_REMOTE_SUBNETS" ]; then
            for entry in $CKR_REMOTE_SUBNETS; do
                pubkey="${entry%%:*}"
                cidrs="${entry#*:}"
                # Convert "cidr1,cidr2" to ["cidr1", "cidr2"]
                cidr_toml=$(echo "$cidrs" | tr ',' '\n' | sed 's/.*/"&"/' | paste -sd ',' -)
                echo "\"$pubkey\" = [$cidr_toml]" >> "$ACTIVE_CONFIG"
            done
        fi
    fi
fi

## System configuration

log "Enabling IP forwarding"
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
sysctl -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true

## NAT

if [ "$NAT_ENABLE" = "true" ]; then
    SRC="${NAT_SOURCE_CIDR:-10.99.0.0/24}"
    OUT="${NAT_OUT_IFACE:-eth0}"
    log "NAT: MASQUERADE $SRC -> $OUT"
    # iptables -t nat -F 2>/dev/null || true
    # iptables -F 2>/dev/null || true
    iptables -t nat -A POSTROUTING -s "$SRC" -o "$OUT" -j MASQUERADE 2>/dev/null || \
        log "WARN: iptables MASQUERADE command failed (host network management capabilities may be missing)"
    iptables -A FORWARD -i ygg+ -o "$OUT" -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i "$OUT" -o ygg+ -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
fi

## Additional host routes
# HOST_ROUTES="192.168.88.0/24:172.17.0.1 10.0.0.0/8:172.17.0.1"

if [ -n "$HOST_ROUTES" ]; then
    for route in $HOST_ROUTES; do
        cidr="${route%%:*}"
        gw="${route#*:}"
        log "Route: $cidr via $gw"
        ip route add "$cidr" via "$gw" 2>/dev/null || \
            log "WARN: route $cidr already exists or failed"
    done
fi

## Run

log "Running yggdrasil-ng with config: $ACTIVE_CONFIG"
exec /usr/bin/yggdrasil -c "$ACTIVE_CONFIG" "$@"
