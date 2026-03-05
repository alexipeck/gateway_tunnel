# ZeroTier Tunnel Gateway

Docker-only tunnel gateway using ZeroTier for transport and iptables for forwarding. No host-level routing, firewall, or VPN config required.

- Edge side: ZeroTier member + edge ingress DNAT + egress MASQUERADE
- Core side: ZeroTier member + DNAT from ZeroTier overlay to core app + MASQUERADE back to ZeroTier

## Assumptions

- Docker is installed on both machines.
- Containers run with `NET_ADMIN` and `/dev/net/tun` mapped.
- A ZeroTier network exists and both members are authorized.
- Example ZeroTier network ID: `8056c2e21c000001`.
- Example ZeroTier subnet: `10.147.17.0/24`.
- Example edge node ZeroTier IP: `10.147.17.2`.
- Example core node ZeroTier IP: `10.147.17.3`.
- Example forwarded ports: `32400/tcp`, `2456/udp`.
- Example app target: `CORE_APP_IP=172.18.0.10`.

## Network Diagram

```text
Internet Client
   |
   | tcp/udp PUBLIC_PORT
   v
[Edge node public IP]
   |
   | Edge node iptables DNAT (eth0 -> core node ZeroTier IP)
   v
[ZeroTier overlay: edge node <-> core node]
   |
   | Core iptables DNAT (zt+ -> CORE_APP_IP:APP_PORT)
   v
[Core app container CORE_APP_IP:APP_PORT]
```

Return path:

1. App sends reply to core gateway container.
2. Core gateway `POSTROUTING -o zt+ -s CORE_APP_IP/32 -j MASQUERADE` rewrites source for return through ZeroTier.
3. Edge gateway forwards to internet and applies `POSTROUTING -o eth0 -s ZT_SUBNET -j MASQUERADE`.

## Interface Matching (`zt+` wildcard)

ZeroTier interface names are dynamic (`ztXXXXXXXX`).

iptables rules use wildcard matching:

- `-i zt+`
- `-o zt+`

This avoids hardcoding the interface name while still restricting traffic to ZeroTier interfaces.

## ZeroTier Behavior

- ZeroTier handles encrypted transport, peer liveness, and overlay maintenance.
- Entry points wait for:
  - ZeroTier daemon readiness
  - network join
  - authorization/status `OK`
  - interface and address readiness
- Edge node additionally waits for core node ZeroTier IP reachability before applying forwarding rules.

## Configuration Interface

### Edge node (`edge/.env`)

- `ZT_NETWORK_ID=8056c2e21c000001`
- `ZT_SUBNET=10.147.17.0/24`
- `CORE_NODE_ZT_IP=10.147.17.3`
- `FORWARD_PORTS=32400/tcp,2456/udp`
- `EXT_IFACE=` (optional override)
- `RULE_REAPPLY_INTERVAL=30`
- `CORE_NODE_WAIT_TIMEOUT=300`

### Core node (`core/.env`)

- `ZT_NETWORK_ID=8056c2e21c000001`
- `CORE_APP_IP=` (required; comma-separated; use `127.0.0.1` when app shares core network)
- `EDGE_NODE_ZT_IP=` (optional; when set, routes outbound through edge)
- `CORE_APP_IFACE=` (optional override)
- `FORWARD_PORTS=32400/tcp,2456/udp`
- `APP_NETWORK_SUBNET=172.18.0.0/24`
- `GATEWAY_CONTAINER_IP=172.18.0.2`
- `RULE_REAPPLY_INTERVAL=30`
- `CORE_ZT_READY_TIMEOUT=300`

Port syntax on both sides:

- `FORWARD_PORTS=PUBLIC_PORT[:TARGET_PORT]/PROTO[@IP],...`
- `PROTO` is `tcp` or `udp`
- `@IP` per-port target when using multiple CORE_APP_IPs

Examples:

- `32400/tcp,2456/udp`
- `32400:32400/tcp,2456:2456/udp`
- `32400/tcp@172.18.0.10,8080/tcp@172.18.0.11`

## Bring Up

1. Authorize both nodes in ZeroTier Central after first join attempt.
2. Start Edge side:

```bash
cd edge
cp .env.example .env
docker compose up -d --build
```

3. Start Core side:

```bash
cd core
cp .env.example .env
docker compose up -d --build
```

### Unraid (Core)

Apps → search "ZeroTier Tunnel Gateway" → Install. Set `ZT_NETWORK_ID`, `CORE_APP_IP` (comma-separated for multiple), `FORWARD_PORTS`. Use `@IP` in FORWARD_PORTS for per-port targets. Authorize the node in ZeroTier Central, then restart.

To publish to Community Applications: create a support thread on the [Unraid forums](https://forums.unraid.net/), set the Support URL in `unraid/zt-core-gateway.xml` to that thread, then submit via the [CA form](https://form.asana.com/?k=qtIUrf5ydiXvXzPI57BiJw&d=714739274360802). The image is published to GHCR on push to main.

Note about edge ingress on VPS:

- `edge/docker-compose.yml` publishes example ports `32400/tcp` and `2456/udp`.
- If you add/remove forwarded edge ports, update both:
  - `FORWARD_PORTS` in `edge/.env` and `core/.env`
  - `ports:` section in `edge/docker-compose.yml`

## Verify

### ZeroTier status

Edge node:

```bash
docker exec -it zt-edge-gateway zerotier-cli info
docker exec -it zt-edge-gateway zerotier-cli listnetworks
docker exec -it zt-edge-gateway ip -br a
```

Core node:

```bash
docker exec -it zt-core-gateway zerotier-cli info
docker exec -it zt-core-gateway zerotier-cli listnetworks
docker exec -it zt-core-gateway ip -br a
```

### Routing and iptables

Edge node:

```bash
docker exec -it zt-edge-gateway ip route
docker exec -it zt-edge-gateway iptables -t nat -S
docker exec -it zt-edge-gateway iptables -S FORWARD
```

Core node:

```bash
docker exec -it zt-core-gateway ip route
docker exec -it zt-core-gateway iptables -t nat -S
docker exec -it zt-core-gateway iptables -S FORWARD
```

### Conntrack checks

Edge node:

```bash
docker exec -it zt-edge-gateway conntrack -L | grep -E 'dport=(32400|2456)|sport=(32400|2456)'
```

Core node:

```bash
docker exec -it zt-core-gateway conntrack -L | grep -E 'dport=(32400|2456)|sport=(32400|2456)'
```

### Inbound tests from internet

TCP:

```bash
nc -vz <EDGE_PUBLIC_IP> 32400
```

UDP:

```bash
printf 'ping' | nc -u -w2 <EDGE_PUBLIC_IP> 2456
```

### Outbound test from app namespace

If app shares gateway netns (`network_mode: service:zt-core-gateway`):

```bash
docker exec -it zt-core-gateway curl -4 https://ifconfig.me
docker exec -it zt-core-gateway ping -c 3 1.1.1.1
```

ICMP is only for egress validation; ingress forwarding is TCP/UDP port-specific.

## Security Notes

- Both containers set `FORWARD` policy to `DROP` (default deny).
- Only declared `FORWARD_PORTS` are allowed as new inbound forwarded flows.
- Return traffic uses conntrack (`ESTABLISHED,RELATED`).
- ZeroTier provides encrypted transport; iptables is the only forwarding/gateway policy layer.
- ZeroTier identities persist in mounted `./zerotier-one` directories.
