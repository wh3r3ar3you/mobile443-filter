#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-install}"

BASE_DIR="/opt/mobile443"
STATE_DIR="/var/lib/mobile443"
BIN_DIR="/usr/local/sbin"
CONFIG_FILE="${BASE_DIR}/config.conf"

# ═══════════════════════════════════════════════
#  Interactive Setup
# ═══════════════════════════════════════════════

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
    echo "$found" | while IFS= read -r f; do echo "     - $f"; done
    echo ""
    echo "   Введите путь или Enter для первого найденного:"
    read -rp "   > " user_path < /dev/tty
    XRAY_ACCESS_LOG="${user_path:-$(echo "$found" | head -1)}"
    echo "   ✅ Используем: $XRAY_ACCESS_LOG"
    return
  fi

  echo "   ⚠️  Автоматически не найден."
  echo "   Введите полный путь к access.log xray:"
  read -rp "   > " XRAY_ACCESS_LOG < /dev/tty
}

interactive_setup() {
  echo ""
  echo "╔═══════════════════════════════════════════════╗"
  echo "║        Настройка mobile443 фильтра            ║"
  echo "╚═══════════════════════════════════════════════╝"
  echo ""

  # 1. Порты
  echo "📡 На каких портах должен работать фильтр?"
  echo "   Введите порты через пробел"
  echo "   Пример: 443 8443 9443 10443 11443 12443 13443"
  read -rp "   > " input_ports < /dev/tty
  PORTS="${input_ports:-443}"
  echo "   ✅ Порты: $PORTS"
  echo ""

  # 2. Telegram
  echo "📱 Включить уведомления в Telegram? (y/n)"
  echo "   • Пользователям — уведомление при блокировке подключения"
  echo "   • Админу — ежедневная статистика блокировок"
  read -rp "   > " tg_choice < /dev/tty

  if [[ "${tg_choice,,}" == "y" ]]; then
    TG_ENABLED="true"
    echo ""
    echo "🤖 Введите токен Telegram бота:"
    read -rp "   > " TG_BOT_TOKEN < /dev/tty
    echo ""
    echo "👤 Введите Telegram ID администратора (для статистики):"
    read -rp "   > " TG_ADMIN_ID < /dev/tty
    echo ""

    echo "🌐 Введите адрес панели Remnawave (например: https://panel.example.com):"
    read -rp "   > " REMNAWAVE_API_URL < /dev/tty
    # Убираем trailing slash
    REMNAWAVE_API_URL="${REMNAWAVE_API_URL%/}"
    echo "   ✅ Панель: $REMNAWAVE_API_URL"
    echo ""

    echo "🔑 Введите API токен Remnawave панели:"
    read -rp "   > " REMNAWAVE_API_TOKEN < /dev/tty
    echo ""

    echo "📋 Откуда брать Telegram ID пользователя?"
    echo "   1) Из поля telegramId пользователя в API Remnawave"
    echo "   2) Из поля username — последнее значение после _ (нижнего подчёркивания)"
    read -rp "   Выберите (1 или 2): " tg_id_source_choice < /dev/tty

    if [[ "$tg_id_source_choice" == "2" ]]; then
      TG_ID_SOURCE="username"
      echo "   ✅ Telegram ID будет извлекаться из username (после последнего _)"
    else
      TG_ID_SOURCE="telegramId"
      echo "   ✅ Telegram ID будет браться из поля telegramId"
    fi
    echo ""

    detect_xray_log
  else
    TG_ENABLED="false"
    TG_BOT_TOKEN=""
    TG_ADMIN_ID=""
    XRAY_ACCESS_LOG=""
    REMNAWAVE_API_URL=""
    REMNAWAVE_API_TOKEN=""
    TG_ID_SOURCE=""
  fi

  mkdir -p "$BASE_DIR"
  cat > "$CONFIG_FILE" <<CONF
PORTS="$PORTS"
TG_ENABLED="$TG_ENABLED"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_ADMIN_ID="$TG_ADMIN_ID"
XRAY_ACCESS_LOG="$XRAY_ACCESS_LOG"
REMNAWAVE_API_URL="$REMNAWAVE_API_URL"
REMNAWAVE_API_TOKEN="$REMNAWAVE_API_TOKEN"
TG_ID_SOURCE="$TG_ID_SOURCE"
CONF
  chmod 600 "$CONFIG_FILE"

  echo ""
  echo "💾 Конфигурация сохранена: $CONFIG_FILE"
  echo ""
}

# ═══════════════════════════════════════════════
#  Install
# ═══════════════════════════════════════════════

install_all() {
  interactive_setup

  mkdir -p "$BASE_DIR" "$STATE_DIR" "$BIN_DIR"

  apt update -y || true
  apt install -y curl jq ipset iptables util-linux

  source "$CONFIG_FILE"

  # ─── ASNs config ───
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
EOF

  # ─── common.sh ───
  cat > "${BIN_DIR}/mobile443-common.sh" <<'COMMONEOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/opt/mobile443/config.conf"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Read ports from config into array
read -ra PORT_LIST <<< "${PORTS:-443}"

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
  iptables -A "$CHAIN_NAME" -m limit --limit 30/min --limit-burst 10 \
    -j LOG --log-prefix "MOBILE443_BLOCK: " --log-level 4
  iptables -A "$CHAIN_NAME" -j DROP
}

delete_jump_if_exists() {
  local chain="$1" proto="$2" port="$3"
  while iptables -C "$chain" -p "$proto" --dport "$port" -j "$CHAIN_NAME" 2>/dev/null; do
    iptables -D "$chain" -p "$proto" --dport "$port" -j "$CHAIN_NAME"
  done
}

attach_chain() {
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
  ensure_ipsets
  prepare_chain
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
COMMONEOF
  chmod +x "${BIN_DIR}/mobile443-common.sh"

  # ─── update.sh ───
  cat > "${BIN_DIR}/mobile443-update.sh" <<'UPDATEEOF'
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
UPDATEEOF
  chmod +x "${BIN_DIR}/mobile443-update.sh"

  # ─── apply-cache.sh ───
  cat > "${BIN_DIR}/mobile443-apply-cache.sh" <<'CACHEEOF'
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
CACHEEOF
  chmod +x "${BIN_DIR}/mobile443-apply-cache.sh"

  # ─── monitor.sh (Telegram notifications to users) ───
  cat > "${BIN_DIR}/mobile443-monitor.sh" <<'MONITOREOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/sbin/mobile443-common.sh

NOTIFIED_FILE="${STATE_DIR}/notified.txt"
STATS_BLOCKED_FILE="${STATE_DIR}/stats_blocked.txt"
NOTIFY_COOLDOWN=21600  # 6 hours

mkdir -p "$STATE_DIR"
touch "$NOTIFIED_FILE" "$STATS_BLOCKED_FILE"

should_notify() {
  local key="$1"
  local now
  now=$(date +%s)

  local last_notified
  last_notified=$(grep "^${key} " "$NOTIFIED_FILE" 2>/dev/null | tail -1 | awk '{print $2}') || true

  if [[ -z "$last_notified" ]]; then
    return 0
  fi

  local diff=$(( now - last_notified ))
  [[ $diff -ge $NOTIFY_COOLDOWN ]]
}

mark_notified() {
  local key="$1"
  local now
  now=$(date +%s)
  grep -v "^${key} " "$NOTIFIED_FILE" > "${NOTIFIED_FILE}.tmp" 2>/dev/null || true
  echo "${key} ${now}" >> "${NOTIFIED_FILE}.tmp"
  mv "${NOTIFIED_FILE}.tmp" "$NOTIFIED_FILE"
}

find_user_by_ip() {
  local ip="$1"
  [[ -z "${XRAY_ACCESS_LOG:-}" || ! -f "${XRAY_ACCESS_LOG:-}" ]] && return

  # xray access log format: ... <IP>:<port> accepted ... email: <email>
  tail -n 50000 "$XRAY_ACCESS_LOG" 2>/dev/null \
    | grep -Fw "$ip" \
    | grep -oP 'email:\s*\K\S+' \
    | tail -1 || true
}

# Запрос данных пользователя из Remnawave API по ID (email из xray логов = ID пользователя)
get_remnawave_user() {
  local user_id="$1"
  [[ -z "${REMNAWAVE_API_URL:-}" || -z "${REMNAWAVE_API_TOKEN:-}" ]] && return

  curl -sS --max-time 10 \
    -H "Authorization: Bearer ${REMNAWAVE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "${REMNAWAVE_API_URL}/api/users/by-id/${user_id}" 2>/dev/null || true
}

# Извлечение Telegram ID из ответа API в зависимости от настройки TG_ID_SOURCE
extract_tg_id() {
  local api_response="$1"
  local tg_id=""

  if [[ "${TG_ID_SOURCE:-telegramId}" == "username" ]]; then
    # Из поля username берём последнее значение после _
    local username
    username=$(echo "$api_response" | jq -r '.response.username // empty' 2>/dev/null)
    if [[ -n "$username" ]]; then
      tg_id=$(echo "$username" | rev | cut -d'_' -f1 | rev)
    fi
  else
    # Из поля telegramId
    tg_id=$(echo "$api_response" | jq -r '.response.telegramId // empty' 2>/dev/null)
  fi

  echo "$tg_id"
}

process_blocked() {
  local src_ip="$1"
  local dst_port="$2"
  local now_ts
  now_ts=$(date '+%F %T')

  # Record for stats
  echo "${now_ts} ${src_ip} ${dst_port}" >> "$STATS_BLOCKED_FILE"

  # Skip if telegram is off
  [[ "${TG_ENABLED:-false}" == "true" ]] || return

  # Find user identifier in xray logs
  local email
  email=$(find_user_by_ip "$src_ip")

  if [[ -z "$email" ]]; then
    log "Blocked ${src_ip}:${dst_port} — user not found in xray logs"
    return
  fi

  # Запрашиваем данные пользователя из Remnawave API
  local api_response
  api_response=$(get_remnawave_user "$email")

  if [[ -z "$api_response" ]]; then
    log "Blocked ${src_ip}:${dst_port} — failed to get user '${email}' from Remnawave API"
    return
  fi

  # Проверяем что ответ содержит данные пользователя
  local has_response
  has_response=$(echo "$api_response" | jq -r '.response // empty' 2>/dev/null)
  if [[ -z "$has_response" || "$has_response" == "null" ]]; then
    log "Blocked ${src_ip}:${dst_port} — user '${email}' not found in Remnawave panel"
    return
  fi

  local tg_id
  tg_id=$(extract_tg_id "$api_response")

  if [[ -z "$tg_id" || "$tg_id" == "null" ]]; then
    log "Blocked ${src_ip}:${dst_port} — user '${email}' has no telegram ID (source: ${TG_ID_SOURCE:-telegramId})"
    return
  fi

  if should_notify "$tg_id"; then
    local msg
    msg="⚠️ <b>Внимание!</b>

Ваше подключение с IP <code>${src_ip}</code> было заблокировано.

Для подключения к VPN используйте <b>только мобильный интернет</b> (МТС, Билайн, МегаФон, Tele2, Ростелеком).

Подключения с домашнего интернета, VPN и прокси не допускаются."

    send_tg "$tg_id" "$msg"
    mark_notified "$tg_id"
    log "Notified tg:${tg_id} (${email}) about blocked IP ${src_ip}"
  else
    log "Blocked ${src_ip}:${dst_port} — tg:${tg_id} already notified recently"
  fi
}

# ─── Main loop: watch kernel log for iptables LOG entries ───

log "Monitor started, watching for blocked connections..."

# Determine log source
get_log_stream() {
  if command -v journalctl &>/dev/null; then
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

get_log_stream | while IFS= read -r line; do
  if [[ "$line" == *"MOBILE443_BLOCK:"* ]]; then
    src_ip=""
    dst_port=""

    # Extract SRC=x.x.x.x
    if [[ "$line" =~ SRC=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
      src_ip="${BASH_REMATCH[1]}"
    fi

    # Extract DPT=port
    if [[ "$line" =~ DPT=([0-9]+) ]]; then
      dst_port="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$src_ip" && -n "$dst_port" ]]; then
      process_blocked "$src_ip" "$dst_port"
    fi
  fi
done
MONITOREOF
  chmod +x "${BIN_DIR}/mobile443-monitor.sh"

  # ─── stats.sh (Daily admin report) ───
  cat > "${BIN_DIR}/mobile443-stats.sh" <<'STATSEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/sbin/mobile443-common.sh

STATS_BLOCKED_FILE="${STATE_DIR}/stats_blocked.txt"

[[ "${TG_ENABLED:-false}" == "true" ]] || exit 0
[[ -n "${TG_ADMIN_ID:-}" ]] || exit 0

# Calculate stats
total_blocked=0
unique_ips=0
top_ips=""

if [[ -f "$STATS_BLOCKED_FILE" && -s "$STATS_BLOCKED_FILE" ]]; then
  total_blocked=$(wc -l < "$STATS_BLOCKED_FILE" | tr -d ' ')
  unique_ips=$(awk '{print $3}' "$STATS_BLOCKED_FILE" | sort -u | wc -l | tr -d ' ')
  top_ips=$(awk '{print $3}' "$STATS_BLOCKED_FILE" | sort | uniq -c | sort -rn | head -10)
fi

# ipset size
ipset_size=$(ipset list "$IPSET_NAME" 2>/dev/null | grep "Number of entries" | awk '{print $NF}') || ipset_size="N/A"

# Active ports
ports_str="${PORT_LIST[*]}"

# Build message
msg="📊 <b>Статистика mobile443</b>
📅 Период: последние 24 часа

🚫 Заблокировано соединений: <b>${total_blocked}</b>
🌐 Уникальных заблокированных IP: <b>${unique_ips}</b>
📋 Префиксов в allowlist: <b>${ipset_size}</b>
🔌 Отслеживаемые порты: <b>${ports_str}</b>"

if [[ -n "$top_ips" ]]; then
  msg+="

🔝 <b>Топ заблокированных IP:</b>
<pre>${top_ips}</pre>"
fi

# Send to admin
send_tg "$TG_ADMIN_ID" "$msg"

# Rotate stats file
mv "$STATS_BLOCKED_FILE" "${STATS_BLOCKED_FILE}.prev" 2>/dev/null || true
touch "$STATS_BLOCKED_FILE"

log "Daily stats sent to admin (tg:${TG_ADMIN_ID})"
STATSEOF
  chmod +x "${BIN_DIR}/mobile443-stats.sh"

  # ═══ Systemd units ═══

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
Description=Daily refresh of mobile443 allowlist at 00:00

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true
Unit=mobile443-update.service

[Install]
WantedBy=timers.target
EOF

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
Description=Daily mobile443 stats report at 09:00

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true
Unit=mobile443-stats.service

[Install]
WantedBy=timers.target
EOF

  # ═══ Enable and start ═══

  systemctl daemon-reload
  systemctl enable mobile443-apply.service
  systemctl enable --now mobile443-update.timer

  if [[ "${TG_ENABLED}" == "true" ]]; then
    systemctl enable --now mobile443-monitor.service
    systemctl enable --now mobile443-stats.timer
  fi

  echo "[*] Скачивание списков IP-адресов ASN... Может занять пару минут."
  if ! systemctl start mobile443-update.service; then
    echo "[!] Первое онлайн-обновление не удалось, применяем кеш"
    systemctl start mobile443-apply.service || true
  fi

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
  echo "    ipset list allowed_mobile_443 | head -30"
  echo "    iptables -L FILTER_MOBILE_443 -n -v --line-numbers"

  if [[ "${TG_ENABLED}" == "true" ]]; then
    echo ""
    echo "  Telegram мониторинг:"
    echo "    systemctl status mobile443-monitor.service --no-pager"
    echo "    systemctl status mobile443-stats.timer --no-pager"
    echo ""
    echo "  Логи монитора:"
    echo "    journalctl -u mobile443-monitor.service -f --no-pager"
  fi
  echo ""
}

# ═══════════════════════════════════════════════
#  Remove
# ═══════════════════════════════════════════════

remove_all() {
  # Load config to know ports
  local -a REMOVE_PORTS=(443)
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    read -ra REMOVE_PORTS <<< "${PORTS:-443}"
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
      for port in "${REMOVE_PORTS[@]}"; do
        while iptables -C "$chain" -p "$proto" --dport "$port" -j FILTER_MOBILE_443 2>/dev/null; do
          iptables -D "$chain" -p "$proto" --dport "$port" -j FILTER_MOBILE_443 || true
        done
      done
    done
  done

  iptables -F FILTER_MOBILE_443 2>/dev/null || true
  iptables -X FILTER_MOBILE_443 2>/dev/null || true

  echo "[*] Удаление ipset"
  ipset destroy allowed_mobile_443_tmp 2>/dev/null || true
  ipset destroy allowed_mobile_443 2>/dev/null || true

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

# ═══════════════════════════════════════════════
#  Entry point
# ═══════════════════════════════════════════════

case "$ACTION" in
  install)
    install_all
    ;;
  remove)
    remove_all
    ;;
  *)
    echo "Использование: $0 [install|remove]"
    exit 1
    ;;
esac