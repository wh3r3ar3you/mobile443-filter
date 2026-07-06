#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-install}"
INSTALL_PROFILE="${2:-full}"

BASE_DIR="/opt/mobile443"
STATE_DIR="/var/lib/mobile443"
BIN_DIR="/usr/local/sbin"
CONFIG_FILE="${BASE_DIR}/config.conf"
ASNS_FILE="${BASE_DIR}/asns.conf"
ASNS_EXCLUDED_FILE="${BASE_DIR}/asns_excluded.conf"
STATIC_NETWORKS_FILE="${BASE_DIR}/static_networks.conf"
EXCLUDED_NETWORKS_FILE="${BASE_DIR}/excluded_networks.conf"
REPO_RAW_DEFAULT="https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main"

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
  local tg_custom_message="${13:-}"
  local tg_username_separator="${14:-}"

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
  printf "TG_CUSTOM_MESSAGE=%q\n" "$tg_custom_message" >> "$CONFIG_FILE"
  printf "TG_USERNAME_SEPARATOR=%q\n" "$tg_username_separator" >> "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

interactive_setup_full() {
  local ports tg_choice enable_telegram tg_bot_token tg_admin_id
  local remnawave_api_url remnawave_api_token tg_id_source tg_username_separator
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
    echo "   3) Из поля username — указать свой разделитель (или без него)"
    read -r -p "   Выберите (1, 2 или 3): " tg_id_source_choice < /dev/tty

    if [[ "$tg_id_source_choice" == "3" ]]; then
      tg_id_source="username_custom"
      echo "   Введите символ-разделитель, после которого идет telegramID (например : или _ или -)."
      echo "   Оставьте пустым, если username и есть telegramID целиком:"
      read -r -p "   > " tg_username_separator < /dev/tty
      if [[ -z "$tg_username_separator" ]]; then
        echo "   ✅ Telegram ID будет браться целиком из username"
      else
        echo "   ✅ Telegram ID будет извлекаться из username после последнего символа '${tg_username_separator}'"
      fi
    elif [[ "$tg_id_source_choice" == "2" ]]; then
      tg_id_source="username"
      tg_username_separator=""
      echo "   ✅ Telegram ID будет извлекаться из username после последнего _"
    else
      tg_id_source="telegramId"
      tg_username_separator=""
      echo "   ✅ Telegram ID будет браться из поля telegramId"
    fi
    echo ""

    echo "💬 Какое сообщение отправлять пользователям при блокировке?"
    echo "   1) Стандартное (рекомендуется)"
    echo "   2) Свое кастомное сообщение"
    read -r -p "   Выберите (1 или 2): " tg_msg_choice < /dev/tty

    if [[ "$tg_msg_choice" == "2" ]]; then
      echo "   Напишите текст кастомного сообщения (в одну строку, для переноса строки пишите \n)."
      echo "   • Поддерживается HTML-разметка (например, <b>жирный текст</b>)."
      echo "   • Доступна переменная: {ip} - IP-адрес пользователя, с которого была попытка подключения"
      read -r -p "   > " tg_custom_message < /dev/tty
      echo "   ✅ Кастомное сообщение сохранено."
    else
      tg_custom_message=""
      echo "   ✅ Будет использовано стандартное сообщение."
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
    tg_custom_message=""
    tg_username_separator=""
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
    "${tg_id_source:-}" \
    "${tg_custom_message:-}" \
    "${tg_username_separator:-}"

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
13174
21365
30922
34351


# Beeline / VimpelCom
3216
16043
16345
42842

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
48092
39374
13116

# Miranda
201776

# Sberbank-Telecom
206673

# Rostelecom
# ВАЖНО: AS12389 исключён из полного пула — весь анонс ASN слишком широкий
# и затрагивает домашний проводной broadband, а не только мобильные сети.
# Вместо ASN используется точечный список сетей, см. static_networks.conf.
# ASN сохранён в asns_excluded.conf и его можно вернуть в пул через
# консоль `mobile443` (пункт меню "Вернуть ASN в полный пул").

# Sevastar (Stavropol)
35816

# T-mobile + Alfa-mobile
205638
214257
202498

# Volna-Mobile
203451
203561

# MCS
47204
# DVF Irkutsk YOTA-mobile
31133
# MOTIV telecom
31499

EOF
}

write_default_asns_excluded() {
  if [[ -s "$ASNS_EXCLUDED_FILE" ]]; then
    return
  fi

  cat > "$ASNS_EXCLUDED_FILE" <<'EOF'
# === ASN, исключённые из полного пула asns.conf ===
# Формат строки: "<ASN> # <комментарий>"
# Такие ASN заменены точечным списком сетей в static_networks.conf,
# т.к. весь анонс ASN слишком широкий (например, задевает домашний
# проводной broadband, а не только мобильные сети).
#
# Вернуть ASN обратно в полный пул можно через консоль:
#   sudo mobile443   ->   "Вернуть ASN в полный пул"

12389 # Rostelecom — заменён static-списком (31 сеть), см. static_networks.conf
EOF
  chmod 644 "$ASNS_EXCLUDED_FILE"
}

write_default_static_networks() {
  if [[ -s "$STATIC_NETWORKS_FILE" ]]; then
    return
  fi

  cat > "$STATIC_NETWORKS_FILE" <<'EOF'
# === Точечные (курируемые вручную) сети ===
# Эти сети всегда добавляются в mobile-allowlist независимо от того,
# какие ASN сейчас в пуле (asns.conf). Используется, когда весь ASN
# целиком слишком широкий, и нужен только конкретный набор подсетей.

# Rostelecom (заменяет исключённый AS12389, см. asns_excluded.conf)
5.141.100.0/22
5.141.192.0/22
5.142.40.0/21
83.219.13.0/24
87.226.172.0/24
87.226.203.0/24
87.226.204.0/23
87.226.206.0/24
87.226.209.0/24
87.226.210.0/23
87.226.212.0/24
87.226.218.0/24
88.205.192.0/20
89.20.97.0/24
89.20.102.0/24
89.204.112.0/20
95.86.213.0/24
95.86.214.0/23
95.152.44.0/24
95.152.62.0/24
95.167.104.0/24
176.119.160.0/21
176.119.168.0/24
176.119.173.0/24
176.119.174.0/23
178.47.161.0/24
178.67.192.0/21
188.254.122.0/23
195.38.60.0/22
212.120.169.0/24
213.24.147.0/24
217.107.106.0/24
EOF
  chmod 644 "$STATIC_NETWORKS_FILE"
}

ensure_excluded_networks_file() {
  if [[ -f "$EXCLUDED_NETWORKS_FILE" ]]; then
    return
  fi

  cat > "$EXCLUDED_NETWORKS_FILE" <<'EOF'
# === Ручные исключения из mobile-allowlist ===
# Любая сеть в этом файле никогда не попадёт в allowlist, даже если она
# анонсируется одним из ASN пула или присутствует в static_networks.conf.
# Формат: один CIDR на строку, комментарии через #.
# Управляется через консоль: sudo mobile443 -> "Управление исключениями"
EOF
  chmod 644 "$EXCLUDED_NETWORKS_FILE"
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
    TG_ID_SOURCE TG_CUSTOM_MESSAGE TG_USERNAME_SEPARATOR TRAF_GUARD_BASE_URL GOV_LIST_URL ANTISCANNER_LIST_URL
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
    write_default_asns_excluded
    write_default_static_networks
  fi
  ensure_excluded_networks_file

  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  write_runtime_scripts
  write_cli_console
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
  local restored_asns_excluded="$4"
  local restored_static_networks="$5"
  local restored_excluded_networks="$6"
  local ports enable_traf_guard enable_gov enable_antiscanner enable_mobile_allow
  local enable_telegram tg_bot_token tg_admin_id xray_access_log remnawave_api_url
  local remnawave_api_token tg_id_source tg_custom_message tg_username_separator

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
  tg_custom_message="${TG_CUSTOM_MESSAGE:-}"
  tg_username_separator="${TG_USERNAME_SEPARATOR:-}"

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
    tg_custom_message=""
    tg_username_separator=""
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
    "$tg_id_source" \
    "$tg_custom_message" \
    "$tg_username_separator"

  if [[ "$target_profile" == "full" ]]; then
    if [[ -s "$restored_asns" ]]; then
      install -m 0644 "$restored_asns" "$ASNS_FILE"
    else
      write_default_asns
    fi

    if [[ -s "$restored_asns_excluded" ]]; then
      install -m 0644 "$restored_asns_excluded" "$ASNS_EXCLUDED_FILE"
    else
      write_default_asns_excluded
    fi

    if [[ -s "$restored_static_networks" ]]; then
      install -m 0644 "$restored_static_networks" "$STATIC_NETWORKS_FILE"
    else
      write_default_static_networks
    fi
  fi

  if [[ -f "$restored_excluded_networks" ]]; then
    install -m 0644 "$restored_excluded_networks" "$EXCLUDED_NETWORKS_FILE"
  else
    ensure_excluded_networks_file
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
ASNS_EXCLUDED_FILE="${BASE_DIR}/asns_excluded.conf"
STATIC_NETWORKS_FILE="${BASE_DIR}/static_networks.conf"
EXCLUDED_NETWORKS_FILE="${BASE_DIR}/excluded_networks.conf"
ALLOW_CACHE_FILE="${STATE_DIR}/prefixes.txt"
LOCK_FILE="${STATE_DIR}/lock"

IPSET_ALLOW_NAME="allowed_mobile_443"
IPSET_ALLOW_TMP_NAME="${IPSET_ALLOW_NAME}_tmp"
IPSET_GOV_NAME="traf_guard_government"
IPSET_GOV_TMP_NAME="${IPSET_GOV_NAME}_tmp"
IPSET_ANTISCANNER_NAME="traf_guard_antiscanner"
IPSET_ANTISCANNER_TMP_NAME="${IPSET_ANTISCANNER_NAME}_tmp"
IPSET_DEFERRED_BLOCK_NAME="mobile443_deferred_block"

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
  if bool_is_true "$ENABLE_TELEGRAM"; then
    ipset create "$IPSET_DEFERRED_BLOCK_NAME" hash:ip family inet hashsize 4096 maxelem 65536 timeout 3600 -exist
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

ip_to_int() {
  local ip="$1" a b c d
  local IFS=.
  read -r a b c d <<< "$ip"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# Возвращает успех, если сеть $2 (CIDR) полностью содержится в сети $1 (CIDR),
# либо равна ей. Используется, чтобы вычесть исключённые сети из allowlist.
cidr_contains() {
  local outer="$1" inner="$2"
  local outer_ip="${outer%/*}" outer_mask="${outer#*/}"
  local inner_ip="${inner%/*}" inner_mask="${inner#*/}"
  local outer_int inner_int mask_int

  [[ "$outer_mask" =~ ^[0-9]+$ && "$inner_mask" =~ ^[0-9]+$ ]] || return 1
  (( inner_mask >= outer_mask )) || return 1

  outer_int="$(ip_to_int "$outer_ip")"
  inner_int="$(ip_to_int "$inner_ip")"
  if (( outer_mask == 0 )); then
    mask_int=0
  else
    mask_int=$(( (0xFFFFFFFF << (32 - outer_mask)) & 0xFFFFFFFF ))
  fi

  (( (outer_int & mask_int) == (inner_int & mask_int) ))
}

# Убирает из $input все сети, попадающие под любую сеть из $exclusions_file
# (точное совпадение или вложенная подсеть). Результат пишется в $output.
filter_excluded_networks() {
  local input="$1" exclusions_file="$2" output="$3"
  local prefix ex excluded

  if [[ ! -s "$exclusions_file" ]]; then
    cp "$input" "$output"
    return
  fi

  local -a exclusion_list=()
  while IFS= read -r ex || [[ -n "$ex" ]]; do
    ex="$(echo "$ex" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$ex" ]] || continue
    validate_ipv4_cidr "$ex" || continue
    exclusion_list+=("$ex")
  done < "$exclusions_file"

  : > "$output"
  if (( ${#exclusion_list[@]} == 0 )); then
    cp "$input" "$output"
    return
  fi

  while IFS= read -r prefix || [[ -n "$prefix" ]]; do
    [[ -n "$prefix" ]] || continue
    excluded="false"
    for ex in "${exclusion_list[@]}"; do
      if cidr_contains "$ex" "$prefix"; then
        excluded="true"
        break
      fi
    done
    [[ "$excluded" == "true" ]] || echo "$prefix" >> "$output"
  done < "$input"
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
    # 1) ACCEPT mobile ASN IPs immediately
    iptables -A "$CHAIN_NAME" -m set --match-set "$IPSET_ALLOW_NAME" src -j ACCEPT

    if bool_is_true "$ENABLE_TELEGRAM"; then
      # 2) DROP IPs that were already identified and deferred-blocked by the monitor
      iptables -A "$CHAIN_NAME" -m set --match-set "$IPSET_DEFERRED_BLOCK_NAME" src -j DROP
      # 3) LOG non-mobile IPs but let them through so xray can log the user email
      iptables -A "$CHAIN_NAME" -m limit --limit 30/min --limit-burst 10 \
        -j LOG --log-prefix "$LOG_PREFIX" --log-level 4
      # No DROP here — connection passes to xray, monitor will add IP to deferred block
    else
      # Telegram disabled — immediate LOG + DROP as before
      iptables -A "$CHAIN_NAME" -m limit --limit 30/min --limit-burst 10 \
        -j LOG --log-prefix "$LOG_PREFIX" --log-level 4
      iptables -A "$CHAIN_NAME" -j DROP
    fi
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
TMP_FILTERED=""

cleanup_tmp() {
  rm -f "${TMP_RAW:-}" "${TMP_CLEAN:-}" "${TMP_FILTERED:-}"
}

update_mobile_allowlist() {
  local asn line new_count old_count min_safe

  [[ -f "$ASNS_FILE" ]] || {
    echo "ASN file not found: $ASNS_FILE" >&2
    exit 1
  }

  TMP_RAW="$(mktemp)"
  TMP_CLEAN="$(mktemp)"
  TMP_FILTERED="$(mktemp)"
  trap cleanup_tmp EXIT

  log "Fetching announced prefixes from RIPEstat"

  while IFS= read -r asn || [[ -n "$asn" ]]; do
    [[ -z "$asn" || "$asn" =~ ^# ]] && continue
    log "Fetching AS${asn}"
    curl -fsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 \
      "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${asn}" \
      | jq -r '.data.prefixes[]?.prefix // empty' >> "$TMP_RAW" || true
  done < "$ASNS_FILE"

  if [[ -f "$STATIC_NETWORKS_FILE" ]]; then
    log "Merging curated static networks: $STATIC_NETWORKS_FILE"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="$(echo "$line" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
      [[ -n "$line" ]] || continue
      echo "$line" >> "$TMP_RAW"
    done < "$STATIC_NETWORKS_FILE"
  fi

  sort -Vu "$TMP_RAW" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
    > "$TMP_CLEAN" || true

  filter_excluded_networks "$TMP_CLEAN" "$EXCLUDED_NETWORKS_FILE" "$TMP_FILTERED"
  cp "$TMP_FILTERED" "$TMP_CLEAN"

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
  elif [[ "${TG_ID_SOURCE:-telegramId}" == "username_custom" ]]; then
    username=$(echo "$api_response" | jq -r '.response.username // empty' 2>/dev/null)
    if [[ -n "$username" ]]; then
      if [[ -z "${TG_USERNAME_SEPARATOR:-}" ]]; then
        tg_id="$username"
      else
        tg_id=$(echo "$username" | rev | cut -d"${TG_USERNAME_SEPARATOR}" -f1 | rev)
      fi
    fi
  else
    tg_id=$(echo "$api_response" | jq -r '.response.telegramId // empty' 2>/dev/null)
  fi

  echo "$tg_id"
}

add_to_deferred_block() {
  local ip="$1"
  ipset add "$IPSET_DEFERRED_BLOCK_NAME" "$ip" timeout 3600 -exist 2>/dev/null || true
  log "Added ${ip} to deferred block ipset for 1 hour"
}

find_user_by_ip_with_retry() {
  local ip="$1"
  local retries=5
  local delay=1
  local attempt email

  for (( attempt=1; attempt<=retries; attempt++ )); do
    email=$(find_user_by_ip "$ip")
    if [[ -n "$email" ]]; then
      echo "$email"
      return
    fi
    if (( attempt < retries )); then
      sleep "$delay"
    fi
  done
}

process_blocked() {
  local src_ip="$1"
  local dst_port="$2"
  local now_ts email api_response has_response tg_id msg

  now_ts=$(date '+%F %T')
  echo "${now_ts} ${src_ip} ${dst_port}" >> "$STATS_BLOCKED_FILE"

  [[ "${ENABLE_TELEGRAM:-false}" == "true" ]] || return

  # Wait for the IP to appear in xray access.log (connection is allowed through first)
  email=$(find_user_by_ip_with_retry "$src_ip")
  if [[ -z "$email" ]]; then
    # Do not add to deferred block if NOT found. 
    # This gives slow connections time to establish and appear in access.log on the next log trigger.
    return
  fi

  # Add IP to deferred block immediately after identifying the user
  add_to_deferred_block "$src_ip"

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
    if [[ -n "${TG_CUSTOM_MESSAGE:-}" ]]; then
      msg="${TG_CUSTOM_MESSAGE//\{ip\}/${src_ip}}"
      msg="$(printf '%b' "$msg")"
    else
      msg="⚠️ <b>Внимание!</b>

Соединение с IP <code>${src_ip}</code> было прервано. 

Данный сервер предназначен <b>исключительно для обхода мобильных глушилок</b>, подключение через Wi-Fi не поддерживается, и соединения будут разрываться автоматически.

Пожалуйста, переключитесь на <b>мобильный интернет</b> (МТС, Билайн, МегаФон, Tele2, Ростелеком, и др.) для стабильной работы."

    fi
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

write_cli_console() {
  cat > "${BIN_DIR}/mobile443" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/sbin/mobile443-common.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [[ "$(id -u)" -ne 0 ]]; then
  echo -e "${RED}✖ Запустите от root: sudo mobile443${NC}"
  exit 1
fi

pause() {
  echo ""
  read -r -p "Нажмите Enter, чтобы вернуться в меню..." _ < /dev/tty || true
}

print_header() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "╔═══════════════════════════════════════════════╗"
  echo "║             mobile443 — консоль                ║"
  echo "╚═══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

strip_comment() {
  echo "$1" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

set_config_key() {
  local key="$1" value="$2" quoted tmp
  quoted="$(printf '%q' "$value")"
  tmp="$(mktemp)"
  grep -v "^${key}=" "$CONFIG_FILE" > "$tmp" 2>/dev/null || true
  echo "${key}=${quoted}" >> "$tmp"
  install -m 0600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

reload_config() {
  # shellcheck disable=SC1090
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
}

# ---------- 1) Обновить списки ----------
action_update_lists() {
  print_header
  echo -e "${CYAN}🔄 Запускаем обновление списков (ASN + traffic-guard)...${NC}"
  echo ""
  if systemctl start mobile443-update.service; then
    echo -e "${GREEN}✅ Обновление выполнено успешно.${NC}"
  else
    echo -e "${RED}✖ Обновление завершилось с ошибкой:${NC}"
  fi
  echo ""
  journalctl -u mobile443-update.service -n 15 --no-pager 2>/dev/null || true
  pause
}

# ---------- 2) Вернуть ASN в полный пул ----------
action_restore_asn() {
  print_header
  echo -e "${CYAN}↩️  Возврат ASN в полный пул${NC}"
  echo ""

  local -a entries=()
  if [[ -f "$ASNS_EXCLUDED_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -n "$(strip_comment "$line")" ]] || continue
      entries+=("$line")
    done < "$ASNS_EXCLUDED_FILE"
  fi

  if (( ${#entries[@]} == 0 )); then
    echo "Список исключённых ASN пуст — возвращать нечего."
    pause
    return
  fi

  echo "Исключённые ASN:"
  local i
  for i in "${!entries[@]}"; do
    echo "  $((i+1))) ${entries[$i]}"
  done
  echo "  0) Отмена"
  echo ""
  read -r -p "Выберите номер ASN для возврата в пул: " choice < /dev/tty
  [[ -z "$choice" || "$choice" == "0" ]] && return

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#entries[@]} )); then
    echo -e "${RED}Некорректный выбор${NC}"
    pause
    return
  fi

  local selected="${entries[$((choice-1))]}"
  local asn_num
  asn_num="$(echo "$selected" | awk '{print $1}')"

  {
    echo ""
    echo "# Возвращён в пул из asns_excluded.conf ($(date '+%F %T'))"
    echo "$asn_num"
  } >> "$ASNS_FILE"

  local tmp
  tmp="$(mktemp)"
  grep -vF "$selected" "$ASNS_EXCLUDED_FILE" > "$tmp" 2>/dev/null || true
  install -m 0644 "$tmp" "$ASNS_EXCLUDED_FILE"
  rm -f "$tmp"

  echo -e "${GREEN}✅ AS${asn_num} возвращён в asns.conf.${NC}"
  echo ""
  read -r -p "Обновить списки сейчас, чтобы применить изменения? (y/n): " run_now < /dev/tty
  if [[ "${run_now,,}" == "y" ]]; then
    systemctl start mobile443-update.service || true
  fi
  pause
}

# ---------- 3) Управление исключениями сетей ----------
action_manage_exclusions() {
  while true; do
    print_header
    echo -e "${CYAN}🚫 Управление исключениями (excluded_networks.conf)${NC}"
    echo ""

    [[ -f "$EXCLUDED_NETWORKS_FILE" ]] || touch "$EXCLUDED_NETWORKS_FILE"

    local -a entries=()
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -n "$(strip_comment "$line")" ]] || continue
      entries+=("$line")
    done < "$EXCLUDED_NETWORKS_FILE"

    if (( ${#entries[@]} > 0 )); then
      echo "Текущие исключения:"
      local i
      for i in "${!entries[@]}"; do
        echo "  $((i+1))) ${entries[$i]}"
      done
    else
      echo "Список исключений пуст."
    fi

    echo ""
    echo "  a) Добавить сеть в исключение"
    (( ${#entries[@]} > 0 )) && echo "  r) Удалить сеть из исключений"
    echo "  0) Назад"
    echo ""
    read -r -p "Выберите действие: " action < /dev/tty

    case "$action" in
      a|A)
        echo ""
        read -r -p "Введите CIDR сети для исключения (например 10.0.0.0/24): " new_cidr < /dev/tty
        new_cidr="$(strip_comment "$new_cidr")"
        if ! validate_ipv4_cidr "$new_cidr"; then
          echo -e "${RED}✖ Некорректный CIDR${NC}"
          pause
          continue
        fi
        read -r -p "Комментарий (необязательно): " comment < /dev/tty
        if [[ -n "$comment" ]]; then
          echo "${new_cidr} # ${comment}" >> "$EXCLUDED_NETWORKS_FILE"
        else
          echo "${new_cidr}" >> "$EXCLUDED_NETWORKS_FILE"
        fi
        echo -e "${GREEN}✅ Сеть ${new_cidr} добавлена в исключения.${NC}"
        echo ""
        read -r -p "Обновить списки сейчас? (y/n): " run_now < /dev/tty
        [[ "${run_now,,}" == "y" ]] && { systemctl start mobile443-update.service || true; }
        pause
        ;;
      r|R)
        (( ${#entries[@]} == 0 )) && continue
        echo ""
        read -r -p "Номер исключения для удаления: " del_choice < /dev/tty
        if ! [[ "$del_choice" =~ ^[0-9]+$ ]] || (( del_choice < 1 || del_choice > ${#entries[@]} )); then
          echo -e "${RED}Некорректный выбор${NC}"
          pause
          continue
        fi
        local target="${entries[$((del_choice-1))]}"
        local tmp
        tmp="$(mktemp)"
        grep -vF "$target" "$EXCLUDED_NETWORKS_FILE" > "$tmp" 2>/dev/null || true
        install -m 0644 "$tmp" "$EXCLUDED_NETWORKS_FILE"
        rm -f "$tmp"
        echo -e "${GREEN}✅ Исключение удалено.${NC}"
        echo ""
        read -r -p "Обновить списки сейчас? (y/n): " run_now < /dev/tty
        [[ "${run_now,,}" == "y" ]] && { systemctl start mobile443-update.service || true; }
        pause
        ;;
      0|"") return ;;
      *) ;;
    esac
  done
}

# ---------- 4) Статус и диагностика ----------
action_status() {
  print_header
  echo -e "${CYAN}🩺 Статус и диагностика${NC}"
  echo ""

  echo -e "${BOLD}Конфигурация (${CONFIG_FILE}):${NC}"
  echo "  Порты: ${PORTS:-443}"
  echo "  Traffic Guard: ${ENABLE_TRAF_GUARD:-false} (government=${ENABLE_TRAF_GUARD_GOVERNMENT:-false}, antiscanner=${ENABLE_TRAF_GUARD_ANTISCANNER:-false})"
  echo "  Mobile allowlist: ${ENABLE_MOBILE_ALLOW:-false}"
  echo "  Telegram/Remnawave: ${ENABLE_TELEGRAM:-false}"
  echo ""

  echo -e "${BOLD}Пулы сетей:${NC}"
  echo "  ASN в пуле (asns.conf): $(grep -cE '^[0-9]+' "$ASNS_FILE" 2>/dev/null || echo 0)"
  echo "  Исключённые ASN (asns_excluded.conf): $(grep -cE '^[0-9]+' "$ASNS_EXCLUDED_FILE" 2>/dev/null || echo 0)"
  echo "  Точечные сети (static_networks.conf): $(grep -cE '^[0-9]+\.' "$STATIC_NETWORKS_FILE" 2>/dev/null || echo 0)"
  echo "  Ручные исключения (excluded_networks.conf): $(grep -cE '^[0-9]+\.' "$EXCLUDED_NETWORKS_FILE" 2>/dev/null || echo 0)"
  echo ""

  echo -e "${BOLD}Ipset:${NC}"
  local set_name cnt
  for set_name in "$IPSET_ALLOW_NAME" "$IPSET_GOV_NAME" "$IPSET_ANTISCANNER_NAME" "$IPSET_DEFERRED_BLOCK_NAME"; do
    if cnt=$(ipset list "$set_name" 2>/dev/null | awk '/Number of entries/ {print $4}') && [[ -n "$cnt" ]]; then
      echo "  $set_name: ${cnt} записей"
    else
      echo "  $set_name: не создан"
    fi
  done
  echo ""

  echo -e "${BOLD}Iptables (счётчики пакетов):${NC}"
  iptables -L "$CHAIN_NAME" -n -v 2>/dev/null | head -10 || echo "  chain $CHAIN_NAME не найден"
  echo ""

  echo -e "${BOLD}Systemd:${NC}"
  local unit
  for unit in mobile443-update.timer mobile443-update.service mobile443-apply.service \
              mobile443-monitor.service mobile443-stats.timer; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      printf "  %-32s %s\n" "$unit" "$(systemctl is-active "$unit" 2>/dev/null || echo unknown)"
    fi
  done
  echo ""

  local last_update
  last_update=$(systemctl show mobile443-update.service -p ActiveEnterTimestamp --value 2>/dev/null || true)
  echo "  Последнее успешное обновление: ${last_update:-нет данных}"

  pause
}

# ---------- 5) Статистика (как отправляет бот) ----------
action_show_stats() {
  print_header
  echo -e "${CYAN}📊 Статистика mobile443${NC}"
  echo ""

  if [[ "${ENABLE_TELEGRAM:-false}" != "true" ]]; then
    echo "Telegram/Remnawave интеграция не настроена, поэтому сбор статистики блокировок не ведётся."
    echo "Настройте интеграцию в пункте меню \"Настроить Telegram/Remnawave\"."
    pause
    return
  fi

  local stats_file="${STATE_DIR}/stats_blocked.txt"
  local total_blocked=0 unique_ips=0 top_ips=""

  if [[ -f "$stats_file" && -s "$stats_file" ]]; then
    total_blocked=$(wc -l < "$stats_file" | tr -d ' ')
    unique_ips=$(awk '{print $3}' "$stats_file" | sort -u | wc -l | tr -d ' ')
    top_ips=$(awk '{print $3}' "$stats_file" | sort | uniq -c | sort -rn | head -10)
  fi

  local allow_count gov_count antiscanner_count
  allow_count=$(ipset list "$IPSET_ALLOW_NAME" 2>/dev/null | awk '/Number of entries/ {print $4}')
  gov_count=$(ipset list "$IPSET_GOV_NAME" 2>/dev/null | awk '/Number of entries/ {print $4}')
  antiscanner_count=$(ipset list "$IPSET_ANTISCANNER_NAME" 2>/dev/null | awk '/Number of entries/ {print $4}')

  echo "📅 Период: с последней отправки/сброса статистики"
  echo ""
  echo "🚫 Заблокировано соединений: ${total_blocked}"
  echo "🌐 Уникальных заблокированных IP: ${unique_ips}"
  echo "📋 Mobile allowlist: ${allow_count:-N/A}"
  echo "🛑 Traffic Guard government: ${gov_count:-N/A}"
  echo "🛑 Traffic Guard antiscanner: ${antiscanner_count:-N/A}"
  echo "🔌 Порты: ${PORTS:-443}"

  if [[ -n "$top_ips" ]]; then
    echo ""
    echo "🔝 Топ заблокированных IP:"
    echo "$top_ips"
  fi

  echo ""
  echo "Это тот же отчёт, что бот раз в день шлёт админу в Telegram (mobile443-stats.timer, 09:00 UTC)."
  echo ""
  read -r -p "Отправить этот отчёт в Telegram прямо сейчас? (y/n): " send_now < /dev/tty
  if [[ "${send_now,,}" == "y" ]]; then
    systemctl start mobile443-stats.service && echo -e "${GREEN}✅ Отправлено.${NC}" || echo -e "${RED}✖ Не удалось отправить${NC}"
  fi
  pause
}

detect_xray_log_cli() {
  echo "🔍 Поиск access.log от xray/remnanode..." >&2
  local -a candidates=(
    "/var/log/remnanode/access.log"
    "/var/log/remnanode/xray/access.log"
    "/var/lib/remnanode/access.log"
    "/var/lib/remnanode/xray/access.log"
    "/opt/remnanode/access.log"
    "/var/log/xray/access.log"
    "/usr/local/etc/xray/access.log"
  )
  local path
  for path in "${candidates[@]}"; do
    if [[ -f "$path" ]]; then
      echo "   ✅ Найден: $path" >&2
      echo "$path"
      return
    fi
  done

  local found
  found=$(find / -maxdepth 5 \( -name "access.log" -o -name "access_log" \) \
    \( -path "*xray*" -o -path "*remna*" \) 2>/dev/null | head -5) || true

  if [[ -n "$found" ]]; then
    echo "   Найдены файлы:" >&2
    echo "$found" | while IFS= read -r f; do echo "     - $f" >&2; done
    echo "" >&2
    read -r -p "   Введите путь или Enter для первого найденного: " user_path < /dev/tty
    echo "${user_path:-$(echo "$found" | head -1)}"
    return
  fi

  echo "   ⚠️  Автоматически не найден." >&2
  read -r -p "   Введите полный путь к access.log xray: " manual_path < /dev/tty
  echo "$manual_path"
}

write_telegram_units_cli() {
  cat > /etc/systemd/system/mobile443-monitor.service <<'UNIT'
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
UNIT

  cat > /etc/systemd/system/mobile443-stats.service <<'UNIT'
[Unit]
Description=Send daily mobile443 stats to Telegram admin
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mobile443-stats.sh
User=root
Group=root
UNIT

  cat > /etc/systemd/system/mobile443-stats.timer <<'UNIT'
[Unit]
Description=Daily mobile443 stats report at 09:00 UTC

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true
Unit=mobile443-stats.service

[Install]
WantedBy=timers.target
UNIT
}

# ---------- 6) Настроить Telegram / Remnawave ----------
action_configure_telegram() {
  print_header
  echo -e "${CYAN}🤖 Настройка Telegram / Remnawave${NC}"
  echo ""

  if [[ "${ENABLE_MOBILE_ALLOW:-true}" != "true" ]]; then
    echo -e "${YELLOW}⚠️  Установка в block-only режиме (mobile allowlist выключен).${NC}"
    echo "    Уведомления пользователям при блокировке mobile-фильтром работать не будут,"
    echo "    но Traffic Guard alert админу и статистика продолжат работать."
    echo ""
  fi

  if [[ "${ENABLE_TELEGRAM:-false}" == "true" ]]; then
    echo "Telegram/Remnawave уже настроены для этой установки."
    read -r -p "Перенастроить заново? (y/n): " redo < /dev/tty
    if [[ "${redo,,}" != "y" ]]; then
      return
    fi
  fi

  local tg_bot_token tg_admin_id remnawave_api_url remnawave_api_token
  local tg_id_source tg_username_separator tg_custom_message xray_access_log tg_id_choice tg_msg_choice

  echo ""
  echo "🤖 Токен Telegram бота:"
  read -r -p "   > " tg_bot_token < /dev/tty
  echo ""
  echo "👤 Telegram ID администратора (для статистики и алертов):"
  read -r -p "   > " tg_admin_id < /dev/tty
  echo ""
  echo "🌐 Адрес панели Remnawave (например: https://panel.example.com):"
  read -r -p "   > " remnawave_api_url < /dev/tty
  remnawave_api_url="${remnawave_api_url%/}"
  echo ""
  echo "🔑 API токен Remnawave панели:"
  read -r -p "   > " remnawave_api_token < /dev/tty
  echo ""
  echo "📋 Откуда брать Telegram ID пользователя?"
  echo "   1) Из поля telegramId в API Remnawave"
  echo "   2) Из username — последнее значение после _"
  echo "   3) Из username — свой разделитель (или без него)"
  read -r -p "   Выберите (1, 2 или 3): " tg_id_choice < /dev/tty
  case "$tg_id_choice" in
    3)
      tg_id_source="username_custom"
      echo "   Символ-разделитель (пусто = весь username целиком):"
      read -r -p "   > " tg_username_separator < /dev/tty
      ;;
    2)
      tg_id_source="username"
      tg_username_separator=""
      ;;
    *)
      tg_id_source="telegramId"
      tg_username_separator=""
      ;;
  esac
  echo ""
  echo "💬 Сообщение пользователю при блокировке:"
  echo "   1) Стандартное"
  echo "   2) Своё кастомное"
  read -r -p "   Выберите (1 или 2): " tg_msg_choice < /dev/tty
  if [[ "$tg_msg_choice" == "2" ]]; then
    echo "   Текст (\\n для переноса строки, {ip} — подстановка IP):"
    read -r -p "   > " tg_custom_message < /dev/tty
  else
    tg_custom_message=""
  fi
  echo ""
  xray_access_log="$(detect_xray_log_cli)"
  echo "   ✅ Используем: ${xray_access_log:-не указан}"

  set_config_key "ENABLE_TELEGRAM" "true"
  set_config_key "TG_ENABLED" "true"
  set_config_key "TG_BOT_TOKEN" "$tg_bot_token"
  set_config_key "TG_ADMIN_ID" "$tg_admin_id"
  set_config_key "XRAY_ACCESS_LOG" "$xray_access_log"
  set_config_key "REMNAWAVE_API_URL" "$remnawave_api_url"
  set_config_key "REMNAWAVE_API_TOKEN" "$remnawave_api_token"
  set_config_key "TG_ID_SOURCE" "$tg_id_source"
  set_config_key "TG_CUSTOM_MESSAGE" "$tg_custom_message"
  set_config_key "TG_USERNAME_SEPARATOR" "$tg_username_separator"

  echo ""
  echo -e "${CYAN}⚙️  Разворачиваем Telegram-мониторинг и статистику...${NC}"
  write_telegram_units_cli
  systemctl daemon-reload
  systemctl enable --now mobile443-monitor.service
  systemctl enable --now mobile443-stats.timer

  echo -e "${CYAN}🔁 Пересобираем правила с учётом новой конфигурации...${NC}"
  systemctl start mobile443-update.service || systemctl start mobile443-apply.service || true

  echo -e "${GREEN}✅ Telegram/Remnawave интеграция настроена.${NC}"
  pause
}

# ---------- 7) Полное удаление ----------
action_remove() {
  print_header
  echo -e "${RED}${BOLD}🗑️  Полное удаление mobile443${NC}"
  echo ""
  echo "Будут удалены: правила iptables, ipset, systemd-юниты,"
  echo "  ${BASE_DIR}, ${STATE_DIR} и сама консоль mobile443."
  echo ""
  read -r -p "Введите 'yes' для подтверждения: " confirm < /dev/tty
  if [[ "$confirm" != "yes" ]]; then
    echo "Отменено."
    pause
    return
  fi

  local -a remove_ports
  read -r -a remove_ports <<< "${PORTS:-443}"

  echo "[*] Остановка и отключение сервисов"
  local unit
  for unit in mobile443-monitor.service mobile443-stats.timer mobile443-stats.service \
              mobile443-update.timer mobile443-update.service mobile443-apply.service; do
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
  done

  echo "[*] Удаление правил iptables"
  local chain proto port
  for chain in INPUT FORWARD DOCKER-USER; do
    for proto in tcp udp; do
      for port in "${remove_ports[@]}"; do
        while iptables -C "$chain" -p "$proto" --dport "$port" -j "$CHAIN_NAME" 2>/dev/null; do
          iptables -D "$chain" -p "$proto" --dport "$port" -j "$CHAIN_NAME" || true
        done
      done
    done
  done

  iptables -F "$CHAIN_NAME" 2>/dev/null || true
  iptables -X "$CHAIN_NAME" 2>/dev/null || true
  iptables -F "$PRECHECK_CHAIN" 2>/dev/null || true
  iptables -X "$PRECHECK_CHAIN" 2>/dev/null || true

  echo "[*] Удаление ipset"
  ipset destroy "${IPSET_ALLOW_NAME}_tmp" 2>/dev/null || true
  ipset destroy "$IPSET_ALLOW_NAME" 2>/dev/null || true
  ipset destroy "${IPSET_GOV_NAME}_tmp" 2>/dev/null || true
  ipset destroy "$IPSET_GOV_NAME" 2>/dev/null || true
  ipset destroy "${IPSET_ANTISCANNER_NAME}_tmp" 2>/dev/null || true
  ipset destroy "$IPSET_ANTISCANNER_NAME" 2>/dev/null || true
  ipset destroy "$IPSET_DEFERRED_BLOCK_NAME" 2>/dev/null || true

  echo "[*] Удаление systemd юнитов"
  rm -f /etc/systemd/system/mobile443-apply.service
  rm -f /etc/systemd/system/mobile443-update.service
  rm -f /etc/systemd/system/mobile443-update.timer
  rm -f /etc/systemd/system/mobile443-monitor.service
  rm -f /etc/systemd/system/mobile443-stats.service
  rm -f /etc/systemd/system/mobile443-stats.timer
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true

  echo "[*] Удаление файлов"
  rm -f /usr/local/sbin/mobile443-common.sh
  rm -f /usr/local/sbin/mobile443-update.sh
  rm -f /usr/local/sbin/mobile443-apply-cache.sh
  rm -f /usr/local/sbin/mobile443-monitor.sh
  rm -f /usr/local/sbin/mobile443-stats.sh
  rm -rf "$BASE_DIR"
  rm -rf "$STATE_DIR"

  echo ""
  echo -e "${GREEN}[+] mobile443 удалён.${NC}"
  trap 'rm -f /usr/local/sbin/mobile443' EXIT
  exit 0
}

main_menu() {
  while true; do
    print_header
    echo "Порты: ${PORTS:-443} | Traffic Guard: ${ENABLE_TRAF_GUARD:-false} | Mobile allow: ${ENABLE_MOBILE_ALLOW:-false} | Telegram: ${ENABLE_TELEGRAM:-false}"
    echo ""
    echo "  1) 🔄 Обновить списки сейчас"
    echo "  2) ↩️  Вернуть ASN в полный пул"
    echo "  3) 🚫 Управление исключениями сетей"
    echo "  4) 🩺 Статус и диагностика"
    echo "  5) 📊 Статистика (как отправляет бот)"
    echo "  6) 🤖 Настроить Telegram / Remnawave"
    echo "  7) 🗑️  Удалить mobile443"
    echo "  0) Выход"
    echo ""
    read -r -p "Выберите пункт меню: " choice < /dev/tty
    case "$choice" in
      1) action_update_lists ;;
      2) action_restore_asn ;;
      3) action_manage_exclusions ;;
      4) action_status ;;
      5) action_show_stats ;;
      6) action_configure_telegram ;;
      7) action_remove ;;
      0) echo "До встречи!"; exit 0 ;;
      *) ;;
    esac
    reload_config
  done
}

main_menu
EOF
  chmod +x "${BIN_DIR}/mobile443"
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
  ipset destroy mobile443_deferred_block 2>/dev/null || true

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
  rm -f "${BIN_DIR}/mobile443"
  rm -rf "$BASE_DIR"
  rm -rf "$STATE_DIR"

  echo ""
  echo "[+] Удалено."
}

update_all() {
  require_root

  local backup_dir backup_config backup_asns target_profile existing_profile requested_profile
  local backup_asns_excluded backup_static_networks backup_excluded_networks
  requested_profile="$INSTALL_PROFILE"
  backup_dir="$(mktemp -d)"
  backup_config="${backup_dir}/config.conf"
  backup_asns="${backup_dir}/asns.conf"
  backup_asns_excluded="${backup_dir}/asns_excluded.conf"
  backup_static_networks="${backup_dir}/static_networks.conf"
  backup_excluded_networks="${backup_dir}/excluded_networks.conf"

  if [[ -f "$CONFIG_FILE" ]]; then
    install -m 0600 "$CONFIG_FILE" "$backup_config"
  fi
  if [[ -f "$ASNS_FILE" ]]; then
    install -m 0644 "$ASNS_FILE" "$backup_asns"
  fi
  if [[ -f "$ASNS_EXCLUDED_FILE" ]]; then
    install -m 0644 "$ASNS_EXCLUDED_FILE" "$backup_asns_excluded"
  fi
  if [[ -f "$STATIC_NETWORKS_FILE" ]]; then
    install -m 0644 "$STATIC_NETWORKS_FILE" "$backup_static_networks"
  fi
  if [[ -f "$EXCLUDED_NETWORKS_FILE" ]]; then
    install -m 0644 "$EXCLUDED_NETWORKS_FILE" "$backup_excluded_networks"
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
  normalize_restored_config "$backup_config" "$backup_asns" "$target_profile" \
    "$backup_asns_excluded" "$backup_static_networks" "$backup_excluded_networks"
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
