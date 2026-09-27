#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="install"
INSTALL_PROFILE="full"

BASE_DIR="/opt/mobile443"
STATE_DIR="/var/lib/mobile443"
BIN_DIR="/usr/local/sbin"
CONFIG_FILE="${BASE_DIR}/config.conf"
ASNS_FILE="${BASE_DIR}/asns.conf"
ASNS_EXCLUDED_FILE="${BASE_DIR}/asns_excluded.conf"
STATIC_NETWORKS_FILE="${BASE_DIR}/static_networks.conf"
EXCLUDED_NETWORKS_FILE="${BASE_DIR}/excluded_networks.conf"
MANUAL_ALLOW_FILE="${BASE_DIR}/manual_allow.conf"
REPO_RAW_DEFAULT="https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main"

DEFAULT_PORTS="443"

TRAF_GUARD_BASE_URL_DEFAULT="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public"
GOV_LIST_URL_DEFAULT="${TRAF_GUARD_BASE_URL_DEFAULT}/government_networks.list"
ANTISCANNER_LIST_URL_DEFAULT="${TRAF_GUARD_BASE_URL_DEFAULT}/antiscanner.list"

# jsDelivr-зеркало GitHub — используется как fallback, если основной
# raw.githubusercontent.com недоступен/таймаутится с хоста сервера.
TRAF_GUARD_BASE_URL_FALLBACK_DEFAULT="https://cdn.jsdelivr.net/gh/shadow-netlab/traffic-guard-lists@main/public"
GOV_LIST_URL_FALLBACK_DEFAULT="${TRAF_GUARD_BASE_URL_FALLBACK_DEFAULT}/government_networks.list"
ANTISCANNER_LIST_URL_FALLBACK_DEFAULT="${TRAF_GUARD_BASE_URL_FALLBACK_DEFAULT}/antiscanner.list"

# ---------------------------------------------------------------------------
# Параметры установки (флаги командной строки / переменные окружения M443_*).
# Каждый заданный параметр отвечает на соответствующий вопрос установщика;
# незаданные спрашиваются интерактивно, а в неинтерактивном режиме
# (-y / --yes или нет /dev/tty) берутся значения по умолчанию.
# ---------------------------------------------------------------------------
NONINTERACTIVE="${M443_YES:-0}"

usage() {
  cat <<'USAGE'
Использование:
  asn.sh [install|update|remove] [full|block-only] [параметры]

Параметры установки (любой можно пропустить — тогда будет задан вопрос):
  --ports "443 8443"          порты фильтрации (через пробел или запятую)
  --backend nftables|iptables движок файрвола
  --lists both|government|antiscanner
                              traffic-guard листы (только block-only)
  --telegram | --no-telegram  включить / выключить Telegram-уведомления
  --tg-token TOKEN            токен Telegram-бота (включает Telegram)
  --tg-admin ID               Telegram ID администратора
  --panel-url URL             адрес панели Remnawave
  --panel-token TOKEN         API-токен панели Remnawave
  --tg-id-source telegramId|username|custom
                              откуда брать Telegram ID пользователя
  --tg-separator SEP          разделитель в username (для custom, можно "")
  --tg-message TEXT           своё сообщение пользователю (HTML, {ip})
  --xray-log auto|none|PATH   access.log xray: найти / отключить / путь
  --manual-allow "CIDR,..."   добавить адреса в manual_allow.conf
  -y, --yes                   не задавать вопросов, остальное по умолчанию
  -h, --help                  эта справка

Те же значения можно передать переменными окружения:
  M443_PORTS M443_BACKEND M443_LISTS M443_TELEGRAM(y|n) M443_TG_TOKEN
  M443_TG_ADMIN M443_PANEL_URL M443_PANEL_TOKEN M443_TG_ID_SOURCE
  M443_TG_SEPARATOR M443_TG_MESSAGE M443_XRAY_LOG M443_MANUAL_ALLOW M443_YES=1
USAGE
}

die_usage() {
  echo "✖ $*" >&2
  echo "  Справка: asn.sh --help" >&2
  exit 2
}

opt_is_set() {
  [[ -n "${!1+set}" ]]
}

# Переносит M443_* из окружения в OPT_*; флаги командной строки разбираются
# позже и перекрывают окружение.
load_env_options() {
  local name src
  for name in PORTS BACKEND LISTS TELEGRAM TG_TOKEN TG_ADMIN PANEL_URL \
              PANEL_TOKEN TG_ID_SOURCE TG_SEPARATOR TG_MESSAGE XRAY_LOG MANUAL_ALLOW; do
    if opt_is_set "M443_${name}"; then
      src="M443_${name}"
      printf -v "OPT_${name}" '%s' "${!src}"
    fi
  done
}

# OPT_* читаются косвенно через ask_input/opt_is_set.
# shellcheck disable=SC2034
parse_args() {
  local positional=() arg value

  while [[ $# -gt 0 ]]; do
    arg="$1"
    value=""
    case "$arg" in
      --*=*)
        value="${arg#*=}"
        arg="${arg%%=*}"
        ;;
    esac

    case "$arg" in
      --ports|--backend|--lists|--tg-token|--tg-admin|--panel-url|--panel-token|\
      --tg-id-source|--tg-separator|--tg-message|--xray-log|--manual-allow)
        if [[ "$1" != *=* ]]; then
          [[ $# -ge 2 ]] || die_usage "Для ${arg} нужно значение"
          value="$2"
          shift
        fi
        case "$arg" in
          --ports)        OPT_PORTS="$value" ;;
          --backend)      OPT_BACKEND="$value" ;;
          --lists)        OPT_LISTS="$value" ;;
          --tg-token)     OPT_TG_TOKEN="$value" ;;
          --tg-admin)     OPT_TG_ADMIN="$value" ;;
          --panel-url)    OPT_PANEL_URL="$value" ;;
          --panel-token)  OPT_PANEL_TOKEN="$value" ;;
          --tg-id-source) OPT_TG_ID_SOURCE="$value" ;;
          --tg-separator) OPT_TG_SEPARATOR="$value" ;;
          --tg-message)   OPT_TG_MESSAGE="$value" ;;
          --xray-log)     OPT_XRAY_LOG="$value" ;;
          --manual-allow) OPT_MANUAL_ALLOW="$value" ;;
        esac
        ;;
      --telegram)    OPT_TELEGRAM="y" ;;
      --no-telegram) OPT_TELEGRAM="n" ;;
      -y|--yes|--non-interactive) NONINTERACTIVE="1" ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die_usage "Неизвестный параметр: $arg"
        ;;
      *)
        positional+=("$arg")
        ;;
    esac
    shift
  done

  if [[ ${#positional[@]} -gt 2 ]]; then
    die_usage "Лишние аргументы: ${positional[*]:2}"
  fi
  ACTION="${positional[0]:-install}"
  INSTALL_PROFILE="${positional[1]:-full}"
}

# Проверяет значения и переводит их в ответы на вопросы установщика.
# shellcheck disable=SC2034
normalize_options() {
  local p
  local -a _ports=() _allow=()

  if opt_is_set OPT_PORTS; then
    OPT_PORTS="${OPT_PORTS//,/ }"
    read -r -a _ports <<< "$OPT_PORTS"
    [[ ${#_ports[@]} -gt 0 ]] || die_usage "--ports: пустой список портов"
    for p in "${_ports[@]}"; do
      [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || die_usage "--ports: некорректный порт '$p'"
    done
    OPT_PORTS="${_ports[*]}"
  fi

  if opt_is_set OPT_BACKEND; then
    case "${OPT_BACKEND,,}" in
      nftables|nft|1) OPT_BACKEND="1" ;;
      iptables|ipt|ipset|2) OPT_BACKEND="2" ;;
      *) die_usage "--backend: ожидается nftables или iptables" ;;
    esac
  fi

  if opt_is_set OPT_LISTS; then
    case "${OPT_LISTS,,}" in
      both|all|1) OPT_LISTS="1" ;;
      government|gov|2) OPT_LISTS="2" ;;
      antiscanner|scan|3) OPT_LISTS="3" ;;
      *) die_usage "--lists: ожидается both, government или antiscanner" ;;
    esac
  fi

  if opt_is_set OPT_TELEGRAM; then
    case "${OPT_TELEGRAM,,}" in
      y|yes|true|1|on) OPT_TELEGRAM="y" ;;
      n|no|false|0|off) OPT_TELEGRAM="n" ;;
      *) die_usage "M443_TELEGRAM: ожидается y или n" ;;
    esac
  elif opt_is_set OPT_TG_TOKEN; then
    OPT_TELEGRAM="y"
  fi

  if opt_is_set OPT_TG_ID_SOURCE; then
    case "${OPT_TG_ID_SOURCE,,}" in
      telegramid|1) OPT_TG_ID_SOURCE="1" ;;
      username|2) OPT_TG_ID_SOURCE="2" ;;
      custom|username_custom|3) OPT_TG_ID_SOURCE="3" ;;
      *) die_usage "--tg-id-source: ожидается telegramId, username или custom" ;;
    esac
  elif opt_is_set OPT_TG_SEPARATOR; then
    OPT_TG_ID_SOURCE="3"
  fi

  if opt_is_set OPT_TG_MESSAGE; then
    OPT_TG_MSG_CHOICE="2"
  fi

  if opt_is_set OPT_XRAY_LOG; then
    case "$OPT_XRAY_LOG" in
      none|no|off|"") OPT_XRAY_CHOICE="n" ;;
      auto) OPT_XRAY_CHOICE="y" ;;
      /*)
        OPT_XRAY_CHOICE="y"
        OPT_XRAY_PATH="$OPT_XRAY_LOG"
        ;;
      *) die_usage "--xray-log: ожидается auto, none или абсолютный путь" ;;
    esac
  fi

  if opt_is_set OPT_MANUAL_ALLOW; then
    OPT_MANUAL_ALLOW="${OPT_MANUAL_ALLOW//,/ }"
    read -r -a _allow <<< "$OPT_MANUAL_ALLOW"
    for p in "${_allow[@]}"; do
      [[ "$p" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]] \
        || die_usage "--manual-allow: некорректный IPv4/CIDR '$p'"
    done
    OPT_MANUAL_ALLOW="${_allow[*]}"
  fi

  # Без терминала вопросы задать нельзя (запуск через ssh без -t,
  # ansible, cloud-init) — работаем неинтерактивно.
  if [[ "$NONINTERACTIVE" != "1" ]] && ! { : < /dev/tty; } 2>/dev/null; then
    NONINTERACTIVE="1"
  fi

  if [[ "$NONINTERACTIVE" == "1" && "$ACTION" == "install" && "$INSTALL_PROFILE" == "full" \
        && "${OPT_TELEGRAM:-n}" == "y" ]]; then
    for p in OPT_TG_TOKEN OPT_TG_ADMIN OPT_PANEL_URL OPT_PANEL_TOKEN; do
      opt_is_set "$p" && [[ -n "${!p}" ]] \
        || die_usage "Для Telegram без вопросов нужны --tg-token, --tg-admin, --panel-url и --panel-token"
    done
  fi
}

# ask_input VAR OPT_NAME PROMPT [secret]
# Значение берётся из параметра OPT_NAME, иначе спрашивается с /dev/tty.
# В неинтерактивном режиме незаданный параметр = пустой ответ = значение
# по умолчанию для этого вопроса.
ask_input() {
  local __target="$1" __opt="$2" __prompt="$3" __secret="${4:-}"

  if opt_is_set "$__opt"; then
    printf -v "$__target" '%s' "${!__opt}"
    if [[ -n "$__secret" ]]; then
      echo "${__prompt}******  (из параметров)"
    else
      echo "${__prompt}${!__opt}  (из параметров)"
    fi
    return 0
  fi

  if [[ "$NONINTERACTIVE" == "1" ]]; then
    printf -v "$__target" '%s' ""
    echo "${__prompt}(по умолчанию)"
    return 0
  fi

  # shellcheck disable=SC2229
  read -r -p "$__prompt" "$__target" < /dev/tty
}

# Добавляет адреса из --manual-allow в manual_allow.conf без дублей.
apply_opt_manual_allow() {
  local entry
  opt_is_set OPT_MANUAL_ALLOW || return 0
  [[ -n "$OPT_MANUAL_ALLOW" ]] || return 0

  for entry in $OPT_MANUAL_ALLOW; do
    [[ "$entry" == */* ]] || entry="${entry}/32"
    if grep -Eq "^[[:space:]]*${entry//./\\.}([[:space:]]|#|$)" "$MANUAL_ALLOW_FILE"; then
      echo "   = manual allow: $entry уже есть"
      continue
    fi
    printf '%s  # добавлено параметром --manual-allow\n' "$entry" >> "$MANUAL_ALLOW_FILE"
    echo "   + manual allow: $entry"
  done
}

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

# Проверяет введённый вручную путь к access.log. Файла может ещё не быть,
# но тогда пользователь должен явно это подтвердить: без access.log
# идентификация не работает и немобильные IP блокируются без уведомлений.
confirm_xray_log_path() {
  local path="$1" use_anyway

  if [[ -z "$path" ]]; then
    echo "   ⚠️  Путь не задан: пользователи не будут идентифицироваться,"
    echo "      немобильные IP будут блокироваться без Telegram-уведомлений."
    return 0
  fi
  if [[ -f "$path" ]]; then
    return 0
  fi

  echo "   ✖ Файл не найден: $path"
  echo "     Пока файла нет, идентификация не работает и немобильные IP"
  echo "     блокируются без Telegram-уведомлений."
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    echo "   Используем этот путь (неинтерактивный режим)."
    return 0
  fi
  read -r -p "   Использовать этот путь всё равно? (y/n): " use_anyway < /dev/tty
  [[ "${use_anyway,,}" == "y" ]]
}

detect_xray_log() {
  echo "🔍 Поиск access.log от xray/remnanode..."

  XRAY_ACCESS_LOG=""
  if opt_is_set OPT_XRAY_PATH; then
    XRAY_ACCESS_LOG="$OPT_XRAY_PATH"
    echo "   Путь из параметров: $XRAY_ACCESS_LOG"
    confirm_xray_log_path "$XRAY_ACCESS_LOG" || XRAY_ACCESS_LOG=""
    echo "   ✅ Используем: ${XRAY_ACCESS_LOG:-не задан}"
    return
  fi
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
    while true; do
      ask_input user_path OPT_NONE "   > "
      XRAY_ACCESS_LOG="${user_path:-$(echo "$found" | head -1)}"
      confirm_xray_log_path "$XRAY_ACCESS_LOG" && break
    done
    echo "   ✅ Используем: ${XRAY_ACCESS_LOG:-не задан}"
    return
  fi

  echo "   ⚠️  Автоматически не найден."
  echo "   Введите полный путь к access.log xray (Enter — пропустить):"
  while true; do
    ask_input XRAY_ACCESS_LOG OPT_NONE "   > "
    confirm_xray_log_path "$XRAY_ACCESS_LOG" && break
  done
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
FIREWALL_BACKEND="${FIREWALL_BACKEND:-nftables}"
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
TRAF_GUARD_BASE_URL_FALLBACK="${TRAF_GUARD_BASE_URL_FALLBACK_DEFAULT}"
GOV_LIST_URL_FALLBACK="${GOV_LIST_URL_FALLBACK_DEFAULT}"
ANTISCANNER_LIST_URL_FALLBACK="${ANTISCANNER_LIST_URL_FALLBACK_DEFAULT}"
EOF
  printf "TG_CUSTOM_MESSAGE=%q\n" "$tg_custom_message" >> "$CONFIG_FILE"
  printf "TG_USERNAME_SEPARATOR=%q\n" "$tg_username_separator" >> "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

ask_firewall_backend() {
  echo "🧱 Движок файрвола:"
  echo "   1) nftables (рекомендуется)"
  echo "   2) iptables + ipset"
  local fw_choice
  ask_input fw_choice OPT_BACKEND "   Выберите (1 или 2): "
  if [[ "$fw_choice" == "2" ]]; then
    FIREWALL_BACKEND="iptables"
  else
    FIREWALL_BACKEND="nftables"
  fi
  echo "   ✅ Движок: $FIREWALL_BACKEND"
  echo ""
}

interactive_setup_full() {
  local ports tg_choice enable_telegram tg_bot_token tg_admin_id
  local remnawave_api_url remnawave_api_token tg_id_source tg_username_separator
  local xray_access_log xray_logs_choice tg_id_source_choice tg_msg_choice tg_custom_message

  echo ""
  echo "╔═══════════════════════════════════════════════╗"
  echo "║        Настройка mobile443 фильтра            ║"
  echo "╚═══════════════════════════════════════════════╝"
  echo ""

  echo "📡 На каких портах должен работать фильтр?"
  echo "   Введите порты через пробел"
  echo "   Пример: 443 8443 9443 10443 11443 12443 13443"
  ask_input ports OPT_PORTS "   > "
  ports="${ports:-$DEFAULT_PORTS}"
  echo "   ✅ Порты: $ports"
  echo ""

  ask_firewall_backend

  echo "📱 Включить уведомления в Telegram? (y/n)"
  echo "   • Пользователям — уведомление при блокировке подключения"
  echo "   • Админу — ежедневная статистика блокировок"
  ask_input tg_choice OPT_TELEGRAM "   > "

  if [[ "${tg_choice,,}" == "y" ]]; then
    enable_telegram="true"

    echo ""
    echo "🤖 Введите токен Telegram бота:"
    ask_input tg_bot_token OPT_TG_TOKEN "   > " secret
    echo ""
    echo "👤 Введите Telegram ID администратора (для статистики):"
    ask_input tg_admin_id OPT_TG_ADMIN "   > "
    echo ""

    echo "🌐 Введите адрес панели Remnawave (например: https://panel.example.com):"
    ask_input remnawave_api_url OPT_PANEL_URL "   > "
    remnawave_api_url="${remnawave_api_url%/}"
    echo "   ✅ Панель: $remnawave_api_url"
    echo ""

    echo "🔑 Введите API токен Remnawave панели:"
    ask_input remnawave_api_token OPT_PANEL_TOKEN "   > " secret
    echo ""

    echo "📋 Откуда брать Telegram ID пользователя?"
    echo "   1) Из поля telegramId пользователя в API Remnawave"
    echo "   2) Из поля username — последнее значение после _"
    echo "   3) Из поля username — указать свой разделитель (или без него)"
    ask_input tg_id_source_choice OPT_TG_ID_SOURCE "   Выберите (1, 2 или 3): "

    if [[ "$tg_id_source_choice" == "3" ]]; then
      tg_id_source="username_custom"
      echo "   Введите символ-разделитель, после которого идет telegramID (например : или _ или -)."
      echo "   Оставьте пустым, если username и есть telegramID целиком:"
      ask_input tg_username_separator OPT_TG_SEPARATOR "   > "
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
    ask_input tg_msg_choice OPT_TG_MSG_CHOICE "   Выберите (1 или 2): "

    if [[ "$tg_msg_choice" == "2" ]]; then
      echo "   Напишите текст кастомного сообщения (в одну строку, для переноса строки пишите \n)."
      echo "   • Поддерживается HTML-разметка (например, <b>жирный текст</b>)."
      echo "   • Доступна переменная: {ip} - IP-адрес пользователя, с которого была попытка подключения"
      ask_input tg_custom_message OPT_TG_MESSAGE "   > "
      echo "   ✅ Кастомное сообщение сохранено."
    else
      tg_custom_message=""
      echo "   ✅ Будет использовано стандартное сообщение."
    fi
    echo ""

    echo "📝 Персональные уведомления пользователям работают через xray access.log:"
    echo "   соединение сначала пропускается до xray, monitor находит по IP email"
    echo "   пользователя в логе, блокирует IP и шлёт ему уведомление."
    echo "   Если логи xray ОТКЛЮЧЕНЫ — уведомления пользователям невозможны,"
    echo "   и немобильные IP будут блокироваться сразу на уровне nftables."
    echo "   Админ-алерты Traffic Guard и статистика работают в любом случае."
    echo ""
    echo "   Включено ли у вас логирование xray (access.log)? (y/n)"
    ask_input xray_logs_choice OPT_XRAY_CHOICE "   > "
    if [[ "${xray_logs_choice,,}" == "y" ]]; then
      detect_xray_log
      xray_access_log="${XRAY_ACCESS_LOG:-}"
    else
      xray_access_log=""
      echo "   ✅ Логи отключены: режим immediate — блокировка сразу в nftables."
    fi
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
  ask_input list_choice OPT_LISTS "   > "

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
  ask_input ports OPT_PORTS "   > "
  ports="${ports:-${PORTS:-$(default_ports_from_existing)}}"

  ask_firewall_backend

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
# Это не "идеально только мобильные": у MTS/MegaFon/Beeline мобайл и fixed
# broadband живут в одних ASN, полностью развести их на уровне ASN нельзя.
# v0.8: секции MTS/Beeline/MegaFon/T2 вычищены от мёртвых (0 анонсов),
# ЦОД/облачных, чисто-fixed ASN, иностранных и дублей (см. changelog в README).
# Остальные операторы (MVNO/региональные) — без изменений.
# Ростелеком (AS12389) по-прежнему точечно через static_networks.conf.

# MTS
8359

# Beeline / VimpelCom
3216
16345
42842

# MegaFon core + related
31133
47395
35298
31224
31213
31208
31205
31195
31163
25159

# T2 regional
12958
15378
42437
48092
48190
41330
39374

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
# Phoenix
214721
204108
# Sevtelecom
59833
47203


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

# === Прочие операторы (добавлено вручную, на проверке) ===
5.101.18.0/24
91.107.97.0/24
84.18.108.0/24
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

ensure_manual_allow_file() {
  if [[ -f "$MANUAL_ALLOW_FILE" ]]; then
    return
  fi

  cat > "$MANUAL_ALLOW_FILE" <<'EOF'
# === Ручной allow-лист ===
# Сети из этого файла ВСЕГДА получают ACCEPT на защищённых портах —
# раньше traf_guard-блоклистов и раньше проверки мобильного ASN.
# Используйте для доверенных адресов (например, свой домашний/офисный IP),
# которым нужен доступ не через мобильный интернет.
# Формат: один CIDR на строку (для одного IP используйте /32),
# комментарии через #.
# Управляется через консоль: sudo mobile443 -> "Ручной allow-лист"
EOF
  chmod 644 "$MANUAL_ALLOW_FILE"
}

strip_legacy_rostelecom_from_asns() {
  # Апгрейд поверх установки, где AS12389 ещё был активен в asns.conf:
  # normalize_restored_config сохраняет старый asns.conf как есть, поэтому
  # ASN нужно вычистить отдельно — asns_excluded.conf/static_networks.conf
  # к этому моменту уже создаются с нуля корректно.
  [[ -s "$ASNS_FILE" ]] || return 0
  grep -qE '^12389[[:space:]]*$' "$ASNS_FILE" || return 0

  echo "[*] Обнаружен активный AS12389 в существующем asns.conf — исключаем"
  echo "    (заменяется static_networks.conf, ASN сохранён в asns_excluded.conf)"

  local tmp
  tmp="$(mktemp)"
  grep -vE '^12389[[:space:]]*$' "$ASNS_FILE" > "$tmp"
  install -m 0644 "$tmp" "$ASNS_FILE"
  rm -f "$tmp"

  if [[ -f "${STATE_DIR}/prefixes.txt" ]]; then
    echo "[*] Сбрасываем кеш mobile allowlist (${STATE_DIR}/prefixes.txt) —"
    echo "    без AS12389 размер пула меньше, safe-check не должен сравнивать"
    echo "    новый результат со старым большим числом"
    rm -f "${STATE_DIR}/prefixes.txt"
  fi
}

install_packages() {
  local -a packages=(curl util-linux ca-certificates)

  if [[ "${FIREWALL_BACKEND:-nftables}" == "iptables" ]]; then
    packages+=(iptables ipset)
  else
    packages+=(nftables)
  fi

  if [[ "$INSTALL_PROFILE" == "full" ]]; then
    packages+=(jq)
  fi

  apt update -y || true
  apt install -y "${packages[@]}"
}

reset_config_vars() {
  unset INSTALL_PROFILE FIREWALL_BACKEND PORTS ENABLE_TRAF_GUARD ENABLE_TRAF_GUARD_GOVERNMENT \
    ENABLE_TRAF_GUARD_ANTISCANNER ENABLE_MOBILE_ALLOW ENABLE_TELEGRAM TG_ENABLED \
    TG_BOT_TOKEN TG_ADMIN_ID XRAY_ACCESS_LOG REMNAWAVE_API_URL REMNAWAVE_API_TOKEN \
    TG_ID_SOURCE TG_CUSTOM_MESSAGE TG_USERNAME_SEPARATOR TRAF_GUARD_BASE_URL GOV_LIST_URL ANTISCANNER_LIST_URL \
    TRAF_GUARD_BASE_URL_FALLBACK GOV_LIST_URL_FALLBACK ANTISCANNER_LIST_URL_FALLBACK
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
    strip_legacy_rostelecom_from_asns
  fi
  ensure_excluded_networks_file
  ensure_manual_allow_file
  apply_opt_manual_allow

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
  local restored_manual_allow="$7"
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

  # Путь к access.log остался с прошлой установки, но файла нет (логи xray
  # выключены или путь неверный) — чистим его, чтобы фильтр работал в
  # immediate-режиме и блокировал сразу, а не ждал идентификации, которая
  # никогда не произойдёт. Вернуть можно через консоль (пункт Telegram).
  if [[ -n "$xray_access_log" && ! -f "$xray_access_log" ]]; then
    echo "[*] xray access.log не найден: ${xray_access_log}"
    echo "    Переключаемся в immediate-режим — немобильные IP будут"
    echo "    блокироваться сразу. Путь можно задать заново:"
    echo "    sudo mobile443 -> \"Настроить Telegram / Remnawave\""
    xray_access_log=""
  fi

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

  if [[ -f "$restored_manual_allow" ]]; then
    install -m 0644 "$restored_manual_allow" "$MANUAL_ALLOW_FILE"
  else
    ensure_manual_allow_file
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
MANUAL_ALLOW_FILE="${BASE_DIR}/manual_allow.conf"
ALLOW_CACHE_FILE="${STATE_DIR}/prefixes.txt"
LOCK_FILE="${STATE_DIR}/lock"
RULESET_FILE="${STATE_DIR}/ruleset.nft"

# Вся фильтрация живёт в собственной nftables-таблице `ip mobile443`:
# её не трогают ни Docker, ни UFW, правила применяются атомарно через
# `nft -f` (если транзакция не прошла — прежние правила остаются),
# а hook forward матчит порт назначения ДО DNAT (ct original proto-dst),
# так что проброс портов в Docker bridge больше не проблема.
NFT_TABLE="mobile443"
SET_MANUAL_ALLOW="manual_allow"
SET_MOBILE_ALLOW="mobile_allow"
SET_GOV="tg_government"
SET_ANTISCANNER="tg_antiscanner"
SET_DEFERRED="deferred_block"
SET_LOG_LIMIT="log_limit"
SET_BLOCKED="blocked_ips"
CHAIN_INPUT="prefilter_input"
CHAIN_FORWARD="prefilter_forward"
CHAIN_FILTER="filter443"

# Backend selector (nftables|iptables). Read from config.conf; nftables default.
FIREWALL_BACKEND="${FIREWALL_BACKEND:-nftables}"
# iptables/ipset names — used only when FIREWALL_BACKEND=iptables
IPSET_MANUAL_ALLOW_NAME="manual_allow_443"
IPSET_MANUAL_ALLOW_TMP_NAME="${IPSET_MANUAL_ALLOW_NAME}_tmp"
IPSET_ALLOW_NAME="allowed_mobile_443"
IPSET_ALLOW_TMP_NAME="${IPSET_ALLOW_NAME}_tmp"
IPSET_GOV_NAME="traf_guard_government"
IPSET_GOV_TMP_NAME="${IPSET_GOV_NAME}_tmp"
IPSET_ANTISCANNER_NAME="traf_guard_antiscanner"
IPSET_ANTISCANNER_TMP_NAME="${IPSET_ANTISCANNER_NAME}_tmp"
IPSET_DEFERRED_BLOCK_NAME="mobile443_deferred_block"
IPT_PRECHECK_CHAIN="TRAF_GUARD_PRECHECK"
IPT_CHAIN_NAME="FILTER_MOBILE_443"

LOG_PREFIX="MOBILE443_BLOCK: "
GOV_LOG_PREFIX="MOBILE443_TG_GOV: "
ANTISCANNER_LOG_PREFIX="MOBILE443_TG_SCAN: "

GOV_LIST_FILE="${LISTS_DIR}/government_networks.list"
ANTISCANNER_LIST_FILE="${LISTS_DIR}/antiscanner.list"

TRAF_GUARD_BASE_URL="${TRAF_GUARD_BASE_URL:-https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public}"
GOV_LIST_URL="${GOV_LIST_URL:-${TRAF_GUARD_BASE_URL}/government_networks.list}"
ANTISCANNER_LIST_URL="${ANTISCANNER_LIST_URL:-${TRAF_GUARD_BASE_URL}/antiscanner.list}"

# jsDelivr-зеркало — используется как fallback, если основной источник
# (raw.githubusercontent.com) недоступен или таймаутится с этого хоста.
TRAF_GUARD_BASE_URL_FALLBACK="${TRAF_GUARD_BASE_URL_FALLBACK:-https://cdn.jsdelivr.net/gh/shadow-netlab/traffic-guard-lists@main/public}"
GOV_LIST_URL_FALLBACK="${GOV_LIST_URL_FALLBACK:-${TRAF_GUARD_BASE_URL_FALLBACK}/government_networks.list}"
ANTISCANNER_LIST_URL_FALLBACK="${ANTISCANNER_LIST_URL_FALLBACK:-${TRAF_GUARD_BASE_URL_FALLBACK}/antiscanner.list}"

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
  need_cmd flock
  if [[ "${FIREWALL_BACKEND:-nftables}" == "iptables" ]]; then
    need_cmd iptables
    need_cmd ipset
  else
    need_cmd nft
  fi
  if bool_is_true "$ENABLE_MOBILE_ALLOW"; then
    need_cmd jq
  fi
}

ensure_dirs() {
  mkdir -p "$BASE_DIR" "$STATE_DIR" "$LISTS_DIR"
}

# Режим deferred (пропустить первое соединение до xray, чтобы monitor нашёл
# пользователя в access.log, заблокировал и уведомил) возможен только когда
# включены Telegram-уведомления И задан путь к access.log. Если логи xray
# отключены (XRAY_ACCESS_LOG пуст) — идентифицировать пользователя нечем,
# и немобильные IP блокируются сразу на уровне nftables (immediate).
deferred_mode_enabled() {
  bool_is_true "$ENABLE_TELEGRAM" \
    && bool_is_true "$ENABLE_MOBILE_ALLOW" \
    && [[ -n "${XRAY_ACCESS_LOG:-}" ]]
}

# nft + immediate + без Telegram: статистика блокировок берётся из in-kernel
# счётчиков (counter в цепочке + per-IP набор blocked_ips), поэтому не нужны
# ни per-packet LOG, ни journal-тейлящий монитор — ~0 нагрузки на userspace CPU.
kernel_stats_mode() {
  [[ "${FIREWALL_BACKEND:-nftables}" != "iptables" ]] \
    && ! bool_is_true "$ENABLE_TELEGRAM"
}

# Идемпотентный скелет (таблица + deferred-набор) — для monitor, который
# может стартовать раньше полного применения правил.
ensure_nft_skeleton() {
  nft -f - <<NFTSKEL
add table ip ${NFT_TABLE}
add set ip ${NFT_TABLE} ${SET_DEFERRED} { type ipv4_addr; flags timeout; }
NFTSKEL
}

# iptables backend: deferred-block ipset must exist before monitor can add IPs
ensure_ipset_skeleton() {
  ipset create "$IPSET_DEFERRED_BLOCK_NAME" hash:ip family inet hashsize 4096 maxelem 65536 timeout 3600 -exist 2>/dev/null || true
}

# Backend-agnostic skeleton for the monitor (may start before full apply).
ensure_skeleton() {
  if [[ "${FIREWALL_BACKEND:-nftables}" == "iptables" ]]; then
    ensure_ipset_skeleton
  else
    ensure_nft_skeleton
  fi
}

# Число элементов набора — для статуса/статистики. Считаем записи,
# разделённые запятыми (одна запись — CIDR либо диапазон a.b.c.d-e.f.g.h,
# который auto-merge создаёт для сетей вне границ CIDR).
nft_set_count() {
  nft list set ip "$NFT_TABLE" "$1" 2>/dev/null \
    | sed -n '/elements = {/,/}/p' \
    | tr ',' '\n' \
    | grep -cE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
    | tr -d ' '
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

# Ручной allow-лист: manual_allow.conf -> валидированный список CIDR
# (по одному в строке). Применяется при каждой пересборке правил.
build_manual_allow_file() {
  local out="$1" line
  : > "$out"
  [[ -f "$MANUAL_ALLOW_FILE" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(echo "$line" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$line" ]] || continue
    validate_ipv4_cidr "$line" || {
      log "WARN manual_allow: skip invalid entry '${line}'"
      continue
    }
    echo "$line" >> "$out"
  done < "$MANUAL_ALLOW_FILE"
}

download_and_validate_list() {
  local url="$1"
  local destination="$2"
  local label="$3"
  local fallback_url="${4:-}"
  local raw_tmp clean_tmp line normalized valid_count old_count

  raw_tmp="$(mktemp)"
  clean_tmp="$(mktemp)"
  trap 'rm -f "$raw_tmp" "$clean_tmp"' RETURN

  log "Downloading ${label}: ${url}"
  if ! curl -fsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 "$url" -o "$raw_tmp"; then
    if [[ -n "$fallback_url" ]]; then
      log "WARN ${label}: основной источник недоступен, пробуем fallback: ${fallback_url}"
      if ! curl -fsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 "$fallback_url" -o "$raw_tmp"; then
        log "ERROR ${label}: не удалось скачать ни с основного источника, ни с fallback"
        return 1
      fi
    else
      log "ERROR ${label}: не удалось скачать список: ${url}"
      return 1
    fi
  fi

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

# flush набора + заливка элементов из файла (по одному CIDR в строке),
# порциями по 500 элементов на строку. Пишется в stdout как часть
# транзакции nft -f.
emit_set_refill() {
  local set_name="$1" file="$2"
  local -a batch=()
  local line joined

  echo "flush set ip ${NFT_TABLE} ${set_name}"
  [[ -s "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    batch+=("$line")
    if (( ${#batch[@]} >= 500 )); then
      printf -v joined '%s, ' "${batch[@]}"
      echo "add element ip ${NFT_TABLE} ${set_name} { ${joined%, } }"
      batch=()
    fi
  done < "$file"

  if (( ${#batch[@]} > 0 )); then
    printf -v joined '%s, ' "${batch[@]}"
    echo "add element ip ${NFT_TABLE} ${set_name} { ${joined%, } }"
  fi
}

# Полный набор правил как ОДНА атомарная транзакция nft -f: если любая
# часть не применится, прежние правила останутся нетронутыми. Содержимое
# наборов берётся из локальных файлов (gov/antiscanner-листы, кеш
# mobile-allowlist, manual_allow.conf). deferred_block не трогается —
# блокировки монитора переживают пересборку.
build_ruleset() {
  local out="$1"
  local ports manual_tmp
  printf -v ports '%s, ' "${PORT_LIST[@]}"
  ports="${ports%, }"

  manual_tmp="$(mktemp)"
  build_manual_allow_file "$manual_tmp"

  {
    echo "add table ip ${NFT_TABLE}"
    echo "add set ip ${NFT_TABLE} ${SET_MANUAL_ALLOW} { type ipv4_addr; flags interval; auto-merge; }"
    echo "add set ip ${NFT_TABLE} ${SET_MOBILE_ALLOW} { type ipv4_addr; flags interval; auto-merge; }"
    echo "add set ip ${NFT_TABLE} ${SET_GOV} { type ipv4_addr; flags interval; auto-merge; }"
    echo "add set ip ${NFT_TABLE} ${SET_ANTISCANNER} { type ipv4_addr; flags interval; auto-merge; }"
    echo "add set ip ${NFT_TABLE} ${SET_DEFERRED} { type ipv4_addr; flags timeout; }"
    # per-IP лимит LOG-строк: один активный поток не съедает бюджет
    # логирования других IP (в deferred-режиме блокировка начинается
    # именно с LOG-строки)
    echo "add set ip ${NFT_TABLE} ${SET_LOG_LIMIT} { type ipv4_addr; flags dynamic; timeout 2m; size 65536; }"
    # per-IP учёт заблокированных (immediate без Telegram) — считает ядро,
    # читается по требованию для статистики; ограничен size + timeout
    echo "add set ip ${NFT_TABLE} ${SET_BLOCKED} { type ipv4_addr; flags dynamic,timeout; timeout 10m; size 65536; }"
    # priority -10: раньше цепочек Docker/UFW (priority 0). accept у нас
    # не обходит их фильтры (в nftables пакет всё равно пройдёт остальные
    # hook-цепочки), а drop — окончателен.
    echo "add chain ip ${NFT_TABLE} ${CHAIN_INPUT} { type filter hook input priority -10; policy accept; }"
    echo "add chain ip ${NFT_TABLE} ${CHAIN_FORWARD} { type filter hook forward priority -10; policy accept; }"
    echo "add chain ip ${NFT_TABLE} ${CHAIN_FILTER}"
    echo "flush chain ip ${NFT_TABLE} ${CHAIN_INPUT}"
    echo "flush chain ip ${NFT_TABLE} ${CHAIN_FORWARD}"
    echo "flush chain ip ${NFT_TABLE} ${CHAIN_FILTER}"

    emit_set_refill "$SET_MANUAL_ALLOW" "$manual_tmp"

    if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_GOVERNMENT" && [[ -s "$GOV_LIST_FILE" ]]; then
      emit_set_refill "$SET_GOV" "$GOV_LIST_FILE"
    fi
    if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_ANTISCANNER" && [[ -s "$ANTISCANNER_LIST_FILE" ]]; then
      emit_set_refill "$SET_ANTISCANNER" "$ANTISCANNER_LIST_FILE"
    fi
    if bool_is_true "$ENABLE_MOBILE_ALLOW" && [[ -s "$ALLOW_CACHE_FILE" ]]; then
      emit_set_refill "$SET_MOBILE_ALLOW" "$ALLOW_CACHE_FILE"
    fi

    # Входные точки: input — обычный dport (host-network/без NAT);
    # forward — порт назначения ДО DNAT через conntrack, чтобы работал
    # любой проброс портов в Docker bridge (hostPort != containerPort).
    echo "add rule ip ${NFT_TABLE} ${CHAIN_INPUT} tcp dport { ${ports} } jump ${CHAIN_FILTER}"
    echo "add rule ip ${NFT_TABLE} ${CHAIN_INPUT} udp dport { ${ports} } jump ${CHAIN_FILTER}"
    echo "add rule ip ${NFT_TABLE} ${CHAIN_FORWARD} meta l4proto { tcp, udp } ct original proto-dst { ${ports} } jump ${CHAIN_FILTER}"

    # Ручной allow-лист — accept раньше traf_guard-блоклистов и мобильного ASN.
    echo "add rule ip ${NFT_TABLE} ${CHAIN_FILTER} ip saddr @${SET_MANUAL_ALLOW} counter accept"

    if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_GOVERNMENT"; then
      if ! kernel_stats_mode; then
        echo "add rule ip ${NFT_TABLE} ${CHAIN_FILTER} ip saddr @${SET_GOV} update @${SET_LOG_LIMIT} { ip saddr limit rate 6/minute burst 8 packets } log prefix \"${GOV_LOG_PREFIX}\" level warn"
      fi
      echo "add rule ip ${NFT_TABLE} ${CHAIN_FILTER} ip saddr @${SET_GOV} counter drop"
    fi
    if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_ANTISCANNER"; then
      if ! kernel_stats_mode; then
        echo "add rule ip ${NFT_TABLE} ${CHAIN_FILTER} ip saddr @${SET_ANTISCANNER} update @${SET_LOG_LIMIT} { ip saddr limit rate 6/minute burst 8 packets } log prefix \"${ANTISCANNER_LOG_PREFIX}\" level warn"
      fi
      echo "add rule ip ${NFT_TABLE} ${CHAIN_FILTER} ip saddr @${SET_ANTISCANNER} counter drop"
    fi

    if bool_is_true "$ENABLE_MOBILE_ALLOW"; then
      echo "add rule ip ${NFT_TABLE} ${CHAIN_FILTER} ip saddr @${SET_MOBILE_ALLOW} counter accept"

      if deferred_mode_enabled; then
        # deferred: уже заблокированные монитором IP — drop; остальные
        # немобильные логируются и пропускаются до xray, чтобы monitor
        # нашёл пользователя в access.log (fail-closed: заблокирует даже
        # если не нашёл)
        echo "add rule ip ${NFT_TABLE} ${CHAIN_FILTER} ip saddr @${SET_DEFERRED} counter drop"
        echo "add rule ip ${NFT_TABLE} ${CHAIN_FILTER} update @${SET_LOG_LIMIT} { ip saddr limit rate 6/minute burst 8 packets } log prefix \"${LOG_PREFIX}\" level warn"
        echo "add rule ip ${NFT_TABLE} ${CHAIN_FILTER} counter accept"
      elif kernel_stats_mode; then
        # immediate без Telegram: считаем в ядре — per-IP в blocked_ips (для
        # топа) + общий counter, без per-packet LOG и без монитора
        echo "add rule ip ${NFT_TABLE} ${CHAIN_FILTER} update @${SET_BLOCKED} { ip saddr counter } counter drop"
      else
        # immediate + Telegram: LOG нужен монитору для админ-алертов
        echo "add rule ip ${NFT_TABLE} ${CHAIN_FILTER} update @${SET_LOG_LIMIT} { ip saddr limit rate 6/minute burst 8 packets } log prefix \"${LOG_PREFIX}\" level warn"
        echo "add rule ip ${NFT_TABLE} ${CHAIN_FILTER} counter drop"
      fi
    fi
    # block-only: после traf_guard-проверок конец цепочки = return,
    # трафик проходит дальше (policy accept)
  } > "$out"

  rm -f "$manual_tmp"
}

apply_rules_nft() {
  ensure_dirs
  build_ruleset "$RULESET_FILE"
  nft -f "$RULESET_FILE"
  if deferred_mode_enabled; then
    log "nftables: правила применены (таблица ip ${NFT_TABLE}, режим deferred)"
  else
    log "nftables: правила применены (таблица ip ${NFT_TABLE}, режим immediate)"
  fi
}

# ---------------------------------------------------------------------------
# iptables + ipset backend (FIREWALL_BACKEND=iptables). Mirrors the nftables
# filter443 chain: manual_allow -> gov/antiscanner drop -> mobile_allow ->
# immediate drop (or deferred pass-through). Only the configured ports are
# hooked, so SSH and other ports are never touched.
# ---------------------------------------------------------------------------
ensure_set_pair() {
  ipset create "$1" hash:net family inet hashsize 65536 maxelem 524288 -exist
  ipset create "$2" hash:net family inet hashsize 65536 maxelem 524288 -exist
}

ensure_ipsets() {
  ensure_set_pair "$IPSET_MANUAL_ALLOW_NAME" "$IPSET_MANUAL_ALLOW_TMP_NAME"
  if bool_is_true "$ENABLE_TRAF_GUARD"; then
    bool_is_true "$ENABLE_TRAF_GUARD_GOVERNMENT" && ensure_set_pair "$IPSET_GOV_NAME" "$IPSET_GOV_TMP_NAME"
    bool_is_true "$ENABLE_TRAF_GUARD_ANTISCANNER" && ensure_set_pair "$IPSET_ANTISCANNER_NAME" "$IPSET_ANTISCANNER_TMP_NAME"
  fi
  bool_is_true "$ENABLE_MOBILE_ALLOW" && ensure_set_pair "$IPSET_ALLOW_NAME" "$IPSET_ALLOW_TMP_NAME"
  ipset create "$IPSET_DEFERRED_BLOCK_NAME" hash:ip family inet hashsize 4096 maxelem 65536 timeout 3600 -exist
}

# Load a set atomically: fill tmp set from file, swap into the live set.
rebuild_ipset_from_file() {
  local target_set="$1" tmp_set="$2" file="$3" label="$4" prefix
  ipset flush "$tmp_set" 2>/dev/null || true
  if [[ -s "$file" ]]; then
    while IFS= read -r prefix || [[ -n "$prefix" ]]; do
      [[ -n "$prefix" ]] || continue
      ipset add "$tmp_set" "$prefix" -exist 2>/dev/null || true
    done < "$file"
  fi
  ipset swap "$tmp_set" "$target_set"
  ipset flush "$tmp_set" 2>/dev/null || true
  log "ipset ${target_set} refilled (${label})"
}

ipt_delete_jump() {
  local chain="$1" proto="$2" port="$3"
  while iptables -C "$chain" -p "$proto" --dport "$port" -j "$IPT_CHAIN_NAME" 2>/dev/null; do
    iptables -D "$chain" -p "$proto" --dport "$port" -j "$IPT_CHAIN_NAME" || break
  done
}

ipt_prepare_chains() {
  local hl="-m hashlimit --hashlimit-mode srcip --hashlimit-upto 6/min --hashlimit-burst 8"

  iptables -N "$IPT_PRECHECK_CHAIN" 2>/dev/null || true
  iptables -F "$IPT_PRECHECK_CHAIN"
  if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_GOVERNMENT"; then
    iptables -A "$IPT_PRECHECK_CHAIN" -m set --match-set "$IPSET_GOV_NAME" src \
      $hl --hashlimit-name mob443_gov -j LOG --log-prefix "$GOV_LOG_PREFIX" --log-level 4
    iptables -A "$IPT_PRECHECK_CHAIN" -m set --match-set "$IPSET_GOV_NAME" src -j DROP
  fi
  if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_ANTISCANNER"; then
    iptables -A "$IPT_PRECHECK_CHAIN" -m set --match-set "$IPSET_ANTISCANNER_NAME" src \
      $hl --hashlimit-name mob443_scan -j LOG --log-prefix "$ANTISCANNER_LOG_PREFIX" --log-level 4
    iptables -A "$IPT_PRECHECK_CHAIN" -m set --match-set "$IPSET_ANTISCANNER_NAME" src -j DROP
  fi

  iptables -N "$IPT_CHAIN_NAME" 2>/dev/null || true
  iptables -F "$IPT_CHAIN_NAME"
  iptables -A "$IPT_CHAIN_NAME" -m set --match-set "$IPSET_MANUAL_ALLOW_NAME" src -j ACCEPT
  iptables -A "$IPT_CHAIN_NAME" -j "$IPT_PRECHECK_CHAIN"
  if bool_is_true "$ENABLE_MOBILE_ALLOW"; then
    iptables -A "$IPT_CHAIN_NAME" -m set --match-set "$IPSET_ALLOW_NAME" src -j ACCEPT
    if deferred_mode_enabled; then
      iptables -A "$IPT_CHAIN_NAME" -m set --match-set "$IPSET_DEFERRED_BLOCK_NAME" src -j DROP
      iptables -A "$IPT_CHAIN_NAME" $hl --hashlimit-name mob443_blk -j LOG --log-prefix "$LOG_PREFIX" --log-level 4
      iptables -A "$IPT_CHAIN_NAME" -j ACCEPT
    else
      iptables -A "$IPT_CHAIN_NAME" $hl --hashlimit-name mob443_blk -j LOG --log-prefix "$LOG_PREFIX" --log-level 4
      iptables -A "$IPT_CHAIN_NAME" -j DROP
    fi
  else
    iptables -A "$IPT_CHAIN_NAME" -j RETURN
  fi
}

ipt_attach_chain() {
  local chain port
  for port in "${PORT_LIST[@]}"; do
    for chain in INPUT FORWARD; do
      ipt_delete_jump "$chain" tcp "$port"
      ipt_delete_jump "$chain" udp "$port"
      iptables -I "$chain" 1 -p tcp --dport "$port" -j "$IPT_CHAIN_NAME"
      iptables -I "$chain" 1 -p udp --dport "$port" -j "$IPT_CHAIN_NAME"
    done
    if iptables -nL DOCKER-USER >/dev/null 2>&1; then
      ipt_delete_jump DOCKER-USER tcp "$port"
      ipt_delete_jump DOCKER-USER udp "$port"
      iptables -I DOCKER-USER 1 -p tcp --dport "$port" -j "$IPT_CHAIN_NAME"
      iptables -I DOCKER-USER 1 -p udp --dport "$port" -j "$IPT_CHAIN_NAME"
    fi
  done
}

apply_rules_ipt() {
  ensure_dirs
  ensure_ipsets

  local manual_tmp
  manual_tmp="$(mktemp)"
  build_manual_allow_file "$manual_tmp"
  rebuild_ipset_from_file "$IPSET_MANUAL_ALLOW_NAME" "$IPSET_MANUAL_ALLOW_TMP_NAME" "$manual_tmp" "manual allow"
  rm -f "$manual_tmp"

  if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_GOVERNMENT" && [[ -s "$GOV_LIST_FILE" ]]; then
    rebuild_ipset_from_file "$IPSET_GOV_NAME" "$IPSET_GOV_TMP_NAME" "$GOV_LIST_FILE" "government"
  fi
  if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_ANTISCANNER" && [[ -s "$ANTISCANNER_LIST_FILE" ]]; then
    rebuild_ipset_from_file "$IPSET_ANTISCANNER_NAME" "$IPSET_ANTISCANNER_TMP_NAME" "$ANTISCANNER_LIST_FILE" "antiscanner"
  fi
  if bool_is_true "$ENABLE_MOBILE_ALLOW" && [[ -s "$ALLOW_CACHE_FILE" ]]; then
    rebuild_ipset_from_file "$IPSET_ALLOW_NAME" "$IPSET_ALLOW_TMP_NAME" "$ALLOW_CACHE_FILE" "mobile allow"
  fi

  ipt_prepare_chains
  ipt_attach_chain

  if deferred_mode_enabled; then
    log "iptables: правила применены (chain ${IPT_CHAIN_NAME}, режим deferred)"
  else
    log "iptables: правила применены (chain ${IPT_CHAIN_NAME}, режим immediate)"
  fi
}

apply_rules() {
  if [[ "${FIREWALL_BACKEND:-nftables}" == "iptables" ]]; then
    apply_rules_ipt
  else
    apply_rules_nft
  fi
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

if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_GOVERNMENT"; then
  download_and_validate_list "$GOV_LIST_URL" "$GOV_LIST_FILE" "government_networks" "${GOV_LIST_URL_FALLBACK:-}"
fi

if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_ANTISCANNER"; then
  download_and_validate_list "$ANTISCANNER_LIST_URL" "$ANTISCANNER_LIST_FILE" "antiscanner" "${ANTISCANNER_LIST_URL_FALLBACK:-}"
fi

if bool_is_true "$ENABLE_MOBILE_ALLOW"; then
  update_mobile_allowlist
fi

# Всё скачанное лежит в локальных файлах — применяем одной nft-транзакцией
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

if bool_is_true "$ENABLE_MOBILE_ALLOW" && [[ ! -s "$ALLOW_CACHE_FILE" ]]; then
  log "WARN mobile allowlist cache not found: $ALLOW_CACHE_FILE (набор будет пуст до первого обновления)"
fi

# build_ruleset читает все списки из локальных файлов — сеть не нужна
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
INFLIGHT_DIR="${STATE_DIR}/inflight"
NOTIFY_COOLDOWN=21600
ADMIN_ALERT_COOLDOWN=1800
DEFERRED_BLOCK_TIMEOUT=3600
DEFERRED_BLOCK_UNIDENTIFIED_TIMEOUT=600
MAX_PARALLEL_EVENTS=8

mkdir -p "$STATE_DIR"
# Маркеры "IP уже обрабатывается" от прошлого запуска больше не актуальны
rm -rf "$INFLIGHT_DIR"
mkdir -p "$INFLIGHT_DIR"
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
  local timeout="${2:-$DEFERRED_BLOCK_TIMEOUT}"

  if [[ "${FIREWALL_BACKEND:-nftables}" == "iptables" ]]; then
    # ipset -exist обновляет timeout существующей записи
    if ipset add "$IPSET_DEFERRED_BLOCK_NAME" "$ip" timeout "$timeout" -exist 2>/dev/null; then
      log "Added ${ip} to deferred block set for ${timeout}s"
    else
      log "WARN: failed to add ${ip} to ipset '${IPSET_DEFERRED_BLOCK_NAME}'"
    fi
    return
  fi

  # nft add element падает, если элемент уже есть — сначала удаляем
  # (заодно обновляется timeout существующей блокировки)
  nft delete element ip "$NFT_TABLE" "$SET_DEFERRED" "{ ${ip} }" 2>/dev/null || true
  if nft add element ip "$NFT_TABLE" "$SET_DEFERRED" "{ ${ip} timeout ${timeout}s }" 2>/dev/null; then
    log "Added ${ip} to deferred block set for ${timeout}s"
  else
    log "WARN: failed to add ${ip} to nft set '${SET_DEFERRED}'"
  fi
}

find_user_by_ip_with_retry() {
  local ip="$1"
  local retries=5
  local delay=2
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
  local email api_response has_response tg_id msg

  [[ "${ENABLE_TELEGRAM:-false}" == "true" ]] || return 0

  # immediate-режим (логи xray отключены): блокирует сам nftables,
  # монитору здесь делать нечего — статистика уже записана
  deferred_mode_enabled || return 0

  # Событие из бэклога: IP уже заблокирован — повторная обработка не нужна
  if nft get element ip "$NFT_TABLE" "$SET_DEFERRED" "{ ${src_ip} }" >/dev/null 2>&1; then
    return 0
  fi

  email=""
  if [[ -n "${XRAY_ACCESS_LOG:-}" && -f "${XRAY_ACCESS_LOG:-}" ]]; then
    # Wait for the IP to appear in xray access.log (connection is allowed through first)
    email=$(find_user_by_ip_with_retry "$src_ip")
  fi

  if [[ -z "$email" ]]; then
    # Fail-closed: пользователя определить не удалось (нет access.log, xray
    # не пишет email, зонд/сканер без аутентификации) — блокируем всё
    # равно, иначе фильтр остаётся открытым для всех неопознанных IP.
    # Таймаут короче обычного: если запись в логе просто запоздала, у
    # клиента будет шанс идентифицироваться при следующей попытке.
    add_to_deferred_block "$src_ip" "$DEFERRED_BLOCK_UNIDENTIFIED_TIMEOUT"
    log "Blocked ${src_ip}:${dst_port} without identification (no email found, XRAY_ACCESS_LOG=${XRAY_ACCESS_LOG:-<not set>})"
    return
  fi

  # Блокируем сразу после идентификации, до медленных запросов к API
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

  [[ "${ENABLE_TELEGRAM:-false}" == "true" ]] || return 0
  [[ -n "${TG_ADMIN_ID:-}" ]] || return 0

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

# Обработка события в фоне: очередь kernel-логов не должна стоять из-за
# sleep'ов и curl'ов в обработчиках (иначе при потоке событий блокировка
# отстаёт на минуты). На каждый IP — не больше одного обработчика
# одновременно; число параллельных обработчиков ограничено.
spawn_event_handler() {
  local kind="$1" ip="$2" port="$3" reason="${4:-}"
  local marker="${INFLIGHT_DIR}/${kind}${reason:+_${reason}}_${ip}"

  # Статистика пишется для каждого события, независимо от Telegram
  echo "$(date '+%F %T') ${ip} ${port}${reason:+ ${reason}}" >> "$STATS_BLOCKED_FILE"

  [[ "${ENABLE_TELEGRAM:-false}" == "true" ]] || return 0

  if ! mkdir "$marker" 2>/dev/null; then
    return 0
  fi

  while (( $(jobs -rp | wc -l) >= MAX_PARALLEL_EVENTS )); do
    wait -n || true
  done

  (
    trap 'rmdir "$marker" 2>/dev/null || true' EXIT
    if [[ "$kind" == "blocked" ]]; then
      process_blocked "$ip" "$port" || true
    else
      process_traf_guard_alert "$ip" "$port" "$reason" || true
    fi
  ) &
}

ensure_dirs
ensure_skeleton

if [[ "${ENABLE_TELEGRAM:-false}" == "true" ]]; then
  if [[ -z "${XRAY_ACCESS_LOG:-}" ]]; then
    log "Логи xray не настроены (XRAY_ACCESS_LOG пуст): персональные уведомления отключены,"
    log "немобильные IP блокируются сразу на уровне nftables (immediate-режим)."
    log "Админ-алерты Traffic Guard и статистика работают как обычно."
  elif [[ ! -f "${XRAY_ACCESS_LOG}" ]]; then
    log "WARN: XRAY_ACCESS_LOG='${XRAY_ACCESS_LOG}' задан, но файл не найден."
    log "WARN: идентификация пользователей невозможна — IP блокируются без уведомлений (fail-closed)."
    if [[ -n "${TG_ADMIN_ID:-}" ]]; then
      send_tg "$TG_ADMIN_ID" "⚠️ <b>mobile443</b>: файл xray access.log (<code>${XRAY_ACCESS_LOG}</code>) не найден на сервере.

Идентификация пользователей не работает — немобильные IP блокируются <b>без</b> Telegram-уведомлений.

Проверьте путь XRAY_ACCESS_LOG в <code>/opt/mobile443/config.conf</code> и монтирование лога из контейнера ноды. Если логи xray отключены намеренно — очистите XRAY_ACCESS_LOG в конфиге, и фильтр перейдёт в immediate-режим без этого предупреждения."
    fi
  fi
fi

log "Monitor started, watching for blocked connections..."

get_log_stream | while IFS= read -r line; do
  if [[ "$line" == *"$LOG_PREFIX"* || "$line" == *"$GOV_LOG_PREFIX"* || "$line" == *"$ANTISCANNER_LOG_PREFIX"* ]]; then
    src_ip=""
    dst_port=""

    if [[ "$line" =~ SRC=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
      src_ip="${BASH_REMATCH[1]}"
    fi

    if [[ "$line" =~ DPT=([0-9]+) ]]; then
      dst_port="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$src_ip" && -n "$dst_port" ]]; then
      if [[ "$line" == *"$GOV_LOG_PREFIX"* ]]; then
        spawn_event_handler traf_guard "$src_ip" "$dst_port" "government_networks"
      elif [[ "$line" == *"$ANTISCANNER_LOG_PREFIX"* ]]; then
        spawn_event_handler traf_guard "$src_ip" "$dst_port" "antiscanner"
      else
        spawn_event_handler blocked "$src_ip" "$dst_port"
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

allow_count=$(nft_set_count "$SET_MOBILE_ALLOW") || allow_count="N/A"
gov_count=$(nft_set_count "$SET_GOV") || gov_count="N/A"
antiscanner_count=$(nft_set_count "$SET_ANTISCANNER") || antiscanner_count="N/A"

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

  cat > "${BIN_DIR}/mobile443-nettune.sh" <<'EOF'
#!/usr/bin/env bash
# Distribute inbound packet processing (RX softirq) across all CPU cores.
# On a host with a single NIC queue every packet is processed on one core;
# under a high packet rate that core saturates (ksoftirqd at 100%) and adds
# latency to everything else on the box, SSH included. RPS spreads the RX work
# across cores, RFS keeps each flow on the core running its consumer.
# No errexit: this is best-effort tuning — a single unavailable sysfs knob or
# an empty grep (via pipefail) must not abort the whole run.
set -uo pipefail

log() { echo "[$(date '+%F %T')] nettune: $*"; }

primary_iface() {
  local dev
  dev="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)"
  [[ -n "$dev" ]] && { echo "$dev"; return; }
  ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}'
}

IFACE="$(primary_iface)"
[[ -n "${IFACE:-}" ]] || { log "no interface found, nothing to do"; exit 0; }

NCPU="$(nproc)"
(( NCPU > 1 )) || { log "single cpu — RPS not needed"; exit 0; }

# full bitmask over all cores
full_mask=0
for ((i=0; i<NCPU; i++)); do full_mask=$(( full_mask | (1 << i) )); done

# core currently taking the NIC hardirq — exclude it from RPS so we don't pile
# softirq back onto the core already busy with napi/hardirq
irq_core=-1
irq_line="$(grep -iE "${IFACE}\b|virtio.*input" /proc/interrupts 2>/dev/null | head -1)"
if [[ -n "$irq_line" ]]; then
  irq_core="$(awk -v n="$NCPU" '{m=-1;idx=-1;for(i=2;i<=n+1;i++){v=$i+0;if(v>m){m=v;idx=i-2}}print idx}' <<< "$irq_line")"
fi

rps_mask=$full_mask
if [[ "$irq_core" =~ ^[0-9]+$ ]] && (( irq_core >= 0 )); then
  rps_mask=$(( full_mask & ~(1 << irq_core) ))
  (( rps_mask != 0 )) || rps_mask=$full_mask
fi
printf -v rps_hex '%x' "$rps_mask"

# count rx queues; only steer with RPS when the NIC has fewer queues than cores
rxq=0
for q in /sys/class/net/"$IFACE"/queues/rx-*; do [[ -d "$q" ]] && rxq=$((rxq+1)); done
(( rxq > 0 )) || { log "iface=$IFACE has no rx queues in sysfs"; exit 0; }

# global RFS flow table (per-queue tables must sum to <= this value)
sock_entries=32768
echo "$sock_entries" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
per_queue_flows=$(( sock_entries / rxq ))
(( per_queue_flows >= 256 )) || per_queue_flows=256

tuned=0
for q in /sys/class/net/"$IFACE"/queues/rx-*; do
  if (( rxq < NCPU )) && [[ -w "$q/rps_cpus" ]]; then
    echo "$rps_hex" > "$q/rps_cpus" 2>/dev/null && tuned=$((tuned+1))
  fi
  [[ -w "$q/rps_flow_cnt" ]] && { echo "$per_queue_flows" > "$q/rps_flow_cnt" 2>/dev/null || true; }
done

log "iface=$IFACE cpus=$NCPU rx_queues=$rxq irq_core=$irq_core rps_cpus=0x$rps_hex rfs_flows/q=$per_queue_flows queues_steered=$tuned"
EOF
  chmod +x "${BIN_DIR}/mobile443-nettune.sh"

  # sysctl profile for high packet-rate hosts: bigger backlog and a larger
  # softirq budget so a burst is drained in-line instead of spilling into
  # ksoftirqd, plus basic SYN-flood resilience. Persisted across reboots.
  cat > /etc/sysctl.d/99-mobile443-net.conf <<'EOF'
# mobile443 network tuning — high packet-rate hosts
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.rps_sock_flow_entries = 32768
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
EOF
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
  echo -e "${CYAN}↩️  Вернуть ASN в полный пул${NC}"
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

  local selected asn_num

  if (( ${#entries[@]} == 1 )); then
    # Единственный исключённый ASN — работаем как одна кнопка, без выбора из списка.
    selected="${entries[0]}"
    asn_num="$(echo "$selected" | awk '{print $1}')"
    echo "Найден один исключённый ASN:"
    echo "  ${selected}"
    echo ""
    read -r -p "Вернуть AS${asn_num} целиком в пул и сразу обновить списки? (y/n): " confirm < /dev/tty
    if [[ "${confirm,,}" != "y" ]]; then
      return
    fi
  else
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

    selected="${entries[$((choice-1))]}"
    asn_num="$(echo "$selected" | awk '{print $1}')"
  fi

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
  echo -e "${CYAN}🔄 Обновляем списки, чтобы получить полный анонс AS${asn_num}...${NC}"
  if systemctl start mobile443-update.service; then
    echo -e "${GREEN}✅ Списки обновлены и применены.${NC}"
  else
    echo -e "${RED}✖ Обновление завершилось с ошибкой, смотрите журнал:${NC}"
    echo "   journalctl -u mobile443-update.service -n 30 --no-pager"
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
    echo "Действия:"
    echo "  1) Добавить сеть в исключение"
    (( ${#entries[@]} > 0 )) && echo "  2) Удалить сеть из исключений"
    echo "  0) Назад"
    echo ""
    read -r -p "Выберите действие: " action < /dev/tty

    case "$action" in
      1)
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
      2)
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

# ---------- 4) Ручной allow-лист (всегда ACCEPT) ----------
action_manage_manual_allow() {
  while true; do
    print_header
    echo -e "${CYAN}✅ Ручной allow-лист (manual_allow.conf)${NC}"
    echo ""
    echo "Сети отсюда ВСЕГДА получают ACCEPT — раньше traf_guard-блоклистов"
    echo "и раньше проверки мобильного ASN. Для одного IP используйте /32."
    echo ""

    [[ -f "$MANUAL_ALLOW_FILE" ]] || touch "$MANUAL_ALLOW_FILE"

    local -a entries=()
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -n "$(strip_comment "$line")" ]] || continue
      entries+=("$line")
    done < "$MANUAL_ALLOW_FILE"

    if (( ${#entries[@]} > 0 )); then
      echo "Текущий allow-лист:"
      local i
      for i in "${!entries[@]}"; do
        echo "  $((i+1))) ${entries[$i]}"
      done
    else
      echo "Ручной allow-лист пуст."
    fi

    echo ""
    echo "Действия:"
    echo "  1) Добавить сеть/IP в allow-лист"
    (( ${#entries[@]} > 0 )) && echo "  2) Удалить сеть из allow-листа"
    echo "  0) Назад"
    echo ""
    read -r -p "Выберите действие: " action < /dev/tty

    case "$action" in
      1)
        echo ""
        read -r -p "Введите CIDR (например 203.0.113.5/32 для одного IP): " new_cidr < /dev/tty
        new_cidr="$(strip_comment "$new_cidr")"
        if ! validate_ipv4_cidr "$new_cidr"; then
          echo -e "${RED}✖ Некорректный CIDR${NC}"
          pause
          continue
        fi
        read -r -p "Комментарий (необязательно): " comment < /dev/tty
        if [[ -n "$comment" ]]; then
          echo "${new_cidr} # ${comment}" >> "$MANUAL_ALLOW_FILE"
        else
          echo "${new_cidr}" >> "$MANUAL_ALLOW_FILE"
        fi
        echo -e "${GREEN}✅ Сеть ${new_cidr} добавлена в allow-лист.${NC}"
        echo ""
        echo -e "${CYAN}🔄 Применяем изменения...${NC}"
        systemctl start mobile443-apply.service || systemctl start mobile443-update.service || true
        pause
        ;;
      2)
        (( ${#entries[@]} == 0 )) && continue
        echo ""
        read -r -p "Номер записи для удаления: " del_choice < /dev/tty
        if ! [[ "$del_choice" =~ ^[0-9]+$ ]] || (( del_choice < 1 || del_choice > ${#entries[@]} )); then
          echo -e "${RED}Некорректный выбор${NC}"
          pause
          continue
        fi
        local target="${entries[$((del_choice-1))]}"
        local tmp
        tmp="$(mktemp)"
        grep -vF "$target" "$MANUAL_ALLOW_FILE" > "$tmp" 2>/dev/null || true
        install -m 0644 "$tmp" "$MANUAL_ALLOW_FILE"
        rm -f "$tmp"
        echo -e "${GREEN}✅ Запись удалена.${NC}"
        echo ""
        echo -e "${CYAN}🔄 Применяем изменения...${NC}"
        systemctl start mobile443-apply.service || systemctl start mobile443-update.service || true
        pause
        ;;
      0|"") return ;;
      *) ;;
    esac
  done
}

# ---------- 5) Статус и диагностика ----------
action_status() {
  print_header
  echo -e "${CYAN}🩺 Статус и диагностика${NC}"
  echo ""

  echo -e "${BOLD}Конфигурация (${CONFIG_FILE}):${NC}"
  echo "  Порты: ${PORTS:-443}"
  echo "  Traffic Guard: ${ENABLE_TRAF_GUARD:-false} (government=${ENABLE_TRAF_GUARD_GOVERNMENT:-false}, antiscanner=${ENABLE_TRAF_GUARD_ANTISCANNER:-false})"
  echo "  Mobile allowlist: ${ENABLE_MOBILE_ALLOW:-false}"
  echo "  Telegram/Remnawave: ${ENABLE_TELEGRAM:-false}"
  if deferred_mode_enabled; then
    echo "  Режим блокировки: deferred (идентификация через xray access.log)"
  else
    echo "  Режим блокировки: immediate (немобильные IP блокируются сразу в nftables)"
  fi
  echo ""

  echo -e "${BOLD}Пулы сетей:${NC}"
  echo "  ASN в пуле (asns.conf): $(grep -cE '^[0-9]+' "$ASNS_FILE" 2>/dev/null || echo 0)"
  echo "  Исключённые ASN (asns_excluded.conf): $(grep -cE '^[0-9]+' "$ASNS_EXCLUDED_FILE" 2>/dev/null || echo 0)"
  echo "  Точечные сети (static_networks.conf): $(grep -cE '^[0-9]+\.' "$STATIC_NETWORKS_FILE" 2>/dev/null || echo 0)"
  echo "  Ручные исключения (excluded_networks.conf): $(grep -cE '^[0-9]+\.' "$EXCLUDED_NETWORKS_FILE" 2>/dev/null || echo 0)"
  echo "  Ручной allow-лист (manual_allow.conf): $(grep -cE '^[0-9]+\.' "$MANUAL_ALLOW_FILE" 2>/dev/null || echo 0)"
  echo ""

  echo -e "${BOLD}Наборы nftables (таблица ip ${NFT_TABLE}):${NC}"
  local set_name cnt
  for set_name in "$SET_MANUAL_ALLOW" "$SET_MOBILE_ALLOW" "$SET_GOV" "$SET_ANTISCANNER" "$SET_DEFERRED"; do
    if nft list set ip "$NFT_TABLE" "$set_name" >/dev/null 2>&1; then
      cnt=$(nft_set_count "$set_name")
      echo "  $set_name: ${cnt} записей"
    else
      echo "  $set_name: не создан"
    fi
  done
  echo ""

  echo -e "${BOLD}Правила (счётчики пакетов):${NC}"
  nft list chain ip "$NFT_TABLE" "$CHAIN_FILTER" 2>/dev/null | sed 's/^/  /' || echo "  цепочка ${CHAIN_FILTER} не найдена"
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

# ---------- 6) Статистика (как отправляет бот) ----------
action_show_stats() {
  print_header
  echo -e "${CYAN}📊 Статистика mobile443${NC}"
  echo ""

  local allow_count gov_count antiscanner_count
  allow_count=$(nft_set_count "$SET_MOBILE_ALLOW")
  gov_count=$(nft_set_count "$SET_GOV")
  antiscanner_count=$(nft_set_count "$SET_ANTISCANNER")

  local total_blocked=0 unique_ips=0 top_ips=""

  if kernel_stats_mode; then
    # Источник — счётчики ядра nftables (монитор не нужен, CPU не тратится)
    total_blocked=$(nft list chain ip "$NFT_TABLE" "$CHAIN_FILTER" 2>/dev/null \
      | grep -oE 'counter packets [0-9]+ bytes [0-9]+ drop' | awk '{s+=$3} END{print s+0}')
    local blk
    blk=$(nft list set ip "$NFT_TABLE" "$SET_BLOCKED" 2>/dev/null \
      | sed -n '/elements = {/,/}/p' | grep -oE '[0-9.]+ counter packets [0-9]+')
    if [[ -n "$blk" ]]; then
      unique_ips=$(echo "$blk" | wc -l | tr -d ' ')
      top_ips=$(echo "$blk" | awk '{print $4, $1}' | sort -rn | head -10 \
        | awk '{printf "%10s  %s\n", $1, $2}')
    fi
    echo "📅 Источник: счётчики ядра nftables (blocked_ips, окно ~10 мин)"
    echo ""
    echo "🚫 Заблокировано пакетов (drop): ${total_blocked}"
    echo "🌐 Активных заблокированных IP (~10 мин): ${unique_ips}"
  else
    if ! systemctl is-active --quiet mobile443-monitor.service 2>/dev/null; then
      echo -e "${YELLOW}⚠️  mobile443-monitor.service сейчас не запущен — цифры ниже могут быть неактуальны.${NC}"
      echo "   Проверить: systemctl status mobile443-monitor.service --no-pager"
      echo ""
    fi
    local stats_file="${STATE_DIR}/stats_blocked.txt"
    if [[ -f "$stats_file" && -s "$stats_file" ]]; then
      total_blocked=$(wc -l < "$stats_file" | tr -d ' ')
      unique_ips=$(awk '{print $3}' "$stats_file" | sort -u | wc -l | tr -d ' ')
      top_ips=$(awk '{print $3}' "$stats_file" | sort | uniq -c | sort -rn | head -10)
    fi
    echo "📅 Период: с последней отправки/сброса статистики"
    echo ""
    echo "🚫 Заблокировано соединений: ${total_blocked}"
    echo "🌐 Уникальных заблокированных IP: ${unique_ips}"
  fi

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
  if [[ "${ENABLE_TELEGRAM:-false}" == "true" ]]; then
    echo "Это тот же отчёт, что бот раз в день шлёт админу в Telegram (mobile443-stats.timer, 09:00 UTC)."
    echo ""
    read -r -p "Отправить этот отчёт в Telegram прямо сейчас? (y/n): " send_now < /dev/tty
    if [[ "${send_now,,}" == "y" ]]; then
      systemctl start mobile443-stats.service && echo -e "${GREEN}✅ Отправлено.${NC}" || echo -e "${RED}✖ Не удалось отправить${NC}"
    fi
  else
    echo "Telegram/Remnawave не настроены — статистика собирается независимо от этого."
    echo "Чтобы получать этот же отчёт в Telegram ежедневно, настройте интеграцию:"
    echo "  sudo mobile443 -> \"Настроить Telegram / Remnawave\""
  fi
  pause
}

# Проверка введённого вручную пути к access.log (сообщения — в stderr,
# т.к. stdout функции detect_xray_log_cli возвращает сам путь).
confirm_xray_log_path_cli() {
  local path="$1" use_anyway

  if [[ -z "$path" ]]; then
    echo "   ⚠️  Путь не задан: пользователи не будут идентифицироваться," >&2
    echo "      немобильные IP будут блокироваться без Telegram-уведомлений." >&2
    return 0
  fi
  if [[ -f "$path" ]]; then
    return 0
  fi

  echo "   ✖ Файл не найден: $path" >&2
  echo "     Пока файла нет, идентификация не работает и немобильные IP" >&2
  echo "     блокируются без Telegram-уведомлений." >&2
  read -r -p "   Использовать этот путь всё равно? (y/n): " use_anyway < /dev/tty
  [[ "${use_anyway,,}" == "y" ]]
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
    local user_path chosen
    while true; do
      read -r -p "   Введите путь или Enter для первого найденного: " user_path < /dev/tty
      chosen="${user_path:-$(echo "$found" | head -1)}"
      confirm_xray_log_path_cli "$chosen" && break
    done
    echo "$chosen"
    return
  fi

  echo "   ⚠️  Автоматически не найден." >&2
  local manual_path
  while true; do
    read -r -p "   Введите полный путь к access.log xray (Enter — пропустить): " manual_path < /dev/tty
    confirm_xray_log_path_cli "$manual_path" && break
  done
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

# ---------- 7) Настроить Telegram / Remnawave ----------
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
  local tg_id_source tg_username_separator tg_custom_message xray_access_log tg_id_choice tg_msg_choice xray_logs_choice

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
  echo "📝 Персональные уведомления пользователям требуют xray access.log."
  echo "   Если логи xray отключены — уведомления пользователям невозможны, и"
  echo "   немобильные IP будут блокироваться сразу на уровне nftables"
  echo "   (админ-алерты и статистика работают в любом случае)."
  echo "   Включено ли у вас логирование xray (access.log)? (y/n)"
  read -r -p "   > " xray_logs_choice < /dev/tty
  if [[ "${xray_logs_choice,,}" == "y" ]]; then
    xray_access_log="$(detect_xray_log_cli)"
    echo "   ✅ Используем: ${xray_access_log:-не указан}"
  else
    xray_access_log=""
    echo "   ✅ Логи отключены: режим immediate — блокировка сразу в nftables."
  fi

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
  systemctl enable mobile443-monitor.service
  # Именно restart, а не enable --now: monitor уже запущен с установки и
  # держит в памяти старый конфиг (ENABLE_TELEGRAM=false, старый
  # XRAY_ACCESS_LOG) — без перезапуска он никогда не начнёт блокировать.
  systemctl restart mobile443-monitor.service
  systemctl enable --now mobile443-stats.timer

  echo -e "${CYAN}🔁 Пересобираем правила с учётом новой конфигурации...${NC}"
  systemctl start mobile443-update.service || systemctl start mobile443-apply.service || true

  echo -e "${GREEN}✅ Telegram/Remnawave интеграция настроена.${NC}"
  pause
}

# ---------- 8) Полное удаление ----------
action_remove() {
  print_header
  echo -e "${RED}${BOLD}🗑️  Полное удаление mobile443${NC}"
  echo ""
  echo "Будут удалены: таблица nftables, systemd-юниты,"
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
              mobile443-update.timer mobile443-update.service mobile443-apply.service \
              mobile443-nettune.service; do
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
  done

  echo "[*] Удаление правил nftables"
  nft delete table ip "$NFT_TABLE" 2>/dev/null || true

  # Зачистка legacy-правил iptables/ipset от установок до v0.7
  if command -v iptables >/dev/null 2>&1; then
    local chain proto port
    for chain in INPUT FORWARD DOCKER-USER; do
      for proto in tcp udp; do
        for port in "${remove_ports[@]}"; do
          while iptables -C "$chain" -p "$proto" --dport "$port" -j FILTER_MOBILE_443 2>/dev/null; do
            iptables -D "$chain" -p "$proto" --dport "$port" -j FILTER_MOBILE_443 || true
          done
          while iptables -C "$chain" -p "$proto" -m conntrack --ctdir ORIGINAL --ctorigdstport "$port" -j FILTER_MOBILE_443 2>/dev/null; do
            iptables -D "$chain" -p "$proto" -m conntrack --ctdir ORIGINAL --ctorigdstport "$port" -j FILTER_MOBILE_443 || true
          done
        done
      done
    done
    iptables -F FILTER_MOBILE_443 2>/dev/null || true
    iptables -X FILTER_MOBILE_443 2>/dev/null || true
    iptables -F TRAF_GUARD_PRECHECK 2>/dev/null || true
    iptables -X TRAF_GUARD_PRECHECK 2>/dev/null || true
  fi

  if command -v ipset >/dev/null 2>&1; then
    local legacy_set
    for legacy_set in allowed_mobile_443_tmp allowed_mobile_443 \
                      traf_guard_government_tmp traf_guard_government \
                      traf_guard_antiscanner_tmp traf_guard_antiscanner \
                      mobile443_deferred_block \
                      manual_allow_443_tmp manual_allow_443; do
      ipset destroy "$legacy_set" 2>/dev/null || true
    done
  fi

  echo "[*] Удаление systemd юнитов"
  rm -f /etc/systemd/system/mobile443-apply.service
  rm -f /etc/systemd/system/mobile443-update.service
  rm -f /etc/systemd/system/mobile443-update.timer
  rm -f /etc/systemd/system/mobile443-monitor.service
  rm -f /etc/systemd/system/mobile443-nettune.service
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
  rm -f /usr/local/sbin/mobile443-nettune.sh
  rm -f /etc/sysctl.d/99-mobile443-net.conf
  rm -rf "$BASE_DIR"
  rm -rf "$STATE_DIR"

  echo ""
  echo -e "${GREEN}[+] mobile443 удалён.${NC}"
  trap 'rm -f /usr/local/sbin/mobile443' EXIT
  exit 0
}

# ---------- Изменить порты фильтрации ----------
action_change_ports() {
  print_header
  echo -e "${CYAN}🔌 Изменение портов фильтрации${NC}"
  echo ""
  echo "   Текущие порты: ${PORTS:-443}"
  echo "   Введите новые порты через пробел (например: 443 8443):"
  read -r -p "   > " new_ports < /dev/tty

  new_ports="$(echo "$new_ports" | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')"
  if [[ -z "$new_ports" ]]; then
    echo -e "${YELLOW}Отменено: порты не введены.${NC}"; pause; return
  fi

  local p
  for p in $new_ports; do
    if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
      echo -e "${RED}✖ Некорректный порт: '${p}'. Изменения не применены.${NC}"; pause; return
    fi
  done

  # Защита от самоблокировки: предупреждаем, если фильтруем SSH-порт.
  # || true — sshd может быть не в PATH или вернуть ненулевой код; это не
  # должно ронять действие под set -e/pipefail.
  local ssh_ports confirm
  ssh_ports="$( { sshd -T 2>/dev/null || /usr/sbin/sshd -T 2>/dev/null; } | awk '/^port /{print $2}' || true)"
  for p in $new_ports; do
    if [[ -n "$ssh_ports" ]] && echo "$ssh_ports" | grep -qx "$p"; then
      echo ""
      echo -e "${RED}⚠️  Порт ${p} — это порт SSH.${NC} В immediate-режиме немобильные IP на нём"
      echo "    будут дропаться — можно потерять доступ. Убедись, что твой IP в ручном"
      echo "    allow-листе (пункт 4)."
      read -r -p "    Всё равно фильтровать ${p}? (yes/n): " confirm < /dev/tty
      [[ "$confirm" == "yes" ]] || { echo "Отменено."; pause; return; }
    fi
  done

  local old_ports="${PORTS:-443}"

  # iptables-бэкенд: снять джампы старых портов, иначе они останутся висеть
  # (nft-бэкенд пересобирает цепочки целиком, там старые порты уходят сами)
  if [[ "${FIREWALL_BACKEND:-nftables}" == "iptables" ]]; then
    local chain oport
    for oport in $old_ports; do
      for chain in INPUT FORWARD DOCKER-USER; do
        ipt_delete_jump "$chain" tcp "$oport" 2>/dev/null || true
        ipt_delete_jump "$chain" udp "$oport" 2>/dev/null || true
      done
    done
  fi

  set_config_key "PORTS" "$new_ports"
  reload_config
  read -r -a PORT_LIST <<< "${PORTS:-443}"

  if apply_rules; then
    echo ""
    echo -e "${GREEN}✅ Порты фильтрации обновлены: ${old_ports} -> ${new_ports}${NC}"
    echo "   Применено к файрволу и сохранено в конфиг (переживёт перезагрузку и обновления списков)."
  else
    echo -e "${RED}✖ Не удалось применить правила. Проверь: sudo mobile443 -> Статус.${NC}"
  fi
  pause
}

main_menu() {
  while true; do
    print_header
    echo "Движок: ${FIREWALL_BACKEND:-nftables} | Порты: ${PORTS:-443} | Traffic Guard: ${ENABLE_TRAF_GUARD:-false} | Mobile allow: ${ENABLE_MOBILE_ALLOW:-false} | Telegram: ${ENABLE_TELEGRAM:-false}"
    echo ""
    echo "  1) 🔄 Обновить списки сейчас"
    echo "  2) ↩️  Вернуть ASN в полный пул и обновить списки"
    echo "  3) 🚫 Управление исключениями сетей"
    echo "  4) ✅ Ручной allow-лист (мой IP всегда проходит)"
    echo "  5) 🩺 Статус и диагностика"
    echo "  6) 📊 Статистика (как отправляет бот)"
    echo "  7) 🤖 Настроить Telegram / Remnawave"
    echo "  8) 🔌 Изменить порты фильтрации"
    echo "  9) 🗑️  Удалить mobile443"
    echo "  0) Выход"
    echo ""
    read -r -p "Выберите пункт меню: " choice < /dev/tty
    case "$choice" in
      1) action_update_lists ;;
      2) action_restore_asn ;;
      3) action_manage_exclusions ;;
      4) action_manage_manual_allow ;;
      5) action_status ;;
      6) action_show_stats ;;
      7) action_configure_telegram ;;
      8) action_change_ports ;;
      9) action_remove ;;
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
Description=Apply mobile443 nftables ruleset from local cache
# nftables.service — только упорядочивание: дистрибутивный юнит часто
# делает `flush ruleset` при старте и снёс бы нашу таблицу, если бы
# запускался после нас. Если юнит не установлен, зависимость игнорируется.
After=network-online.target nftables.service
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
After=network-online.target nftables.service
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

  # Monitor всегда ставится и запускается — он считает заблокированные
  # соединения и топ IP в stats_blocked.txt (видно в консоли mobile443
  # -> "Статистика") независимо от того, настроен ли Telegram. Сами
  # Telegram-уведомления и админский alert внутри monitor.sh включаются
  # только при ENABLE_TELEGRAM=true.
  cat > /etc/systemd/system/mobile443-monitor.service <<'EOF'
[Unit]
Description=Monitor blocked connections, collect stats and send Telegram notifications
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

  cat > /etc/systemd/system/mobile443-nettune.service <<'EOF'
[Unit]
Description=Distribute network RX softirq across CPU cores (RPS/RFS)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mobile443-nettune.sh
User=root
Group=root
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  if [[ "${ENABLE_TELEGRAM:-false}" == "true" ]]; then
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

remove_telegram_stats_assets() {
  systemctl stop mobile443-stats.timer 2>/dev/null || true
  systemctl stop mobile443-stats.service 2>/dev/null || true
  systemctl disable mobile443-stats.timer 2>/dev/null || true
  rm -f /etc/systemd/system/mobile443-stats.service
  rm -f /etc/systemd/system/mobile443-stats.timer
  rm -f "${BIN_DIR}/mobile443-stats.sh"
}

enable_services() {
  systemctl daemon-reload
  systemctl enable mobile443-apply.service
  systemctl enable --now mobile443-update.timer
  if [[ "${FIREWALL_BACKEND:-nftables}" != "iptables" && "${ENABLE_TELEGRAM:-false}" != "true" ]]; then
    # nft + immediate без Telegram: статистика из in-kernel счётчиков,
    # journal-тейлящий монитор не нужен — не грузим CPU
    systemctl disable --now mobile443-monitor.service 2>/dev/null || true
  else
    systemctl enable --now mobile443-monitor.service
  fi
  systemctl enable --now mobile443-nettune.service 2>/dev/null || true
  sysctl -p /etc/sysctl.d/99-mobile443-net.conf >/dev/null 2>&1 || true

  if [[ "${ENABLE_TELEGRAM:-false}" == "true" ]]; then
    systemctl enable --now mobile443-stats.timer
  else
    remove_telegram_stats_assets
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
  echo "    nft list table ip mobile443 | head -40"
  echo "    nft list chain ip mobile443 filter443"
  echo "    nft list set ip mobile443 mobile_allow | head -20"
  echo "    nft list set ip mobile443 tg_government | head -20"
  echo "    nft list set ip mobile443 deferred_block"

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
  systemctl stop mobile443-nettune.service 2>/dev/null || true

  systemctl disable mobile443-monitor.service 2>/dev/null || true
  systemctl disable mobile443-stats.timer 2>/dev/null || true
  systemctl disable mobile443-update.timer 2>/dev/null || true
  systemctl disable mobile443-apply.service 2>/dev/null || true
  systemctl disable mobile443-nettune.service 2>/dev/null || true

  echo "[*] Удаление правил nftables"
  if command -v nft >/dev/null 2>&1; then
    nft delete table ip mobile443 2>/dev/null || true
  fi

  # Зачистка legacy-правил iptables/ipset от установок до v0.7
  if command -v iptables >/dev/null 2>&1; then
    for chain in INPUT FORWARD DOCKER-USER; do
      for proto in tcp udp; do
        for port in "${remove_ports[@]}"; do
          while iptables -C "$chain" -p "$proto" --dport "$port" -j FILTER_MOBILE_443 2>/dev/null; do
            iptables -D "$chain" -p "$proto" --dport "$port" -j FILTER_MOBILE_443 || true
          done
          while iptables -C "$chain" -p "$proto" -m conntrack --ctdir ORIGINAL --ctorigdstport "$port" -j FILTER_MOBILE_443 2>/dev/null; do
            iptables -D "$chain" -p "$proto" -m conntrack --ctdir ORIGINAL --ctorigdstport "$port" -j FILTER_MOBILE_443 || true
          done
        done
      done
    done

    iptables -F FILTER_MOBILE_443 2>/dev/null || true
    iptables -X FILTER_MOBILE_443 2>/dev/null || true
    iptables -F TRAF_GUARD_PRECHECK 2>/dev/null || true
    iptables -X TRAF_GUARD_PRECHECK 2>/dev/null || true
  fi

  if command -v ipset >/dev/null 2>&1; then
    for legacy_set in allowed_mobile_443_tmp allowed_mobile_443 \
                      traf_guard_government_tmp traf_guard_government \
                      traf_guard_antiscanner_tmp traf_guard_antiscanner \
                      mobile443_deferred_block \
                      manual_allow_443_tmp manual_allow_443; do
      ipset destroy "$legacy_set" 2>/dev/null || true
    done
  fi

  echo "[*] Удаление systemd юнитов"
  rm -f /etc/systemd/system/mobile443-apply.service
  rm -f /etc/systemd/system/mobile443-update.service
  rm -f /etc/systemd/system/mobile443-update.timer
  rm -f /etc/systemd/system/mobile443-monitor.service
  rm -f /etc/systemd/system/mobile443-nettune.service
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
  rm -f "${BIN_DIR}/mobile443-nettune.sh"
  rm -f /etc/sysctl.d/99-mobile443-net.conf
  rm -f "${BIN_DIR}/mobile443"
  rm -rf "$BASE_DIR"
  rm -rf "$STATE_DIR"

  echo ""
  echo "[+] Удалено."
}

update_all() {
  require_root

  local backup_dir backup_config backup_asns target_profile existing_profile requested_profile
  local backup_asns_excluded backup_static_networks backup_excluded_networks backup_manual_allow
  requested_profile="$INSTALL_PROFILE"
  backup_dir="$(mktemp -d)"
  backup_config="${backup_dir}/config.conf"
  backup_asns="${backup_dir}/asns.conf"
  backup_asns_excluded="${backup_dir}/asns_excluded.conf"
  backup_static_networks="${backup_dir}/static_networks.conf"
  backup_excluded_networks="${backup_dir}/excluded_networks.conf"
  backup_manual_allow="${backup_dir}/manual_allow.conf"

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
  if [[ -f "$MANUAL_ALLOW_FILE" ]]; then
    install -m 0644 "$MANUAL_ALLOW_FILE" "$backup_manual_allow"
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
    "$backup_asns_excluded" "$backup_static_networks" "$backup_excluded_networks" \
    "$backup_manual_allow"
  runtime_install_from_config

  rm -rf "$backup_dir"
}

load_env_options
parse_args "$@"
normalize_options

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
    usage >&2
    exit 1
    ;;
esac
