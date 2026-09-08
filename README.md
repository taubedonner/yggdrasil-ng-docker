# yggdrasil-ng-docker

Container image for [Yggdrasil-ng](https://github.com/Revertron/Yggdrasil-ng) – the Rust rewrite of the Yggdrasil mesh daemon with **Crypto-Key Routing (CKR)** support. Images are published for `linux/amd64`, `linux/arm64` and `linux/arm/v7`, on an Alpine base, so the same image runs on OpenWrt/ImmortalWrt devices with Docker and on MikroTik routers with the RouterOS container feature.

CKR is the reason this exists. The reference Go implementation [removed it in v0.4.0](https://github.com/yggdrasil-network/yggdrasil-go/releases/tag/v0.4.0), so `luci-proto-yggdrasil` and the stock OpenWrt `yggdrasil` package cannot tunnel real subnets. Yggdrasil-ng keeps CKR and has it in the default feature set.

Upstream version built by CI: **v0.3.0** (`YGG_VERSION` in `.github/workflows/build.yml`).

## How it works

The container runs one `yggdrasil` binary that creates a TUN interface and joins the mesh over TCP/TLS. On startup the entrypoint:

1. **Loads configuration.** A file mounted at `/config/yggdrasil.toml` is used as-is and every environment variable is ignored (with a warning). Otherwise an ephemeral config is generated and patched from the environment.
2. **Validates it** with `yggdrasil --normalize` before touching anything else, so a typo fails immediately instead of after the daemon has reconfigured the host.
3. **Enables IP forwarding** – required for CKR to route anything through this node.
4. **Applies NAT** when `NAT_ENABLE=true`. Rules are added idempotently and removed on shutdown.
5. **Adds host routes** from `HOST_ROUTES`, using `ip route replace` so restarts do not pile up duplicates.
6. **Starts the daemon.**

## Understanding CKR before you configure it

This is the part that costs people an afternoon, so it is worth stating plainly.

`remote_subnets` is **one longest-prefix-match table that works in both directions**:

- **Outbound** – a packet leaving the TUN has its destination looked up in the table, and is sent to the public key that owns the matching prefix. No match means the packet is silently dropped.
- **Inbound** – a packet arriving from the mesh has its **source** looked up in the same table, and is accepted only if the owning key equals the peer that actually sent it. Everything else is dropped.

Two consequences follow, and both are easy to get wrong:

1. **Both ends need matching entries.** If only one side has a route, traffic leaves but the replies vanish with no error anywhere.
2. **Prefix lengths must describe the real network.** To reach a `/24` LAN you list the `/24`. Note that the upstream [CKR.md](https://github.com/Revertron/Yggdrasil-ng/blob/master/docs/CKR.md) site-to-site example writes `"192.168.1.0/32"` for a `/24` network; a `/32` matches exactly one address and will not carry LAN traffic.

Prefix syntax supported in the CIDR list: a bare address means `/32` or `/128`; a `~` prefix sets up the CKR tunnel without installing a system route; `!` excludes a range; `inetv4` and `inetv6` expand to the public internet prefixes.

> **Do not route your own peering through the tunnel.** A route such as `0.0.0.0/0` or `inetv6` can swallow the address you peer over, and the node loses the mesh it needs to work. Prefer the `0.0.0.0/1` + `128.0.0.0/1` split, or peer over a family the tunnel does not cover. On a remote router this mistake ends your access.

## Reaching a LAN behind a remote node

The common goal: node **R** (a laptop, a VPS) wants to reach `192.168.88.0/24`, the LAN behind router **B**. Get both public keys first with `yggdrasil getSelf`.

**Router B** – owns the LAN, hands out `10.99.0.1` to itself on the tunnel:

```toml
[tunnel_routing]
enable = true
ip_addresses = ["10.99.0.1/24"]

[tunnel_routing.remote_subnets]
"<KEY_R>" = ["10.99.0.2/32"]     # without this, R's packets are dropped inbound
```

**Node R** – takes `10.99.0.2` and routes the LAN prefix at B:

```toml
[tunnel_routing]
enable = true
ip_addresses = ["10.99.0.2/24"]

[tunnel_routing.remote_subnets]
"<KEY_B>" = ["192.168.88.0/24", "10.99.0.1/32"]
```

That is the mesh half. The host half is what usually breaks:

- **B forwards.** `net.ipv4.ip_forward=1` (the entrypoint sets it) and a firewall that permits traffic between the TUN and the LAN. On OpenWrt the TUN must be added to a firewall zone or fw4 drops it.
- **LAN hosts must be able to answer `10.99.0.2`.** If B is their default gateway this is automatic, because `install_system_routes` puts `10.99.0.0/24` on B's TUN. If B is not their gateway, either add a route on the real gateway or use NAT (below).

### When the daemon runs in a container namespace

On RouterOS, and on Docker without `network_mode: host`, the TUN lives inside the container, not on the router. Two extra links are needed:

- **Container → LAN**: `HOST_ROUTES="192.168.88.0/24:172.17.0.1"`, where `172.17.0.1` is the bridge/veth gateway on the router side.
- **Router → tunnel**: a route on the router sending `10.99.0.0/24` to the container's bridge address.

If you would rather not add a route on the router, let the container masquerade instead – LAN hosts then see traffic coming from the container's own bridge address and need no route at all, at the cost of losing the original source address:

```
NAT_ENABLE=true
NAT_SOURCE_CIDR=10.99.0.0/24
NAT_OUT_IFACE=eth0
```

## Configuration

Mounting a config is the recommended path:

```bash
docker run -d \
  --name yggdrasil-ng \
  --restart unless-stopped \
  --cap-add NET_ADMIN \
  --device /dev/net/tun \
  -v ./config:/config:ro \
  -p 1234:1234 \
  ghcr.io/taubedonner/yggdrasil-ng-docker:latest
```

`NET_ADMIN` is sufficient – it covers creating the TUN, adding routes and the namespaced sysctls. `SYS_ADMIN` is not required and should not be granted.

Without a mounted config, these variables are applied to a generated one:

| Variable | Description | Default |
|---|---|---|
| `YGGDRASIL_PRIVATE_KEY` | Hex Ed25519 private key, read natively by the daemon. Without it the node gets a new identity – and a new address – on every start. | – |
| `YGG_PEERS` | Space-separated peer URIs | – |
| `YGG_LISTEN` | Space-separated listen URIs | – |
| `YGG_ADMIN_LISTEN` | Admin socket address | `tcp://localhost:9001` |
| `YGG_TUN_NAME` | TUN interface name (`auto`, `none`, or a name) | `auto` |
| `YGG_MTU` | TUN MTU | `65535` |
| `CKR_ENABLE` | Enable Crypto-Key Routing | `false` |
| `CKR_IP_ADDRESSES` | Space-separated CIDRs for the TUN, dual-stack allowed | `10.99.0.1/24` |
| `CKR_IPV4_ADDRESS` | Deprecated single-address form, kept for compatibility | – |
| `CKR_YGGDRASIL_ROUTING` | Also route native `0200::/7` traffic | `true` |
| `CKR_INSTALL_SYSTEM_ROUTES` | Install system routes for CKR prefixes | `true` |
| `CKR_REMOTE_SUBNETS` | Space-separated `pubkey:cidr1,cidr2` entries | – |
| `HOST_ROUTES` | Space-separated `CIDR:gateway` routes added inside the container | – |
| `NAT_ENABLE` | IPv4 MASQUERADE, for exit-node and container-namespace setups | `false` |
| `NAT_SOURCE_CIDR` | Source subnet to masquerade | `10.99.0.0/24` |
| `NAT_OUT_IFACE` | Outbound interface | `eth0` |
| `NAT_IPV6` | Also masquerade IPv6 | `false` |
| `NAT_SOURCE_CIDR6` | IPv6 source subnet | `200::/7` |
| `NAT_CLAMP_MSS` | Clamp TCP MSS to path MTU | `false` |

`CKR_REMOTE_SUBNETS` maps one-to-one onto the TOML:

```
CKR_REMOTE_SUBNETS="<key_A>:192.168.88.0/24,10.99.0.1/32 <key_B>:172.16.0.0/12"
```

```toml
[tunnel_routing.remote_subnets]
"<key_A>" = ["192.168.88.0/24", "10.99.0.1/32"]
"<key_B>" = ["172.16.0.0/12"]
```

## MikroTik RouterOS

The configuration below is the one running on a hAP ax³ (arm64, RouterOS 7.22.1), where this
image has been the CKR gateway for months. It is hub-and-spoke: the router holds
`10.99.0.1` on the tunnel and hands `/32`s to each client, and LAN access is plain
routing with no NAT anywhere.

Container mode has to be enabled first, which needs physical confirmation and
external storage on some models:

```
/system/device-mode/update container=yes
```

A bridge for containers, and a veth on it:

```
/interface/bridge/add name=containers
/ip/address/add address=172.17.0.1/24 interface=containers
/interface/veth/add name=veth1 address=172.17.0.2/24 gateway=172.17.0.1
/interface/bridge/port/add bridge=containers interface=veth1
```

The container. `mount=` and `env=` take a single entry directly, which is shorter
than declaring `/container/mounts` and `/container/envs` lists when you only need
one of each:

```
/container/add name=yggdrasil-ng interface=veth1 \
    remote-image=ghcr.io/taubedonner/yggdrasil-ng-docker:latest \
    check-certificate=no \
    root-dir=/ygg-root \
    mount=/ygg-config:/config:ro \
    env=HOST_ROUTES=192.168.88.0/24:172.17.0.1 \
    logging=yes start-on-boot=yes
/container/start yggdrasil-ng
```

Put `yggdrasil.toml` in `/ygg-config/` on the router before starting; a mounted
config wins over every environment variable, so `HOST_ROUTES` above is the only
one that still applies.

> `devices=/dev/net/tun` is **not** needed on RouterOS 7.22.1 – the working
> container above has `devices=""` and its TUN comes up fine. Add it only if the
> daemon reports it cannot open the TUN on your firmware version.

> Flash is the real constraint: a hAP ax³ has 128 MB with roughly 60 MB free after
> the system. The image is small enough, but `root-dir` should point at internal
> storage you have actually measured, or at an external disk.

### The router side, which is what usually breaks

Three things have to be in place, and the mesh config cannot compensate for any
of them:

**1. A route back into the tunnel**, so LAN replies for the CKR subnet reach the
container instead of the default gateway:

```
/ip/route/add dst-address=10.99.0.0/24 gateway=172.17.0.2
```

**2. Forwarding between the container bridge and the LAN**, both directions:

```
/ip/firewall/filter/add chain=forward action=accept src-address=172.17.0.0/24 dst-address=192.168.88.0/24
/ip/firewall/filter/add chain=forward action=accept src-address=192.168.88.0/24 dst-address=172.17.0.0/24
```

Place them above the `defconf` drop rules.

**3. Input rules for services on the router itself.** Reaching a LAN host is
covered by forwarding; reaching the *router* (WinBox, DNS) is a separate chain,
and it is easy to forget:

```
/ip/firewall/filter/add chain=input action=accept protocol=tcp in-interface=containers dst-port=53
/ip/firewall/filter/add chain=input action=accept protocol=udp in-interface=containers dst-port=53
/ip/firewall/filter/add chain=input action=accept protocol=tcp in-interface=containers src-address=10.99.0.3 dst-port=8291
```

Note that the source address here is the client's **tunnel** address, not its real
one – nothing is masqueraded, so the original source survives end to end. That is
what makes per-client rules like the WinBox one above possible.

### Matching config

```toml
peers = ["tls://your.relay.example:2053?maxbackoff=30s"]
listen = ["tcp://0.0.0.0:0"]

# Optional but recommended on a gateway: refuse sessions from anyone else.
allowed_public_keys = [
    "<key of each client>",
]

[tunnel_routing]
enable = true
yggdrasil_routing = true
ip_addresses = ["10.99.0.1/24"]

[tunnel_routing.remote_subnets]
"<client_1_key>" = ["10.99.0.3/32"]
"<client_2_key>" = ["10.99.0.4/32"]
```

Each client mirrors it, taking its own `/32` and routing the LAN at the router:

```toml
[tunnel_routing]
enable = true
ip_addresses = ["10.99.0.3/24"]

[tunnel_routing.remote_subnets]
"<router_key>" = ["192.168.88.0/24", "10.99.0.1/32"]
```

`listen = ["tcp://0.0.0.0:0"]` means the router never accepts inbound peerings and
reaches the mesh purely through the relay, which is what you want behind CGNAT.

## OpenWrt / ImmortalWrt with Docker

```bash
docker run -d --name yggdrasil-ng --restart unless-stopped \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -e YGGDRASIL_PRIVATE_KEY=<hex> \
  -e YGG_PEERS="tls://peer.example.com:443" \
  -e CKR_ENABLE=true -e CKR_IP_ADDRESSES=10.99.0.1/24 \
  -e CKR_REMOTE_SUBNETS="<KEY_R>:10.99.0.2/32" \
  -e HOST_ROUTES="192.168.1.0/24:172.17.0.1" \
  ghcr.io/taubedonner/yggdrasil-ng-docker:latest
```

> **Do not combine `--network host` with `NAT_ENABLE=true` casually.** OpenWrt's fw4 owns the host's nftables ruleset; the container writes through the iptables-nft shim into the same tables. The entrypoint removes its own rules on shutdown, but a `docker kill` skips that. Prefer the bridge network plus a route, or add the TUN to a firewall zone and let fw4 do the NAT.

If you do use host networking, the TUN appears on the router and can be put in a zone the normal way (`/etc/config/firewall`, `option device 'ygg0'`).

## Building

CI compiles the daemon from upstream source with [cross-rs](https://github.com/cross-rs/cross) and assembles images from the resulting static musl binaries, so no emulation is involved. The upstream tag is pinned by `YGG_VERSION` and can be overridden per run via workflow dispatch – it is deliberately not taken from this repository's own tag, since the two version lines are independent.

| Asset | Target | Image platform |
|---|---|---|
| `yggdrasil-x86_64-linux-gnu` | `x86_64-unknown-linux-gnu` | – |
| `yggdrasil-x86_64-linux-musl` | `x86_64-unknown-linux-musl` | `linux/amd64` |
| `yggdrasil-aarch64-linux-gnu` | `aarch64-unknown-linux-gnu` | – |
| `yggdrasil-aarch64-linux-musl` | `aarch64-unknown-linux-musl` | `linux/arm64` |
| `yggdrasil-armv7-linux-musleabihf` | `armv7-unknown-linux-musleabihf` | `linux/arm/v7` |

Upstream's `Cross.toml` also carries mips and mipsel targets for older OpenWrt hardware; they need `build-std` and are not built here by default.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Packets leave, nothing comes back | The far end has no `remote_subnets` entry for this node's tunnel address, so inbound is dropped by the source check |
| Small pings work, large transfers stall | MTU. Set `NAT_CLAMP_MSS=true`, or lower `YGG_MTU`, and let ICMPv6 Packet Too Big through |
| Node address changes on every restart | No `YGGDRASIL_PRIVATE_KEY` and no mounted config |
| `YGG_ADMIN_LISTEN` seems ignored | Fixed in this image; older versions only rewrote uncommented keys, and the template ships `admin_listen` commented out |
| Duplicate NAT or route entries after restarts | Fixed in this image; rules are now idempotent and cleaned up on shutdown |
| Peering drops when CKR is enabled | A CKR prefix swallowed the address used for peering. Exclude it with `!`, or use the `0.0.0.0/1` + `128.0.0.0/1` split |

## License

This repository contains only build tooling and container configuration. The Yggdrasil-ng daemon is licensed under [MPL-2.0](https://github.com/Revertron/Yggdrasil-ng/blob/master/LICENSE).
