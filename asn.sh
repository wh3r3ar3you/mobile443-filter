#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-install}"

BASE_DIR="/opt/mobile443"
STATE_DIR="/var/lib/mobile443"
BIN_DIR="/usr/local/sbin"

install_all() {
  mkdir -p "$BASE_DIR" "$STATE_DIR" "$BIN_DIR"

  apt update -y
  apt install -y curl jq ipset iptables util-linux

  cat > "${BASE_DIR}/asns.conf" <<'EOF'
# === Mobile-focused allowlist for Russia ===
# ВАЖНО:
# Это не "идеально только мобильные".
# Это "основные мобильные сети + важные MVNO-пути + Ростелеком".
# Добавление Ростелекома расширяет allowlist и для части fixed broadband.

# MTS
8359

# Beeline / VimpelCom
3216
16345
# MegaFon core + related
31133
8263
6854
50928
48615
47395
47218
43841
42891
41976
35298
34552
31268
31224
31213
31208
31205
31195
31163
29648
25290
25159
24866
20663
20632
12396
202804

# T2 regional
12958
15378
42437
48092
48190
41330

# Miranda
201776

# Sberbank-Telecom
206673

# Rostelecom
12389
# T-mobile + Alfa-mobile
205638
214257
EOF

  cat > "${BIN_DIR}/mobile443-common.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

IPSET_NAME="allowed_mobile_443"
TMPSET_NAME="${IPSET_NAME}_tmp"
CHAIN_NAME="FILTER_MOBILE_443"

BASE_DIR="/opt/mobile443"
STATE_DIR="/var/lib/mobile443"
ASNS_FILE="${BASE_DIR}/asns.conf"
CACHE_FILE="${STATE_DIR}/prefixes.txt"
LOCK_FILE="${STATE_DIR}/lock"

log() {
  echo "[$(date '+%F %T')] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

ensure_deps() {
  need_cmd curl
  need_cmd jq
  need_cmd ipset
  need_cmd iptables
  need_cmd flock
}

ensure_ipsets() {
  ipset create "$IPSET_NAME" hash:net family inet hashsize 65536 maxelem 524288 -exist
  ipset create "$TMPSET_NAME" hash:net family inet hashsize 65536 maxelem 524288 -exist
}

count_lines() {
  local file="$1"
  [[ -f "$file" ]] || { echo 0; return; }
  wc -l < "$file" | tr -d ' '
}

load_prefixes_into_tmpset() {
  local file="$1"
  ipset flush "$TMPSET_NAME"

  while IFS= read -r prefix; do
    [[ -n "$prefix" ]] || continue
    ipset add "$TMPSET_NAME" "$prefix" -exist
  done < "$file"
}

swap_sets() {
  ipset swap "$TMPSET_NAME" "$IPSET_NAME"
  ipset flush "$TMPSET_NAME"
}

prepare_chain() {
  iptables -N "$CHAIN_NAME" 2>/dev/null || true
  iptables -F "$CHAIN_NAME"

  iptables -A "$CHAIN_NAME" -m set --match-set "$IPSET_NAME" src -j ACCEPT
  iptables -A "$CHAIN_NAME" -j DROP
}

delete_jump_if_exists() {
  local chain="$1"
  local proto="$2"
  while iptables -C "$chain" -p "$proto" --dport 443 -j "$CHAIN_NAME" 2>/dev/null; do
    iptables -D "$chain" -p "$proto" --dport 443 -j "$CHAIN_NAME"
  done
}

attach_chain() {
  for chain in INPUT FORWARD; do
    delete_jump_if_exists "$chain" tcp
    delete_jump_if_exists "$chain" udp
    iptables -I "$chain" 1 -p tcp --dport 443 -j "$CHAIN_NAME"
    iptables -I "$chain" 1 -p udp --dport 443 -j "$CHAIN_NAME"
  done

  if iptables -nL DOCKER-USER >/dev/null 2>&1; then
    delete_jump_if_exists DOCKER-USER tcp
    delete_jump_if_exists DOCKER-USER udp
    iptables -I DOCKER-USER 1 -p tcp --dport 443 -j "$CHAIN_NAME"
    iptables -I DOCKER-USER 1 -p udp --dport 443 -j "$CHAIN_NAME"
  fi
}

apply_rules() {
  ensure_ipsets
  prepare_chain
  attach_chain
}
EOF
  chmod +x "${BIN_DIR}/mobile443-common.sh"

  cat > "${BIN_DIR}/mobile443-update.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/sbin/mobile443-common.sh

TMP_RAW="$(mktemp)"
TMP_CLEAN="$(mktemp)"
trap 'rm -f "$TMP_RAW" "$TMP_CLEAN"' EXIT

mkdir -p "$STATE_DIR"

exec 9>"$LOCK_FILE"
flock -n 9 || {
  log "Another mobile443 job is already running"
  exit 0
}

ensure_deps
ensure_ipsets

[[ -f "$ASNS_FILE" ]] || { echo "ASN file not found: $ASNS_FILE" >&2; exit 1; }

log "Fetching announced prefixes from RIPEstat"

while IFS= read -r asn; do
  [[ -z "$asn" || "$asn" =~ ^# ]] && continue
  log "Fetching AS${asn}"
  curl -fsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 \
    "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${asn}" \
    | jq -r '.data.prefixes[]?.prefix // empty' >> "$TMP_RAW" || true
done < "$ASNS_FILE"

sort -Vu "$TMP_RAW" \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
  > "$TMP_CLEAN" || true

NEW_COUNT="$(count_lines "$TMP_CLEAN")"
OLD_COUNT="$(count_lines "$CACHE_FILE")"

log "Collected prefixes: new=${NEW_COUNT}, old=${OLD_COUNT}"

if [[ "$NEW_COUNT" -lt 500 ]]; then
  log "Refusing update: too few prefixes"
  exit 1
fi

if [[ "$OLD_COUNT" -gt 0 ]]; then
  MIN_SAFE=$(( OLD_COUNT * 70 / 100 ))
  if [[ "$NEW_COUNT" -lt "$MIN_SAFE" ]]; then
    log "Refusing update: new prefix count dropped too much (need >= ${MIN_SAFE})"
    exit 1
  fi
fi

load_prefixes_into_tmpset "$TMP_CLEAN"
swap_sets
cp "$TMP_CLEAN" "$CACHE_FILE"

apply_rules

log "Update complete"
EOF
  chmod +x "${BIN_DIR}/mobile443-update.sh"

  cat > "${BIN_DIR}/mobile443-apply-cache.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/sbin/mobile443-common.sh

mkdir -p "$STATE_DIR"

exec 9>"$LOCK_FILE"
flock -n 9 || {
  log "Another mobile443 job is already running"
  exit 0
}

ensure_deps
ensure_ipsets

if [[ ! -s "$CACHE_FILE" ]]; then
  log "Cache file not found or empty: $CACHE_FILE"
  apply_rules
  exit 0
fi

log "Loading cached prefixes from $CACHE_FILE"
load_prefixes_into_tmpset "$CACHE_FILE"
swap_sets
apply_rules
log "Cache applied"
EOF
  chmod +x "${BIN_DIR}/mobile443-apply-cache.sh"

  cat > /etc/systemd/system/mobile443-apply.service <<'EOF'
[Unit]
Description=Apply mobile 443 filter from cached prefixes
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mobile443-apply-cache.sh
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/mobile443-update.service <<'EOF'
[Unit]
Description=Refresh mobile 443 allowlist from RIPEstat
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mobile443-update.sh
User=root
Group=root
EOF

  cat > /etc/systemd/system/mobile443-update.timer <<'EOF'
[Unit]
Description=Daily refresh of mobile 443 allowlist at 00:00

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true
Unit=mobile443-update.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable mobile443-apply.service
  systemctl enable --now mobile443-update.timer

  if ! systemctl start mobile443-update.service; then
    echo "[!] First online update failed, applying cache"
    systemctl start mobile443-apply.service || true
  fi

  echo
  echo "[+] Installed."
  echo "[+] Check status:"
  echo "systemctl status mobile443-update.service --no-pager"
  echo "systemctl status mobile443-update.timer --no-pager"
  echo "systemctl status mobile443-apply.service --no-pager"
  echo
  echo "[+] Check rules:"
  echo "ipset list allowed_mobile_443 | head -30"
  echo "iptables -L FILTER_MOBILE_443 -n -v --line-numbers"
}

remove_all() {
  echo "[*] Stopping and disabling services"
  systemctl stop mobile443-update.timer 2>/dev/null || true
  systemctl stop mobile443-update.service 2>/dev/null || true
  systemctl stop mobile443-apply.service 2>/dev/null || true

  systemctl disable mobile443-update.timer 2>/dev/null || true
  systemctl disable mobile443-apply.service 2>/dev/null || true

  echo "[*] Removing iptables rules"
  for chain in INPUT FORWARD DOCKER-USER; do
    for proto in tcp udp; do
      while iptables -C "$chain" -p "$proto" --dport 443 -j FILTER_MOBILE_443 2>/dev/null; do
        iptables -D "$chain" -p "$proto" --dport 443 -j FILTER_MOBILE_443 || true
      done
    done
  done

  iptables -F FILTER_MOBILE_443 2>/dev/null || true
  iptables -X FILTER_MOBILE_443 2>/dev/null || true

  echo "[*] Removing ipset"
  ipset destroy allowed_mobile_443_tmp 2>/dev/null || true
  ipset destroy allowed_mobile_443 2>/dev/null || true

  echo "[*] Removing systemd units"
  rm -f /etc/systemd/system/mobile443-apply.service
  rm -f /etc/systemd/system/mobile443-update.service
  rm -f /etc/systemd/system/mobile443-update.timer
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true

  echo "[*] Removing scripts and config"
  rm -f "${BIN_DIR}/mobile443-common.sh"
  rm -f "${BIN_DIR}/mobile443-update.sh"
  rm -f "${BIN_DIR}/mobile443-apply-cache.sh"
  rm -rf "$BASE_DIR"
  rm -rf "$STATE_DIR"

  echo
  echo "[+] Removed."
}

case "$ACTION" in
  install)
    install_all
    ;;
  remove)
    remove_all
    ;;
  *)
    echo "Usage: $0 [install|remove]"
    exit 1
    ;;
esac
