#!/usr/bin/env bash
set -euo pipefail

ZT_NETWORK_ID="${ZT_NETWORK_ID:?ZT_NETWORK_ID is required}"
CORE_APP_IP="${CORE_APP_IP:?CORE_APP_IP is required}"
EDGE_NODE_ZT_IP="${EDGE_NODE_ZT_IP:-}"
FORWARD_PORTS="${FORWARD_PORTS:-32400/tcp,2456/udp}"
RULE_REAPPLY_INTERVAL="${RULE_REAPPLY_INTERVAL:-30}"
CORE_ZT_READY_TIMEOUT="${CORE_ZT_READY_TIMEOUT:-300}"

log() {
  printf '[core-zt-gw] %s\n' "$*"
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
  local proto pair public_port target_port ip_part

  if [[ "$spec" == *"@"* ]]; then
    ip_part="${spec##*@}"
    spec="${spec%@*}"
  else
    ip_part=""
  fi

  proto="${spec##*/}"
  pair="${spec%/*}"

  if [[ "$pair" == *":"* ]]; then
    public_port="${pair%%:*}"
    target_port="${pair##*:}"
  else
    public_port="$pair"
    target_port="$pair"
  fi

  printf '%s %s %s %s\n' "$public_port" "$target_port" "$proto" "$ip_part"
}

find_app_iface() {
  local first_ip
  first_ip="${CORE_APP_IP%%,*}"
  ip -4 route get "$first_ip" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit }}'
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
      if [[ -n "$EDGE_NODE_ZT_IP" ]]; then
        ip route del default 2>/dev/null || true
        ip route add default via "$EDGE_NODE_ZT_IP" dev "$iface"
        log "Default route via ${EDGE_NODE_ZT_IP} (outbound through edge)"
      fi
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

apply_rules() {
  local app_iface first_ip port_ip
  app_iface="${CORE_APP_IFACE:-$(find_app_iface)}"

  first_ip="${CORE_APP_IP%%,*}"
  if [[ "$first_ip" != "127.0.0.1" ]]; then
    app_iface="${CORE_APP_IFACE:-$(find_app_iface)}"
    if [[ -z "$app_iface" ]]; then
      log "Could not detect interface to CORE_APP_IP ${CORE_APP_IP}"
      exit 1
    fi
  else
    app_iface=""
  fi

  iptables -P FORWARD DROP

  IFS=',' read -r -a app_ips <<< "$CORE_APP_IP"
  for ip in "${app_ips[@]}"; do
    ip="${ip//[[:space:]]/}"
    [[ -z "$ip" ]] && continue
    ensure_rule nat POSTROUTING -o zt+ -s "${ip}/32" -j MASQUERADE
  done
  if [[ -n "$EDGE_NODE_ZT_IP" ]]; then
    ensure_rule nat POSTROUTING -o zt+ -j MASQUERADE
  fi

  if [[ -n "$app_iface" ]]; then
    IFS=',' read -r -a app_ips <<< "$CORE_APP_IP"
    for ip in "${app_ips[@]}"; do
      ip="${ip//[[:space:]]/}"
      [[ -z "$ip" ]] && continue
      ensure_rule filter FORWARD -i zt+ -o "$app_iface" -d "$ip" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      ensure_rule filter FORWARD -i "$app_iface" -o zt+ -s "$ip" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    done
  fi

  IFS=',' read -r -a entries <<< "$FORWARD_PORTS"
  for entry in "${entries[@]}"; do
    entry="${entry//[[:space:]]/}"
    [[ -z "$entry" ]] && continue

    read -r public_port target_port proto port_ip < <(parse_port_spec "$entry")
    if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
      log "Skipping invalid protocol in entry: $entry"
      continue
    fi

    port_ip="${port_ip:-$first_ip}"

    ensure_rule nat PREROUTING -i zt+ -p "$proto" --dport "$public_port" -j DNAT --to-destination "${port_ip}:${target_port}"
    if [[ -n "$app_iface" ]]; then
      ensure_rule filter FORWARD -i zt+ -o "$app_iface" -p "$proto" -d "$port_ip" --dport "$target_port" -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
      ensure_rule filter FORWARD -i "$app_iface" -o zt+ -p "$proto" -s "$port_ip" --sport "$target_port" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    else
      ensure_rule filter INPUT -i zt+ -p "$proto" -d "$port_ip" --dport "$target_port" -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
      ensure_rule filter OUTPUT -o zt+ -p "$proto" -s "$port_ip" --sport "$target_port" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    fi
  done

  log "iptables rules applied (CORE_APP_IFACE=${app_iface}, CORE_APP_IP=${CORE_APP_IP})"
}

cleanup() {
  log "Shutting down"
  pkill zerotier-one >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

start_zerotier
wait_for_zt_interface "$CORE_ZT_READY_TIMEOUT"
apply_rules

while true; do
  if ! zt_network_ok; then
    log "ZeroTier network not OK; rejoining ${ZT_NETWORK_ID}"
    zerotier-cli leave "$ZT_NETWORK_ID" >/dev/null 2>&1 || true
    zerotier-cli join "$ZT_NETWORK_ID" >/dev/null 2>&1 || true
    wait_for_zt_interface "$CORE_ZT_READY_TIMEOUT"
  fi

  apply_rules
  sleep "$RULE_REAPPLY_INTERVAL"
done
