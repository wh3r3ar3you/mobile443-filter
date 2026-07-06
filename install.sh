#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  mobile443 installer
#  Использование:
#    bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh)
#    bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) update
#    bash <(curl -Ls https://raw.githubusercontent.com/wh3r3ar3you/mobile443-filter/refs/heads/main/install.sh) remove
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
echo "║     mobile443 - mobile ASN filter + DROP     ║"
echo "╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo -e "${RED}✖ Запустите от root: sudo bash <(curl -Ls ...)${NC}"
  exit 1
fi

fetch_file() {
  local url="$1"
  local dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$dest"
    return
  fi

  echo -e "${CYAN}📦 Не найден ни curl, ни wget — устанавливаем curl...${NC}"
  apt update -y >/dev/null 2>&1 || true
  apt install -y curl >/dev/null 2>&1
  curl -fsSL "$url" -o "$dest"
}

echo -e "${CYAN}📥 Скачиваем ${SCRIPT_NAME}...${NC}"
mkdir -p "$INSTALL_DIR"

if ! fetch_file "${REPO_RAW}/${SCRIPT_NAME}" "${INSTALL_DIR}/${SCRIPT_NAME}"; then
  echo -e "${RED}✖ Не удалось скачать скрипт.${NC}"
  echo -e "${RED}  Проверьте URL: ${REPO_RAW}/${SCRIPT_NAME}${NC}"
  exit 1
fi

chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
echo -e "${GREEN}✅ Скрипт загружен${NC}"
echo ""

cd "$INSTALL_DIR"
bash "${INSTALL_DIR}/${SCRIPT_NAME}" "$ACTION" full

rm -rf "$INSTALL_DIR"
