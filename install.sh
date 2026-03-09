#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  mobile443 installer
#  Использование:
#    bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh)
#    bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) remove
# ═══════════════════════════════════════════════════════════
set -Eeuo pipefail

# ─── Конфигурация ───
REPO_RAW="https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/asn.sh"
SCRIPT_NAME="asn.sh"
INSTALL_DIR="/tmp/mobile443-installer"
ACTION="${1:-install}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}"
echo "╔═══════════════════════════════════════════════╗"
echo "║     🛡️  mobile443 — ASN-фильтр для VPN       ║"
echo "╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Проверка root ───
if [[ "$(id -u)" -ne 0 ]]; then
  echo -e "${RED}✖ Запустите от root: sudo bash <(curl -Ls ...)${NC}"
  exit 1
fi

# ─── Проверка зависимостей ───
if ! command -v curl &>/dev/null; then
  echo -e "${CYAN}📦 Устанавливаем curl...${NC}"
  apt update -y >/dev/null 2>&1 || true
  apt install -y curl >/dev/null 2>&1
fi

# ─── Скачивание скрипта ───
echo -e "${CYAN}📥 Скачиваем ${SCRIPT_NAME}...${NC}"
mkdir -p "$INSTALL_DIR"

if ! curl -fsSL "${REPO_RAW}/${SCRIPT_NAME}" -o "${INSTALL_DIR}/${SCRIPT_NAME}"; then
  echo -e "${RED}✖ Не удалось скачать скрипт.${NC}"
  echo -e "${RED}  Проверьте URL: ${REPO_RAW}/${SCRIPT_NAME}${NC}"
  exit 1
fi

chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
echo -e "${GREEN}✅ Скрипт загружен${NC}"
echo ""

# ─── Запуск ───
cd "$INSTALL_DIR"
bash "${INSTALL_DIR}/${SCRIPT_NAME}" "$ACTION"

# ─── Очистка ───
rm -rf "$INSTALL_DIR"
