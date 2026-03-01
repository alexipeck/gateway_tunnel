#!/usr/bin/env bash
set -euo pipefail

ZT_NETWORK_ID="${ZT_NETWORK_ID:?ZT_NETWORK_ID is required}"
ZT_SUBNET="${ZT_SUBNET:-10.147.17.0/24}"
CORE_NODE_ZT_IP="${CORE_NODE_ZT_IP:-10.147.17.3}"
FORWARD_PORTS="${FORWARD_PORTS:-32400/tcp,2456/udp}"
RULE_REAPPLY_INTERVAL="${RULE_REAPPLY_INTERVAL:-30}"
CORE_NODE_WAIT_TIMEOUT="${CORE_NODE_WAIT_TIMEOUT:-300}"

log() {
  printf '[edge-zt-gw] %s\n' "$*"
}

get_default_iface() {
  ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1
}

ensure_rule() {
  local table="$1"
  shift
  if ! iptables -t "$table" -C "$@" 2>/dev/null; then
    iptables -t "$table" -A "$@"
  fi
}

parse_port_spec() {
  local spec="$1"
  local proto pair public_port target_port

  proto="${spec##*/}"
  pair="${spec%/*}"

  if [[ "$pair" == *":"* ]]; then
    public_port="${pair%%:*}"
    target_port="${pair##*:}"
  else
    public_port="$pair"
    target_port="$pair"
  fi

  printf '%s %s %s\n' "$public_port" "$target_port" "$proto"
}

zt_network_joined() {
  zerotier-cli listnetworks | awk -v nwid="$ZT_NETWORK_ID" '$3==nwid {found=1} END {exit(found?0:1)}'
}

zt_network_ok() {
  zerotier-cli listnetworks | awk -v nwid="$ZT_NETWORK_ID" '$3==nwid && $6=="OK" {ok=1} END {exit(ok?0:1)}'
}

get_zt_iface() {
  zerotier-cli listnetworks | awk -v nwid="$ZT_NETWORK_ID" '$3==nwid && $8 ~ /^zt/ {print $8; exit}'
}

start_zerotier() {
  mkdir -p /var/lib/zerotier-one
  chmod 700 /var/lib/zerotier-one

  zerotier-one -d

  for _ in $(seq 1 30); do
    if zerotier-cli info >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ! zerotier-cli info >/dev/null 2>&1; then
    log "zerotier-cli not ready"
    exit 1
  fi

  if ! zt_network_joined; then
    log "Joining ZeroTier network ${ZT_NETWORK_ID}"
    zerotier-cli join "$ZT_NETWORK_ID"
  fi
}

wait_for_zt_interface() {
  local timeout="${1:-300}"
  local start iface
  start="$(date +%s)"

  while true; do
    iface="$(get_zt_iface || true)"
    if zt_network_ok && [[ -n "$iface" ]] && ip -4 addr show dev "$iface" | grep -q 'inet '; then
      log "ZeroTier interface ready: ${iface}"
      return 0
    fi

    if (( $(date +%s) - start >= timeout )); then
      log "Timed out waiting for ZeroTier authorization/interface (network ${ZT_NETWORK_ID})"
      zerotier-cli listnetworks || true
      exit 1
    fi

    sleep 2
  done
}

wait_for_peer() {
  local timeout="${1:-300}"
  local start
  start="$(date +%s)"

  while true; do
    if ping -c1 -W1 "$CORE_NODE_ZT_IP" >/dev/null 2>&1; then
      log "Peer ${CORE_NODE_ZT_IP} reachable"
      return 0
    fi

    if (( $(date +%s) - start >= timeout )); then
      log "Timed out waiting for peer ${CORE_NODE_ZT_IP}"
      exit 1
    fi

    sleep 2
  done
}

apply_rules() {
  local ext_iface
  ext_iface="${EXT_IFACE:-$(get_default_iface)}"

  if [[ -z "$ext_iface" ]]; then
    log "Could not detect external interface"
    exit 1
  fi

  iptables -P FORWARD DROP

  ensure_rule nat POSTROUTING -o "$ext_iface" -s "$ZT_SUBNET" -j MASQUERADE

  ensure_rule filter FORWARD -i zt+ -o "$ext_iface" -s "$ZT_SUBNET" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
  ensure_rule filter FORWARD -i "$ext_iface" -o zt+ -d "$ZT_SUBNET" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  IFS=',' read -r -a entries <<< "$FORWARD_PORTS"
  for entry in "${entries[@]}"; do
    entry="${entry//[[:space:]]/}"
    [[ -z "$entry" ]] && continue

    read -r public_port target_port proto < <(parse_port_spec "$entry")
    if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
      log "Skipping invalid protocol in entry: $entry"
      continue
    fi

    ensure_rule nat PREROUTING -i "$ext_iface" -p "$proto" --dport "$public_port" -j DNAT --to-destination "${CORE_NODE_ZT_IP}:${target_port}"
    ensure_rule filter FORWARD -i "$ext_iface" -o zt+ -p "$proto" -d "$CORE_NODE_ZT_IP" --dport "$target_port" -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
    ensure_rule filter FORWARD -i zt+ -o "$ext_iface" -p "$proto" -s "$CORE_NODE_ZT_IP" --sport "$target_port" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  done

  log "iptables rules applied on external iface ${ext_iface}"
}

cleanup() {
  log "Shutting down"
  pkill zerotier-one >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

start_zerotier
wait_for_zt_interface "$CORE_NODE_WAIT_TIMEOUT"
wait_for_peer "$CORE_NODE_WAIT_TIMEOUT"
apply_rules

while true; do
  if ! zt_network_ok; then
    log "ZeroTier network not OK; rejoining ${ZT_NETWORK_ID}"
    zerotier-cli leave "$ZT_NETWORK_ID" >/dev/null 2>&1 || true
    zerotier-cli join "$ZT_NETWORK_ID" >/dev/null 2>&1 || true
    wait_for_zt_interface "$CORE_NODE_WAIT_TIMEOUT"
    wait_for_peer "$CORE_NODE_WAIT_TIMEOUT"
  fi

  apply_rules
  sleep "$RULE_REAPPLY_INTERVAL"
done
