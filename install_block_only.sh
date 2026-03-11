#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  mobile443 block-only installer
#  Использование:
#    bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh)
#    PORTS="443 8443" bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh)
#    bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install_block_only.sh) remove
# ═══════════════════════════════════════════════════════════
set -Eeuo pipefail

REPO_RAW="https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main"
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
echo "║  mobile443 block-only - traffic guard DROP   ║"
echo "╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo -e "${RED}✖ Запустите от root: sudo bash <(curl -Ls ...)${NC}"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo -e "${CYAN}📦 Устанавливаем curl...${NC}"
  apt update -y >/dev/null 2>&1 || true
  apt install -y curl >/dev/null 2>&1
fi

echo -e "${CYAN}📥 Скачиваем ${SCRIPT_NAME}...${NC}"
mkdir -p "$INSTALL_DIR"

if ! curl -fsSL "${REPO_RAW}/${SCRIPT_NAME}" -o "${INSTALL_DIR}/${SCRIPT_NAME}"; then
  echo -e "${RED}✖ Не удалось скачать скрипт.${NC}"
  echo -e "${RED}  Проверьте URL: ${REPO_RAW}/${SCRIPT_NAME}${NC}"
  exit 1
fi

chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
echo -e "${GREEN}✅ Скрипт загружен${NC}"
echo -e "${CYAN}ℹ️  Порты по умолчанию: ${PORTS:-443}${NC}"
echo ""

cd "$INSTALL_DIR"
bash "${INSTALL_DIR}/${SCRIPT_NAME}" "$ACTION" block-only

rm -rf "$INSTALL_DIR"
