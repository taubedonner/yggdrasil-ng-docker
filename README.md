# yggdrasil-ng-docker

Docker image for [Yggdrasil-ng](https://github.com/Revertron/Yggdrasil-ng) — a Rust rewrite of the Yggdrasil mesh networking daemon — compiled with **Crypto-Key Routing (CKR)** support. Targets `linux/amd64` and `linux/arm64`, based on Alpine Linux. Designed to run on resource-constrained devices such as MikroTik routers with the Container feature or OpenWRT devices with 64-bit CPU.

## How it works

The container runs a single `yggdrasil` binary that creates a TUN interface and connects to the Yggdrasil mesh over TCP/TLS. With CKR enabled, it additionally maps arbitrary IPv4/IPv6 subnets to remote node public keys, turning the mesh into a point-to-point VPN or site-to-site tunnel.

On startup the entrypoint script:

1. **Loads configuration** from `/config/yggdrasil.toml` if the volume is mounted. Otherwise generates an ephemeral config and patches it from environment variables.
2. **Enables IP forwarding** (`net.ipv4.ip_forward`, `net.ipv6.conf.all.forwarding`) required for CKR tunnel routing.
3. **Adds host routes** listed in `HOST_ROUTES` so the container can reach the local LAN through the bridge gateway.
4. **Configures NAT** via `iptables MASQUERADE` if `NAT_ENABLE=true` (exit-node scenario).
5. **Starts the daemon** with the resolved config file.

## Configuration

The recommended approach is to mount a `yggdrasil.toml` into `/config/`. The entrypoint uses it as-is and ignores all CKR- and YGG-related environment variables.

```bash
docker run -d \
  --cap-add NET_ADMIN \
  --cap-add SYS_ADMIN \
  --device /dev/net/tun \
  -v ./config:/config:ro \
  -p 1234:1234 \
  ghcr.io/taubedonner/yggdrasil-ng-docker:latest
```

If no config file is present, the daemon starts with an ephemeral key and the following variables are applied:

| Variable | Description | Default | Example |
|---|---|---|---|
| `YGGDRASIL_PRIVATE_KEY` | Hex Ed25519 private key (overrides config) | — | `0123...ef` |
| `YGG_PEERS` | Space-separated peer URIs | — | `tcp://1.2.3.4:443` |
| `YGG_LISTEN` | Listen address | — | `tcp://[::]:1234` |
| `YGG_ADMIN_LISTEN` | Admin socket address | — | `tcp://0.0.0.0:9001` |
| `CKR_ENABLE` | Enable Crypto-Key Routing | `false` | `true` |
| `CKR_IPV4_ADDRESS` | IPv4 address assigned to TUN (CIDR) | `10.99.0.1/24` | `10.0.0.1/24` |
| `CKR_YGGDRASIL_ROUTING` | Also route native `0200::/7` traffic | `true` | `false` |
| `CKR_REMOTE_SUBNETS` | Space-separated `pubkey:cidr1,cidr2` entries | — | see below |
| `HOST_ROUTES` | Space-separated `CIDR:gateway` routes to add | — | `192.168.88.0/24:172.17.0.1` |
| `NAT_ENABLE` | Enable IPv4 MASQUERADE (exit-node) | `false` | `true` |
| `NAT_SOURCE_CIDR` | Source subnet for NAT | `10.99.0.0/24` | `10.0.0.0/24` |
| `NAT_OUT_IFACE` | Outbound interface for NAT | `eth0` | `ens3` |

### CKR subnet format

`CKR_REMOTE_SUBNETS` takes a space-separated list of entries. Each entry is a node public key followed by a colon and a comma-separated list of CIDRs to route through that node:

```
CKR_REMOTE_SUBNETS="<pubkey_A>:10.99.0.2/32,10.0.0.0/24 <pubkey_B>:192.168.2.0/24"
```

This is equivalent to the following TOML in a mounted config file:

```toml
[tunnel_routing]
enable = true
ipv4_address = "10.99.0.1/24"

[tunnel_routing.remote_subnets]
"<pubkey_A>" = ["10.99.0.2/32", "10.0.0.0/24"]
"<pubkey_B>" = ["192.168.2.0/24"]
```

## Building

Binaries are compiled in CI via [cross-rs](https://github.com/cross-rs/cross) for all targets and attached as release assets. The Docker image is built with Buildx using pre-compiled binaries — no emulation is involved.

| Asset | Target |
|---|---|
| `yggdrasil-x86_64-linux-gnu` | `x86_64-unknown-linux-gnu` |
| `yggdrasil-x86_64-linux-musl` | `x86_64-unknown-linux-musl` |
| `yggdrasil-aarch64-linux-gnu` | `aarch64-unknown-linux-gnu` |
| `yggdrasil-aarch64-linux-musl` | `aarch64-unknown-linux-musl` |

## License

This repository contains only build tooling and container configuration. The Yggdrasil-ng daemon is licensed under [MPL-2.0](https://github.com/Revertron/Yggdrasil-ng/blob/master/LICENSE).