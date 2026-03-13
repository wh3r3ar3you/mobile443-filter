#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-install}"
INSTALL_PROFILE="${2:-full}"

BASE_DIR="/opt/mobile443"
STATE_DIR="/var/lib/mobile443"
BIN_DIR="/usr/local/sbin"
CONFIG_FILE="${BASE_DIR}/config.conf"
ASNS_FILE="${BASE_DIR}/asns.conf"

DEFAULT_PORTS="443"

TRAF_GUARD_BASE_URL_DEFAULT="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public"
GOV_LIST_URL_DEFAULT="${TRAF_GUARD_BASE_URL_DEFAULT}/government_networks.list"
ANTISCANNER_LIST_URL_DEFAULT="${TRAF_GUARD_BASE_URL_DEFAULT}/antiscanner.list"

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
  fi
}

log() {
  echo "[$(date '+%F %T')] $*"
}

default_ports_from_existing() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    if [[ -n "${PORTS:-}" ]]; then
      echo "$PORTS"
      return
    fi
  fi
  echo "$DEFAULT_PORTS"
}

detect_xray_log() {
  echo "🔍 Поиск access.log от xray/remnanode..."

  XRAY_ACCESS_LOG=""
  local -a candidates=(
    "/var/log/remnanode/access.log"
    "/var/log/remnanode/xray/access.log"
    "/var/lib/remnanode/access.log"
    "/var/lib/remnanode/xray/access.log"
    "/opt/remnanode/access.log"
    "/var/log/xray/access.log"
    "/usr/local/etc/xray/access.log"
  )

  for path in "${candidates[@]}"; do
    if [[ -f "$path" ]]; then
      XRAY_ACCESS_LOG="$path"
      echo "   ✅ Найден: $path"
      return
    fi
  done

  local found=""
  found=$(find / -maxdepth 5 \( -name "access.log" -o -name "access_log" \) \
    \( -path "*xray*" -o -path "*remna*" \) 2>/dev/null | head -5) || true

  if [[ -n "$found" ]]; then
    echo "   Найдены файлы:"
    echo "$found" | while IFS= read -r f; do
      echo "     - $f"
    done
    echo ""
    echo "   Введите путь или Enter для первого найденного:"
    read -r -p "   > " user_path < /dev/tty
    XRAY_ACCESS_LOG="${user_path:-$(echo "$found" | head -1)}"
    echo "   ✅ Используем: $XRAY_ACCESS_LOG"
    return
  fi

  echo "   ⚠️  Автоматически не найден."
  echo "   Введите полный путь к access.log xray:"
  read -r -p "   > " XRAY_ACCESS_LOG < /dev/tty
}

write_config() {
  local ports="$1"
  local enable_traf_guard="$2"
  local enable_traf_guard_government="$3"
  local enable_traf_guard_antiscanner="$4"
  local enable_mobile_allow="$5"
  local enable_telegram="$6"
  local tg_bot_token="$7"
  local tg_admin_id="$8"
  local xray_access_log="$9"
  local remnawave_api_url="${10}"
  local remnawave_api_token="${11}"
  local tg_id_source="${12}"

  mkdir -p "$BASE_DIR"

  cat > "$CONFIG_FILE" <<EOF
INSTALL_PROFILE="$INSTALL_PROFILE"
PORTS="$ports"
ENABLE_TRAF_GUARD="$enable_traf_guard"
ENABLE_TRAF_GUARD_GOVERNMENT="$enable_traf_guard_government"
ENABLE_TRAF_GUARD_ANTISCANNER="$enable_traf_guard_antiscanner"
ENABLE_MOBILE_ALLOW="$enable_mobile_allow"
ENABLE_TELEGRAM="$enable_telegram"
TG_ENABLED="$enable_telegram"
TG_BOT_TOKEN="$tg_bot_token"
TG_ADMIN_ID="$tg_admin_id"
XRAY_ACCESS_LOG="$xray_access_log"
REMNAWAVE_API_URL="$remnawave_api_url"
REMNAWAVE_API_TOKEN="$remnawave_api_token"
TG_ID_SOURCE="$tg_id_source"
TRAF_GUARD_BASE_URL="${TRAF_GUARD_BASE_URL_DEFAULT}"
GOV_LIST_URL="${GOV_LIST_URL_DEFAULT}"
ANTISCANNER_LIST_URL="${ANTISCANNER_LIST_URL_DEFAULT}"
EOF
  chmod 600 "$CONFIG_FILE"
}

interactive_setup_full() {
  local ports tg_choice enable_telegram tg_bot_token tg_admin_id
  local remnawave_api_url remnawave_api_token tg_id_source
  local xray_access_log

  echo ""
  echo "╔═══════════════════════════════════════════════╗"
  echo "║        Настройка mobile443 фильтра            ║"
  echo "╚═══════════════════════════════════════════════╝"
  echo ""

  echo "📡 На каких портах должен работать фильтр?"
  echo "   Введите порты через пробел"
  echo "   Пример: 443 8443 9443 10443 11443 12443 13443"
  read -r -p "   > " ports < /dev/tty
  ports="${ports:-$DEFAULT_PORTS}"
  echo "   ✅ Порты: $ports"
  echo ""

  echo "📱 Включить уведомления в Telegram? (y/n)"
  echo "   • Пользователям — уведомление при блокировке подключения"
  echo "   • Админу — ежедневная статистика блокировок"
  read -r -p "   > " tg_choice < /dev/tty

  if [[ "${tg_choice,,}" == "y" ]]; then
    enable_telegram="true"

    echo ""
    echo "🤖 Введите токен Telegram бота:"
    read -r -p "   > " tg_bot_token < /dev/tty
    echo ""
    echo "👤 Введите Telegram ID администратора (для статистики):"
    read -r -p "   > " tg_admin_id < /dev/tty
    echo ""

    echo "🌐 Введите адрес панели Remnawave (например: https://panel.example.com):"
    read -r -p "   > " remnawave_api_url < /dev/tty
    remnawave_api_url="${remnawave_api_url%/}"
    echo "   ✅ Панель: $remnawave_api_url"
    echo ""

    echo "🔑 Введите API токен Remnawave панели:"
    read -r -p "   > " remnawave_api_token < /dev/tty
    echo ""

    echo "📋 Откуда брать Telegram ID пользователя?"
    echo "   1) Из поля telegramId пользователя в API Remnawave"
    echo "   2) Из поля username — последнее значение после _"
    read -r -p "   Выберите (1 или 2): " tg_id_source_choice < /dev/tty

    if [[ "$tg_id_source_choice" == "2" ]]; then
      tg_id_source="username"
      echo "   ✅ Telegram ID будет извлекаться из username"
    else
      tg_id_source="telegramId"
      echo "   ✅ Telegram ID будет браться из поля telegramId"
    fi
    echo ""

    detect_xray_log
    xray_access_log="${XRAY_ACCESS_LOG:-}"
  else
    enable_telegram="false"
    tg_bot_token=""
    tg_admin_id=""
    xray_access_log=""
    remnawave_api_url=""
    remnawave_api_token=""
    tg_id_source=""
  fi

  write_config \
    "$ports" \
    "true" \
    "true" \
    "true" \
    "true" \
    "$enable_telegram" \
    "${tg_bot_token:-}" \
    "${tg_admin_id:-}" \
    "${xray_access_log:-}" \
    "${remnawave_api_url:-}" \
    "${remnawave_api_token:-}" \
    "${tg_id_source:-}"

  echo ""
  echo "💾 Конфигурация сохранена: $CONFIG_FILE"
  echo ""
}

setup_block_only() {
  local ports list_choice enable_government enable_antiscanner

  echo ""
  echo "╔═══════════════════════════════════════════════╗"
  echo "║      Настройка mobile443 block-only          ║"
  echo "╚═══════════════════════════════════════════════╝"
  echo ""

  echo "🛑 Какие traffic-guard листы включить?"
  echo "   1) Оба: government + antiscanner"
  echo "   2) Только government"
  echo "   3) Только antiscanner"
  read -r -p "   > " list_choice < /dev/tty

  case "$list_choice" in
    2)
      enable_government="true"
      enable_antiscanner="false"
      ;;
    3)
      enable_government="false"
      enable_antiscanner="true"
      ;;
    *)
      enable_government="true"
      enable_antiscanner="true"
      ;;
  esac

  echo ""
  echo "📡 На каких портах должен работать block-only фильтр?"
  echo "   Введите порты через пробел"
  echo "   Пример: 443 8443 9443"
  read -r -p "   > " ports < /dev/tty
  ports="${ports:-${PORTS:-$(default_ports_from_existing)}}"

  write_config \
    "$ports" \
    "true" \
    "$enable_government" \
    "$enable_antiscanner" \
    "false" \
    "false" \
    "" \
    "" \
    "" \
    "" \
    "" \
    ""

  echo "[*] block-only режим"
  echo "    Порты: $ports"
  echo "    Traffic Guard government: $enable_government"
  echo "    Traffic Guard antiscanner: $enable_antiscanner"
  echo "    Mobile allowlist: disabled"
  echo "    Telegram/Remnawave: disabled"
}

write_default_asns() {
  if [[ -s "$ASNS_FILE" ]]; then
    return
  fi

  cat > "$ASNS_FILE" <<'EOF'
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
202498
EOF
}

install_packages() {
  local -a packages=(curl ipset iptables util-linux ca-certificates)

  if [[ "$INSTALL_PROFILE" == "full" ]]; then
    packages+=(jq)
  fi

  apt update -y || true
  apt install -y "${packages[@]}"
}

reset_config_vars() {
  unset INSTALL_PROFILE PORTS ENABLE_TRAF_GUARD ENABLE_TRAF_GUARD_GOVERNMENT \
    ENABLE_TRAF_GUARD_ANTISCANNER ENABLE_MOBILE_ALLOW ENABLE_TELEGRAM TG_ENABLED \
    TG_BOT_TOKEN TG_ADMIN_ID XRAY_ACCESS_LOG REMNAWAVE_API_URL REMNAWAVE_API_TOKEN \
    TG_ID_SOURCE TRAF_GUARD_BASE_URL GOV_LIST_URL ANTISCANNER_LIST_URL
}

load_config_if_exists() {
  reset_config_vars
  if [[ -f "$1" ]]; then
    # shellcheck disable=SC1090
    source "$1"
    return 0
  fi
  return 1
}

runtime_install_from_config() {
  mkdir -p "$BASE_DIR" "$STATE_DIR" "$BIN_DIR"
  install_packages

  if [[ "$INSTALL_PROFILE" == "full" ]]; then
    write_default_asns
  fi

  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  write_runtime_scripts
  write_systemd_units
  enable_services

  echo "[*] Первичное обновление списков..."
  if ! systemctl start mobile443-update.service; then
    echo "[!] Онлайн-обновление не удалось, пробуем применить локальный кеш"
    systemctl start mobile443-apply.service || true
  fi

  print_install_status
}

normalize_restored_config() {
  local restored_config="$1"
  local restored_asns="$2"
  local target_profile="$3"
  local ports enable_traf_guard enable_gov enable_antiscanner enable_mobile_allow
  local enable_telegram tg_bot_token tg_admin_id xray_access_log remnawave_api_url
  local remnawave_api_token tg_id_source

  load_config_if_exists "$restored_config" || true

  ports="${PORTS:-$DEFAULT_PORTS}"
  enable_traf_guard="${ENABLE_TRAF_GUARD:-true}"
  enable_gov="${ENABLE_TRAF_GUARD_GOVERNMENT:-$enable_traf_guard}"
  enable_antiscanner="${ENABLE_TRAF_GUARD_ANTISCANNER:-$enable_traf_guard}"
  enable_mobile_allow="${ENABLE_MOBILE_ALLOW:-true}"
  enable_telegram="${ENABLE_TELEGRAM:-${TG_ENABLED:-false}}"
  tg_bot_token="${TG_BOT_TOKEN:-}"
  tg_admin_id="${TG_ADMIN_ID:-}"
  xray_access_log="${XRAY_ACCESS_LOG:-}"
  remnawave_api_url="${REMNAWAVE_API_URL:-}"
  remnawave_api_token="${REMNAWAVE_API_TOKEN:-}"
  tg_id_source="${TG_ID_SOURCE:-}"

  if [[ "$target_profile" == "block-only" ]]; then
    enable_traf_guard="true"
    enable_mobile_allow="false"
    enable_telegram="false"
    tg_bot_token=""
    tg_admin_id=""
    xray_access_log=""
    remnawave_api_url=""
    remnawave_api_token=""
    tg_id_source=""
  fi

  INSTALL_PROFILE="$target_profile"
  write_config \
    "$ports" \
    "$enable_traf_guard" \
    "$enable_gov" \
    "$enable_antiscanner" \
    "$enable_mobile_allow" \
    "$enable_telegram" \
    "$tg_bot_token" \
    "$tg_admin_id" \
    "$xray_access_log" \
    "$remnawave_api_url" \
    "$remnawave_api_token" \
    "$tg_id_source"

  if [[ "$target_profile" == "full" ]]; then
    if [[ -s "$restored_asns" ]]; then
      install -m 0644 "$restored_asns" "$ASNS_FILE"
    else
      write_default_asns
    fi
  fi
}

write_runtime_scripts() {
  cat > "${BIN_DIR}/mobile443-common.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/opt/mobile443/config.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

BASE_DIR="/opt/mobile443"
STATE_DIR="/var/lib/mobile443"
LISTS_DIR="${BASE_DIR}/lists"
ASNS_FILE="${BASE_DIR}/asns.conf"
ALLOW_CACHE_FILE="${STATE_DIR}/prefixes.txt"
LOCK_FILE="${STATE_DIR}/lock"

IPSET_ALLOW_NAME="allowed_mobile_443"
IPSET_ALLOW_TMP_NAME="${IPSET_ALLOW_NAME}_tmp"
IPSET_GOV_NAME="traf_guard_government"
IPSET_GOV_TMP_NAME="${IPSET_GOV_NAME}_tmp"
IPSET_ANTISCANNER_NAME="traf_guard_antiscanner"
IPSET_ANTISCANNER_TMP_NAME="${IPSET_ANTISCANNER_NAME}_tmp"

PRECHECK_CHAIN="TRAF_GUARD_PRECHECK"
CHAIN_NAME="FILTER_MOBILE_443"
LOG_PREFIX="MOBILE443_BLOCK: "
GOV_LOG_PREFIX="MOBILE443_TG_GOV: "
ANTISCANNER_LOG_PREFIX="MOBILE443_TG_SCAN: "

GOV_LIST_FILE="${LISTS_DIR}/government_networks.list"
ANTISCANNER_LIST_FILE="${LISTS_DIR}/antiscanner.list"

TRAF_GUARD_BASE_URL="${TRAF_GUARD_BASE_URL:-https://raw.githubusercontent.com/wh3r3ar3you/traffic-guard-lists/refs/heads/main/public}"
GOV_LIST_URL="${GOV_LIST_URL:-${TRAF_GUARD_BASE_URL}/government_networks.list}"
ANTISCANNER_LIST_URL="${ANTISCANNER_LIST_URL:-${TRAF_GUARD_BASE_URL}/antiscanner.list}"

ENABLE_TRAF_GUARD="${ENABLE_TRAF_GUARD:-true}"
ENABLE_TRAF_GUARD_GOVERNMENT="${ENABLE_TRAF_GUARD_GOVERNMENT:-true}"
ENABLE_TRAF_GUARD_ANTISCANNER="${ENABLE_TRAF_GUARD_ANTISCANNER:-true}"
ENABLE_MOBILE_ALLOW="${ENABLE_MOBILE_ALLOW:-true}"
ENABLE_TELEGRAM="${ENABLE_TELEGRAM:-${TG_ENABLED:-false}}"

read -r -a PORT_LIST <<< "${PORTS:-443}"

log() {
  echo "[$(date '+%F %T')] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

bool_is_true() {
  [[ "${1:-false}" == "true" ]]
}

ensure_deps() {
  need_cmd curl
  need_cmd ipset
  need_cmd iptables
  need_cmd flock
  if bool_is_true "$ENABLE_MOBILE_ALLOW"; then
    need_cmd jq
  fi
}

ensure_dirs() {
  mkdir -p "$BASE_DIR" "$STATE_DIR" "$LISTS_DIR"
}

ensure_set_pair() {
  local set_name="$1"
  local tmp_name="$2"
  ipset create "$set_name" hash:net family inet hashsize 65536 maxelem 524288 -exist
  ipset create "$tmp_name" hash:net family inet hashsize 65536 maxelem 524288 -exist
}

ensure_ipsets() {
  if bool_is_true "$ENABLE_TRAF_GUARD"; then
    if bool_is_true "$ENABLE_TRAF_GUARD_GOVERNMENT"; then
      ensure_set_pair "$IPSET_GOV_NAME" "$IPSET_GOV_TMP_NAME"
    fi
    if bool_is_true "$ENABLE_TRAF_GUARD_ANTISCANNER"; then
      ensure_set_pair "$IPSET_ANTISCANNER_NAME" "$IPSET_ANTISCANNER_TMP_NAME"
    fi
  fi
  if bool_is_true "$ENABLE_MOBILE_ALLOW"; then
    ensure_set_pair "$IPSET_ALLOW_NAME" "$IPSET_ALLOW_TMP_NAME"
  fi
}

destroy_set_if_exists() {
  ipset destroy "$1" 2>/dev/null || true
}

count_lines() {
  local file="$1"
  [[ -f "$file" ]] || {
    echo 0
    return
  }
  wc -l < "$file" | tr -d ' '
}

validate_ipv4_cidr() {
  local prefix="$1"
  local ip mask octet
  local IFS=.

  [[ "$prefix" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || return 1
  ip="${prefix%/*}"
  mask="${prefix#*/}"

  [[ "$mask" =~ ^[0-9]+$ ]] || return 1
  (( mask >= 0 && mask <= 32 )) || return 1

  for octet in $ip; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

download_and_validate_list() {
  local url="$1"
  local destination="$2"
  local label="$3"
  local raw_tmp clean_tmp line normalized valid_count old_count

  raw_tmp="$(mktemp)"
  clean_tmp="$(mktemp)"
  trap 'rm -f "$raw_tmp" "$clean_tmp"' RETURN

  log "Downloading ${label}: ${url}"
  curl -fsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 \
    "$url" -o "$raw_tmp"

  valid_count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    normalized="$(echo "$line" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$normalized" ]] || continue

    if validate_ipv4_cidr "$normalized"; then
      echo "$normalized" >> "$clean_tmp"
      valid_count=$(( valid_count + 1 ))
    else
      log "WARN ${label}: skip invalid entry '${normalized}'"
    fi
  done < "$raw_tmp"

  if (( valid_count == 0 )); then
    log "ERROR ${label}: no valid CIDR entries"
    return 1
  fi

  sort -Vu "$clean_tmp" -o "$clean_tmp"
  old_count="$(count_lines "$destination")"
  if (( old_count > 0 )); then
    local min_safe=$(( old_count * 70 / 100 ))
    if (( valid_count < min_safe )); then
      log "ERROR ${label}: too few entries after update (${valid_count} < ${min_safe})"
      return 1
    fi
  fi

  install -m 0644 "$clean_tmp" "$destination"
  log "${label} entries: ${valid_count}"
}

rebuild_ipset_from_file() {
  local target_set="$1"
  local tmp_set="$2"
  local file="$3"
  local label="$4"

  [[ -f "$file" ]] || {
    log "WARN ${label}: file not found: ${file}"
    return 1
  }

  ipset flush "$tmp_set"
  while IFS= read -r prefix || [[ -n "$prefix" ]]; do
    [[ -n "$prefix" ]] || continue
    ipset add "$tmp_set" "$prefix" -exist
  done < "$file"

  ipset swap "$tmp_set" "$target_set"
  ipset flush "$tmp_set"
  log "${label} loaded into ${target_set}"
}

delete_jump_if_exists() {
  local chain="$1"
  local proto="$2"
  local port="$3"

  while iptables -C "$chain" -p "$proto" --dport "$port" -j "$CHAIN_NAME" 2>/dev/null; do
    iptables -D "$chain" -p "$proto" --dport "$port" -j "$CHAIN_NAME"
  done
}

prepare_chains() {
  iptables -N "$PRECHECK_CHAIN" 2>/dev/null || true
  iptables -F "$PRECHECK_CHAIN"

  if bool_is_true "$ENABLE_TRAF_GUARD"; then
    if bool_is_true "$ENABLE_TRAF_GUARD_GOVERNMENT"; then
      iptables -A "$PRECHECK_CHAIN" -m set --match-set "$IPSET_GOV_NAME" src \
        -m limit --limit 30/min --limit-burst 10 \
        -j LOG --log-prefix "$GOV_LOG_PREFIX" --log-level 4
      iptables -A "$PRECHECK_CHAIN" -m set --match-set "$IPSET_GOV_NAME" src -j DROP
    fi
    if bool_is_true "$ENABLE_TRAF_GUARD_ANTISCANNER"; then
      iptables -A "$PRECHECK_CHAIN" -m set --match-set "$IPSET_ANTISCANNER_NAME" src \
        -m limit --limit 30/min --limit-burst 10 \
        -j LOG --log-prefix "$ANTISCANNER_LOG_PREFIX" --log-level 4
      iptables -A "$PRECHECK_CHAIN" -m set --match-set "$IPSET_ANTISCANNER_NAME" src -j DROP
    fi
  fi

  iptables -N "$CHAIN_NAME" 2>/dev/null || true
  iptables -F "$CHAIN_NAME"
  iptables -A "$CHAIN_NAME" -j "$PRECHECK_CHAIN"

  if bool_is_true "$ENABLE_MOBILE_ALLOW"; then
    iptables -A "$CHAIN_NAME" -m set --match-set "$IPSET_ALLOW_NAME" src -j ACCEPT
    iptables -A "$CHAIN_NAME" -m limit --limit 30/min --limit-burst 10 \
      -j LOG --log-prefix "$LOG_PREFIX" --log-level 4
    iptables -A "$CHAIN_NAME" -j DROP
  else
    iptables -A "$CHAIN_NAME" -j RETURN
  fi
}

attach_chain() {
  local chain port

  for port in "${PORT_LIST[@]}"; do
    for chain in INPUT FORWARD; do
      delete_jump_if_exists "$chain" tcp "$port"
      delete_jump_if_exists "$chain" udp "$port"
      iptables -I "$chain" 1 -p tcp --dport "$port" -j "$CHAIN_NAME"
      iptables -I "$chain" 1 -p udp --dport "$port" -j "$CHAIN_NAME"
    done

    if iptables -nL DOCKER-USER >/dev/null 2>&1; then
      delete_jump_if_exists DOCKER-USER tcp "$port"
      delete_jump_if_exists DOCKER-USER udp "$port"
      iptables -I DOCKER-USER 1 -p tcp --dport "$port" -j "$CHAIN_NAME"
      iptables -I DOCKER-USER 1 -p udp --dport "$port" -j "$CHAIN_NAME"
    fi
  done
}

apply_rules() {
  ensure_dirs
  ensure_ipsets
  prepare_chains
  attach_chain
}

send_tg() {
  local chat_id="$1"
  local text="$2"

  [[ -z "${TG_BOT_TOKEN:-}" ]] && return
  curl -sS --max-time 10 \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${chat_id}" \
    -d "text=${text}" \
    -d "parse_mode=HTML" >/dev/null 2>&1 || true
}
EOF
  chmod +x "${BIN_DIR}/mobile443-common.sh"

  cat > "${BIN_DIR}/mobile443-update.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/sbin/mobile443-common.sh

TMP_RAW=""
TMP_CLEAN=""

cleanup_tmp() {
  rm -f "${TMP_RAW:-}" "${TMP_CLEAN:-}"
}

update_mobile_allowlist() {
  local asn new_count old_count min_safe

  [[ -f "$ASNS_FILE" ]] || {
    echo "ASN file not found: $ASNS_FILE" >&2
    exit 1
  }

  TMP_RAW="$(mktemp)"
  TMP_CLEAN="$(mktemp)"
  trap cleanup_tmp EXIT

  log "Fetching announced prefixes from RIPEstat"

  while IFS= read -r asn || [[ -n "$asn" ]]; do
    [[ -z "$asn" || "$asn" =~ ^# ]] && continue
    log "Fetching AS${asn}"
    curl -fsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 \
      "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${asn}" \
      | jq -r '.data.prefixes[]?.prefix // empty' >> "$TMP_RAW" || true
  done < "$ASNS_FILE"

  sort -Vu "$TMP_RAW" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
    > "$TMP_CLEAN" || true

  new_count="$(count_lines "$TMP_CLEAN")"
  old_count="$(count_lines "$ALLOW_CACHE_FILE")"

  log "Collected mobile prefixes: new=${new_count}, old=${old_count}"

  if [[ "$new_count" -lt 500 ]]; then
    log "Refusing mobile allowlist update: too few prefixes"
    exit 1
  fi

  if [[ "$old_count" -gt 0 ]]; then
    min_safe=$(( old_count * 70 / 100 ))
    if [[ "$new_count" -lt "$min_safe" ]]; then
      log "Refusing mobile allowlist update: new prefix count dropped too much (need >= ${min_safe})"
      exit 1
    fi
  fi

  rebuild_ipset_from_file "$IPSET_ALLOW_NAME" "$IPSET_ALLOW_TMP_NAME" "$TMP_CLEAN" "mobile allowlist"
  install -m 0644 "$TMP_CLEAN" "$ALLOW_CACHE_FILE"
  cleanup_tmp
  trap - EXIT
}

mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || {
  log "Another mobile443 job is already running"
  exit 0
}

ensure_deps
ensure_dirs
ensure_ipsets

if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_GOVERNMENT"; then
  download_and_validate_list "$GOV_LIST_URL" "$GOV_LIST_FILE" "government_networks"
  rebuild_ipset_from_file "$IPSET_GOV_NAME" "$IPSET_GOV_TMP_NAME" "$GOV_LIST_FILE" "government_networks"
fi

if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_ANTISCANNER"; then
  download_and_validate_list "$ANTISCANNER_LIST_URL" "$ANTISCANNER_LIST_FILE" "antiscanner"
  rebuild_ipset_from_file "$IPSET_ANTISCANNER_NAME" "$IPSET_ANTISCANNER_TMP_NAME" "$ANTISCANNER_LIST_FILE" "antiscanner"
fi

if bool_is_true "$ENABLE_MOBILE_ALLOW"; then
  update_mobile_allowlist
fi

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
ensure_dirs
ensure_ipsets

if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_GOVERNMENT"; then
  rebuild_ipset_from_file "$IPSET_GOV_NAME" "$IPSET_GOV_TMP_NAME" "$GOV_LIST_FILE" "government_networks" || true
fi

if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_ANTISCANNER"; then
  rebuild_ipset_from_file "$IPSET_ANTISCANNER_NAME" "$IPSET_ANTISCANNER_TMP_NAME" "$ANTISCANNER_LIST_FILE" "antiscanner" || true
fi

if bool_is_true "$ENABLE_MOBILE_ALLOW"; then
  if [[ -s "$ALLOW_CACHE_FILE" ]]; then
    rebuild_ipset_from_file "$IPSET_ALLOW_NAME" "$IPSET_ALLOW_TMP_NAME" "$ALLOW_CACHE_FILE" "mobile allowlist"
  else
    log "WARN mobile allowlist cache not found: $ALLOW_CACHE_FILE"
  fi
fi

apply_rules
log "Cache applied"
EOF
  chmod +x "${BIN_DIR}/mobile443-apply-cache.sh"

  cat > "${BIN_DIR}/mobile443-monitor.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/sbin/mobile443-common.sh

NOTIFIED_FILE="${STATE_DIR}/notified.txt"
STATS_BLOCKED_FILE="${STATE_DIR}/stats_blocked.txt"
TG_ALERTS_FILE="${STATE_DIR}/tg_alerts.txt"
NOTIFY_COOLDOWN=21600
ADMIN_ALERT_COOLDOWN=1800

mkdir -p "$STATE_DIR"
touch "$NOTIFIED_FILE" "$STATS_BLOCKED_FILE" "$TG_ALERTS_FILE"

should_notify() {
  local key="$1"
  local now last_notified diff

  now=$(date +%s)
  last_notified=$(grep "^${key} " "$NOTIFIED_FILE" 2>/dev/null | tail -1 | awk '{print $2}') || true

  if [[ -z "$last_notified" ]]; then
    return 0
  fi

  diff=$(( now - last_notified ))
  [[ $diff -ge $NOTIFY_COOLDOWN ]]
}

mark_notified() {
  local key="$1"
  local now tmp_file

  now=$(date +%s)
  tmp_file="$(mktemp)"
  grep -v "^${key} " "$NOTIFIED_FILE" > "$tmp_file" 2>/dev/null || true
  echo "${key} ${now}" >> "$tmp_file"
  install -m 0644 "$tmp_file" "$NOTIFIED_FILE"
  rm -f "$tmp_file"
}

should_notify_admin_alert() {
  local key="$1"
  local now last_notified diff

  now=$(date +%s)
  last_notified=$(grep "^${key} " "$TG_ALERTS_FILE" 2>/dev/null | tail -1 | awk '{print $2}') || true

  if [[ -z "$last_notified" ]]; then
    return 0
  fi

  diff=$(( now - last_notified ))
  [[ $diff -ge $ADMIN_ALERT_COOLDOWN ]]
}

mark_admin_alert() {
  local key="$1"
  local now tmp_file

  now=$(date +%s)
  tmp_file="$(mktemp)"
  grep -v "^${key} " "$TG_ALERTS_FILE" > "$tmp_file" 2>/dev/null || true
  echo "${key} ${now}" >> "$tmp_file"
  install -m 0644 "$tmp_file" "$TG_ALERTS_FILE"
  rm -f "$tmp_file"
}

find_user_by_ip() {
  local ip="$1"
  [[ -z "${XRAY_ACCESS_LOG:-}" || ! -f "${XRAY_ACCESS_LOG:-}" ]] && return

  tail -n 50000 "$XRAY_ACCESS_LOG" 2>/dev/null \
    | grep -Fw "$ip" \
    | grep -oP 'email:\s*\K\S+' \
    | tail -1 || true
}

get_remnawave_user() {
  local user_id="$1"
  [[ -z "${REMNAWAVE_API_URL:-}" || -z "${REMNAWAVE_API_TOKEN:-}" ]] && return

  curl -sS --max-time 10 \
    -H "Authorization: Bearer ${REMNAWAVE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "${REMNAWAVE_API_URL}/api/users/by-id/${user_id}" 2>/dev/null || true
}

extract_tg_id() {
  local api_response="$1"
  local tg_id="" username=""

  if [[ "${TG_ID_SOURCE:-telegramId}" == "username" ]]; then
    username=$(echo "$api_response" | jq -r '.response.username // empty' 2>/dev/null)
    if [[ -n "$username" ]]; then
      tg_id=$(echo "$username" | rev | cut -d'_' -f1 | rev)
    fi
  else
    tg_id=$(echo "$api_response" | jq -r '.response.telegramId // empty' 2>/dev/null)
  fi

  echo "$tg_id"
}

process_blocked() {
  local src_ip="$1"
  local dst_port="$2"
  local now_ts email api_response has_response tg_id msg

  now_ts=$(date '+%F %T')
  echo "${now_ts} ${src_ip} ${dst_port}" >> "$STATS_BLOCKED_FILE"

  [[ "${ENABLE_TELEGRAM:-false}" == "true" ]] || return

  email=$(find_user_by_ip "$src_ip")
  if [[ -z "$email" ]]; then
    log "Blocked ${src_ip}:${dst_port} - user not found in xray logs"
    return
  fi

  api_response=$(get_remnawave_user "$email")
  if [[ -z "$api_response" ]]; then
    log "Blocked ${src_ip}:${dst_port} - failed to get user '${email}' from Remnawave API"
    return
  fi

  has_response=$(echo "$api_response" | jq -r '.response // empty' 2>/dev/null)
  if [[ -z "$has_response" || "$has_response" == "null" ]]; then
    log "Blocked ${src_ip}:${dst_port} - user '${email}' not found in Remnawave panel"
    return
  fi

  tg_id=$(extract_tg_id "$api_response")
  if [[ -z "$tg_id" || "$tg_id" == "null" ]]; then
    log "Blocked ${src_ip}:${dst_port} - user '${email}' has no telegram ID (source: ${TG_ID_SOURCE:-telegramId})"
    return
  fi

  if should_notify "$tg_id"; then
    msg="⚠️ <b>Внимание!</b>

Ваше подключение с IP <code>${src_ip}</code> было заблокировано.

Для подключения к VPN используйте <b>только мобильный интернет</b> (МТС, Билайн, МегаФон, Tele2, Ростелеком).

Подключения с домашнего интернета, VPN и прокси не допускаются."
    send_tg "$tg_id" "$msg"
    mark_notified "$tg_id"
    log "Notified tg:${tg_id} (${email}) about blocked IP ${src_ip}"
  else
    log "Blocked ${src_ip}:${dst_port} - tg:${tg_id} already notified recently"
  fi
}

process_traf_guard_alert() {
  local src_ip="$1"
  local dst_port="$2"
  local reason="$3"
  local key msg

  echo "$(date '+%F %T') ${src_ip} ${dst_port} ${reason}" >> "$STATS_BLOCKED_FILE"

  [[ "${ENABLE_TELEGRAM:-false}" == "true" ]] || return
  [[ -n "${TG_ADMIN_ID:-}" ]] || return

  key="${reason}_${src_ip}_${dst_port}"
  if ! should_notify_admin_alert "$key"; then
    log "Traffic Guard alert suppressed for ${src_ip}:${dst_port} (${reason})"
    return
  fi

  msg="🚨 <b>Traffic Guard alert</b>

Попытка подключения с IP <code>${src_ip}</code> к порту <code>${dst_port}</code>.

Причина блокировки: <b>${reason}</b>."

  send_tg "$TG_ADMIN_ID" "$msg"
  mark_admin_alert "$key"
  log "Traffic Guard alert sent for ${src_ip}:${dst_port} (${reason})"
}

get_log_stream() {
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -kf --no-pager 2>/dev/null
  elif [[ -f /var/log/kern.log ]]; then
    tail -F /var/log/kern.log
  elif [[ -f /var/log/syslog ]]; then
    tail -F /var/log/syslog
  else
    log "ERROR: Cannot find kernel log source"
    exit 1
  fi
}

log "Monitor started, watching for blocked connections..."

get_log_stream | while IFS= read -r line; do
  if [[ "$line" == *"$LOG_PREFIX"* || "$line" == *"$GOV_LOG_PREFIX"* || "$line" == *"$ANTISCANNER_LOG_PREFIX"* ]]; then
    src_ip=""
    dst_port=""
    reason=""

    if [[ "$line" =~ SRC=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
      src_ip="${BASH_REMATCH[1]}"
    fi

    if [[ "$line" =~ DPT=([0-9]+) ]]; then
      dst_port="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$src_ip" && -n "$dst_port" ]]; then
      if [[ "$line" == *"$GOV_LOG_PREFIX"* ]]; then
        reason="government_networks"
        process_traf_guard_alert "$src_ip" "$dst_port" "$reason"
      elif [[ "$line" == *"$ANTISCANNER_LOG_PREFIX"* ]]; then
        reason="antiscanner"
        process_traf_guard_alert "$src_ip" "$dst_port" "$reason"
      else
        process_blocked "$src_ip" "$dst_port"
      fi
    fi
  fi
done
EOF
  chmod +x "${BIN_DIR}/mobile443-monitor.sh"

  cat > "${BIN_DIR}/mobile443-stats.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/sbin/mobile443-common.sh

STATS_BLOCKED_FILE="${STATE_DIR}/stats_blocked.txt"

[[ "${ENABLE_TELEGRAM:-false}" == "true" ]] || exit 0
[[ -n "${TG_ADMIN_ID:-}" ]] || exit 0

total_blocked=0
unique_ips=0
top_ips=""

if [[ -f "$STATS_BLOCKED_FILE" && -s "$STATS_BLOCKED_FILE" ]]; then
  total_blocked=$(wc -l < "$STATS_BLOCKED_FILE" | tr -d ' ')
  unique_ips=$(awk '{print $3}' "$STATS_BLOCKED_FILE" | sort -u | wc -l | tr -d ' ')
  top_ips=$(awk '{print $3}' "$STATS_BLOCKED_FILE" | sort | uniq -c | sort -rn | head -10)
fi

allow_count=$(ipset list "$IPSET_ALLOW_NAME" 2>/dev/null | awk '/Number of entries/ {print $4}') || allow_count="N/A"
gov_count=$(ipset list "$IPSET_GOV_NAME" 2>/dev/null | awk '/Number of entries/ {print $4}') || gov_count="N/A"
antiscanner_count=$(ipset list "$IPSET_ANTISCANNER_NAME" 2>/dev/null | awk '/Number of entries/ {print $4}') || antiscanner_count="N/A"

msg="📊 <b>Статистика mobile443</b>
📅 Период: последние 24 часа

🚫 Заблокировано соединений: <b>${total_blocked}</b>
🌐 Уникальных заблокированных IP: <b>${unique_ips}</b>
📋 Mobile allowlist: <b>${allow_count}</b>
🛑 Traffic Guard government: <b>${gov_count}</b>
🛑 Traffic Guard antiscanner: <b>${antiscanner_count}</b>
🔌 Отслеживаемые порты: <b>${PORT_LIST[*]}</b>"

if [[ -n "$top_ips" ]]; then
  msg+="

🔝 <b>Топ заблокированных IP:</b>
<pre>${top_ips}</pre>"
fi

send_tg "$TG_ADMIN_ID" "$msg"

mv "$STATS_BLOCKED_FILE" "${STATS_BLOCKED_FILE}.prev" 2>/dev/null || true
touch "$STATS_BLOCKED_FILE"

log "Daily stats sent to admin (tg:${TG_ADMIN_ID})"
EOF
  chmod +x "${BIN_DIR}/mobile443-stats.sh"
}

write_systemd_units() {
  cat > /etc/systemd/system/mobile443-apply.service <<'EOF'
[Unit]
Description=Apply mobile443 sets and firewall rules from local cache
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
Description=Refresh mobile443 allowlists and traffic-guard blocklists
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
Description=Daily refresh of mobile443 data at 00:00 UTC

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true
Unit=mobile443-update.service

[Install]
WantedBy=timers.target
EOF

  if [[ "${ENABLE_TELEGRAM:-false}" == "true" ]]; then
    cat > /etc/systemd/system/mobile443-monitor.service <<'EOF'
[Unit]
Description=Monitor blocked connections and send Telegram notifications
After=network-online.target mobile443-apply.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/mobile443-monitor.sh
User=root
Group=root
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/mobile443-stats.service <<'EOF'
[Unit]
Description=Send daily mobile443 stats to Telegram admin
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mobile443-stats.sh
User=root
Group=root
EOF

    cat > /etc/systemd/system/mobile443-stats.timer <<'EOF'
[Unit]
Description=Daily mobile443 stats report at 09:00 UTC

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true
Unit=mobile443-stats.service

[Install]
WantedBy=timers.target
EOF
  fi
}

remove_optional_telegram_assets() {
  systemctl stop mobile443-monitor.service 2>/dev/null || true
  systemctl stop mobile443-stats.timer 2>/dev/null || true
  systemctl stop mobile443-stats.service 2>/dev/null || true
  systemctl disable mobile443-monitor.service 2>/dev/null || true
  systemctl disable mobile443-stats.timer 2>/dev/null || true
  rm -f /etc/systemd/system/mobile443-monitor.service
  rm -f /etc/systemd/system/mobile443-stats.service
  rm -f /etc/systemd/system/mobile443-stats.timer
  rm -f "${BIN_DIR}/mobile443-monitor.sh"
  rm -f "${BIN_DIR}/mobile443-stats.sh"
}

enable_services() {
  systemctl daemon-reload
  systemctl enable mobile443-apply.service
  systemctl enable --now mobile443-update.timer

  if [[ "${ENABLE_TELEGRAM:-false}" == "true" ]]; then
    systemctl enable --now mobile443-monitor.service
    systemctl enable --now mobile443-stats.timer
  else
    remove_optional_telegram_assets
    systemctl daemon-reload
  fi
}

print_install_status() {
  echo ""
  echo "╔═══════════════════════════════════════════════╗"
  echo "║            ✅  Установлено!                   ║"
  echo "╚═══════════════════════════════════════════════╝"
  echo ""
  echo "  Проверка статуса:"
  echo "    systemctl status mobile443-update.service --no-pager"
  echo "    systemctl status mobile443-update.timer --no-pager"
  echo "    systemctl status mobile443-apply.service --no-pager"
  echo ""
  echo "  Проверка правил:"
  echo "    iptables -L TRAF_GUARD_PRECHECK -n -v --line-numbers"
  echo "    iptables -L FILTER_MOBILE_443 -n -v --line-numbers"
  echo "    ipset list traf_guard_government | head -20"
  echo "    ipset list traf_guard_antiscanner | head -20"
  echo "    ipset list allowed_mobile_443 | head -20"

  if [[ "${ENABLE_TELEGRAM:-false}" == "true" ]]; then
    echo ""
    echo "  Telegram мониторинг:"
    echo "    systemctl status mobile443-monitor.service --no-pager"
    echo "    systemctl status mobile443-stats.timer --no-pager"
  fi

  echo ""
}

install_all() {
  require_root

  if [[ "$INSTALL_PROFILE" == "block-only" ]]; then
    setup_block_only
  else
    interactive_setup_full
    write_default_asns
  fi

  runtime_install_from_config
}

remove_all() {
  require_root

  local -a remove_ports=(443)
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    read -r -a remove_ports <<< "${PORTS:-443}"
  fi

  echo "[*] Остановка и отключение сервисов"
  systemctl stop mobile443-monitor.service 2>/dev/null || true
  systemctl stop mobile443-stats.timer 2>/dev/null || true
  systemctl stop mobile443-stats.service 2>/dev/null || true
  systemctl stop mobile443-update.timer 2>/dev/null || true
  systemctl stop mobile443-update.service 2>/dev/null || true
  systemctl stop mobile443-apply.service 2>/dev/null || true

  systemctl disable mobile443-monitor.service 2>/dev/null || true
  systemctl disable mobile443-stats.timer 2>/dev/null || true
  systemctl disable mobile443-update.timer 2>/dev/null || true
  systemctl disable mobile443-apply.service 2>/dev/null || true

  echo "[*] Удаление правил iptables"
  for chain in INPUT FORWARD DOCKER-USER; do
    for proto in tcp udp; do
      for port in "${remove_ports[@]}"; do
        while iptables -C "$chain" -p "$proto" --dport "$port" -j FILTER_MOBILE_443 2>/dev/null; do
          iptables -D "$chain" -p "$proto" --dport "$port" -j FILTER_MOBILE_443 || true
        done
      done
    done
  done

  iptables -F FILTER_MOBILE_443 2>/dev/null || true
  iptables -X FILTER_MOBILE_443 2>/dev/null || true
  iptables -F TRAF_GUARD_PRECHECK 2>/dev/null || true
  iptables -X TRAF_GUARD_PRECHECK 2>/dev/null || true

  echo "[*] Удаление ipset"
  ipset destroy allowed_mobile_443_tmp 2>/dev/null || true
  ipset destroy allowed_mobile_443 2>/dev/null || true
  ipset destroy traf_guard_government_tmp 2>/dev/null || true
  ipset destroy traf_guard_government 2>/dev/null || true
  ipset destroy traf_guard_antiscanner_tmp 2>/dev/null || true
  ipset destroy traf_guard_antiscanner 2>/dev/null || true

  echo "[*] Удаление systemd юнитов"
  rm -f /etc/systemd/system/mobile443-apply.service
  rm -f /etc/systemd/system/mobile443-update.service
  rm -f /etc/systemd/system/mobile443-update.timer
  rm -f /etc/systemd/system/mobile443-monitor.service
  rm -f /etc/systemd/system/mobile443-stats.service
  rm -f /etc/systemd/system/mobile443-stats.timer
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true

  echo "[*] Удаление скриптов и конфигурации"
  rm -f "${BIN_DIR}/mobile443-common.sh"
  rm -f "${BIN_DIR}/mobile443-update.sh"
  rm -f "${BIN_DIR}/mobile443-apply-cache.sh"
  rm -f "${BIN_DIR}/mobile443-monitor.sh"
  rm -f "${BIN_DIR}/mobile443-stats.sh"
  rm -rf "$BASE_DIR"
  rm -rf "$STATE_DIR"

  echo ""
  echo "[+] Удалено."
}

update_all() {
  require_root

  local backup_dir backup_config backup_asns target_profile existing_profile requested_profile
  requested_profile="$INSTALL_PROFILE"
  backup_dir="$(mktemp -d)"
  backup_config="${backup_dir}/config.conf"
  backup_asns="${backup_dir}/asns.conf"

  if [[ -f "$CONFIG_FILE" ]]; then
    install -m 0600 "$CONFIG_FILE" "$backup_config"
  fi
  if [[ -f "$ASNS_FILE" ]]; then
    install -m 0644 "$ASNS_FILE" "$backup_asns"
  fi

  if [[ ! -f "$backup_config" ]]; then
    echo "[*] Текущая установка не найдена, запускаем обычную установку"
    INSTALL_PROFILE="$requested_profile"
    install_all
    rm -rf "$backup_dir"
    return
  fi

  load_config_if_exists "$backup_config" || true
  existing_profile="${INSTALL_PROFILE:-}"

  if [[ -n "$existing_profile" ]]; then
    target_profile="$existing_profile"
  else
    target_profile="$requested_profile"
    if [[ "${ENABLE_MOBILE_ALLOW:-true}" == "false" && "${ENABLE_TRAF_GUARD:-false}" == "true" ]]; then
      target_profile="block-only"
    fi
  fi

  echo "[*] Обновление mobile443"
  echo "    Профиль: $target_profile"
  echo "    Подход: backup config -> remove -> reinstall"

  remove_all
  normalize_restored_config "$backup_config" "$backup_asns" "$target_profile"
  runtime_install_from_config

  rm -rf "$backup_dir"
}

case "$ACTION" in
  install)
    install_all
    ;;
  update)
    update_all
    ;;
  remove)
    remove_all
    ;;
  *)
    echo "Использование: $0 [install|update|remove] [full|block-only]" >&2
    exit 1
    ;;
esac
