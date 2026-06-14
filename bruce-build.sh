#!/usr/bin/env bash
# ============================================================
#  Bruce Firmware Builder
#  Requer: git, python3, pip3, platformio
# ============================================================

set -euo pipefail

# ---- cores ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

REPO_URL="https://github.com/BruceDevices/firmware.git"
BUILD_DIR="$(pwd)/Bruce-src"
OUTPUT_DIR="$(pwd)/Bruce-bins"

# ---- devices disponíveis (env PlatformIO : label exibido) ----
declare -A DEVICES=(
  [1]="m5stack-cardputer|M5Stack Cardputer"
  [2]="m5stack-cplus2|M5Stack StickC Plus2"
  [3]="m5stack-cplus1_1|M5Stack StickC Plus 1.1"
  [4]="m5stack-cores3|M5Stack CoreS3"
  [5]="m5stack-core2|M5Stack Core2"
  [6]="lilygo-t-deck|LilyGo T-Deck"
  [7]="lilygo-t-embed-cc1101|LilyGo T-Embed CC1101"
  [8]="lilygo-t-embed-s3|LilyGo T-Embed S3"
  [9]="Bruce-CYD-2USB|CYD Cheap Yellow Display (2 USB)"
  [10]="Bruce-esp32-s3-devkitc-1|ESP32-S3 DevKitC-1"
  [11]="ALL|*** Compilar TODOS ***"
)
TOTAL=${#DEVICES[@]}

# ============================================================
header() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "  ██████╗ ██████╗ ██╗   ██╗ ██████╗███████╗"
  echo "  ██╔══██╗██╔══██╗██║   ██║██╔════╝██╔════╝"
  echo "  ██████╔╝██████╔╝██║   ██║██║     █████╗  "
  echo "  ██╔══██╗██╔══██╗██║   ██║██║     ██╔══╝  "
  echo "  ██████╔╝██║  ██║╚██████╔╝╚██████╗███████╗"
  echo "  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝╚══════╝"
  echo -e "  Firmware Builder v1.0${RESET}"
  echo ""
}

check_deps() {
  local missing=()
  for cmd in git python3 pip3; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if ! command -v pio &>/dev/null; then
    missing+=("platformio  →  pip3 install platformio")
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}[ERRO] Dependências faltando:${RESET}"
    for m in "${missing[@]}"; do echo "  • $m"; done
    echo ""
    read -rp "Instalar platformio agora? [s/N] " ans
    if [[ "$ans" =~ ^[sS]$ ]]; then
      pip3 install platformio
      export PATH="$PATH:$HOME/.local/bin"
    else
      exit 1
    fi
  fi
  export PATH="$PATH:$HOME/.local/bin"
}

clone_or_update() {
  echo -e "${YELLOW}[•] Repositório: ${BUILD_DIR}${RESET}"
  if [ -d "$BUILD_DIR/.git" ]; then
    echo -e "${CYAN}[↑] Atualizando fonte...${RESET}"
    git -C "$BUILD_DIR" pull --ff-only
  else
    echo -e "${CYAN}[↓] Clonando Bruce...${RESET}"
    git clone "$REPO_URL" "$BUILD_DIR"
  fi
  echo ""
}

show_menu() {
  header
  echo -e "${BOLD}  Selecione o device para compilar:${RESET}"
  echo ""
  for i in $(seq 1 $TOTAL); do
    IFS='|' read -r env label <<< "${DEVICES[$i]}"
    if [ "$env" = "ALL" ]; then
      echo -e "  ${YELLOW}[$i]${RESET} ${BOLD}$label${RESET}"
    else
      printf "  ${CYAN}[%2d]${RESET} %-42s ${RED}(%s)${RESET}\n" "$i" "$label" "$env"
    fi
  done
  echo ""
  echo -e "  ${RED}[0]${RESET} Sair"
  echo ""
}

build_device() {
  local env="$1"
  local label="$2"
  local log_file="$OUTPUT_DIR/build_${env}.log"

  mkdir -p "$OUTPUT_DIR"

  echo ""
  echo -e "${YELLOW}╔══════════════════════════════════════════╗${RESET}"
  echo -e "${YELLOW}║  Compilando: ${BOLD}${label}${RESET}${YELLOW}"
  echo -e "${YELLOW}║  env: ${env}${RESET}"
  echo -e "${YELLOW}╚══════════════════════════════════════════╝${RESET}"
  echo ""

  pushd "$BUILD_DIR" > /dev/null

  # compilar
  echo -e "${CYAN}[1/2] Build...${RESET}"
  if pio run -e "$env" 2>&1 | tee "$log_file"; then
    echo -e "${GREEN}[✔] Build OK${RESET}"
  else
    echo -e "${RED}[✘] Build falhou! Veja: $log_file${RESET}"
    popd > /dev/null
    return 1
  fi

  # gerar .bin combinado (bootloader + partições + firmware)
  echo ""
  echo -e "${CYAN}[2/2] Gerando .bin combinado...${RESET}"
  if pio run -e "$env" -t build-firmware 2>&1 | tee -a "$log_file"; then
    echo -e "${GREEN}[✔] .bin gerado!${RESET}"
  else
    echo -e "${YELLOW}[!] build-firmware falhou, tentando merge manual...${RESET}"
    merge_manual "$env"
  fi

  # copiar .bin para pasta de saída
  copy_output "$env" "$label"

  popd > /dev/null
}

merge_manual() {
  local env="$1"
  # tenta achar os 3 arquivos e fazer merge com esptool
  local fw_dir=".pio/build/${env}"
  local boot="${fw_dir}/bootloader.bin"
  local part="${fw_dir}/partitions.bin"
  local app="${fw_dir}/firmware.bin"

  if [ -f "$boot" ] && [ -f "$part" ] && [ -f "$app" ]; then
    python3 -m esptool --chip esp32 merge_bin \
      -o "Bruce-${env}.bin" \
      --flash_mode dio --flash_freq 40m --flash_size 4MB \
      0x1000  "$boot" \
      0x8000  "$part" \
      0x10000 "$app" && \
    echo -e "${GREEN}[✔] Merge manual OK${RESET}" || \
    echo -e "${RED}[✘] Merge manual falhou${RESET}"
  else
    echo -e "${RED}[✘] Binários intermediários não encontrados em ${fw_dir}${RESET}"
  fi
}

copy_output() {
  local env="$1"
  local label="$2"
  local found=0

  # procura o .bin na raiz ou em .pio/build
  for f in \
    "${BUILD_DIR}/Bruce-${env}.bin" \
    "${BUILD_DIR}/.pio/build/${env}/firmware.bin"; do
    if [ -f "$f" ]; then
      local dest="${OUTPUT_DIR}/Bruce-${env}.bin"
      cp "$f" "$dest"
      echo ""
      echo -e "${GREEN}╔══════════════════════════════════════════╗${RESET}"
      echo -e "${GREEN}║  ${BOLD}.bin salvo em:${RESET}${GREEN}"
      echo -e "${GREEN}║  ${RESET}${BOLD}${dest}${RESET}"
      echo -e "${GREEN}╚══════════════════════════════════════════╝${RESET}"
      echo ""
      found=1
      break
    fi
  done

  if [ $found -eq 0 ]; then
    echo -e "${RED}[!] .bin não encontrado, verifique o log:${RESET}"
    echo -e "    ${OUTPUT_DIR}/build_${env}.log"
  fi
}

build_all() {
  echo -e "${YELLOW}[★] Compilando TODOS os devices...${RESET}"
  local ok=0; local fail=0
  for i in $(seq 1 $((TOTAL-1))); do
    IFS='|' read -r env label <<< "${DEVICES[$i]}"
    build_device "$env" "$label" && ((ok++)) || ((fail++))
    echo ""
  done
  echo -e "${BOLD}Resultado: ${GREEN}${ok} OK${RESET} / ${RED}${fail} falhou${RESET}"
}

flash_prompt() {
  local bin_file="$1"
  echo ""
  read -rp "Flashar agora? [s/N] " ans
  if [[ "$ans" =~ ^[sS]$ ]]; then
    echo ""
    echo "Portas disponíveis:"
    ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "  (nenhuma encontrada)"
    echo ""
    read -rp "Porta (ex: /dev/ttyUSB0): " port
    if [ -n "$port" ]; then
      esptool.py --port "$port" write_flash 0x00000 "$bin_file"
    fi
  fi
}

# ============================================================
#  MAIN
# ============================================================
header
check_deps
clone_or_update

while true; do
  show_menu
  read -rp "  Escolha [0-${TOTAL}]: " choice

  if [ "$choice" = "0" ]; then
    echo -e "${CYAN}Saindo...${RESET}"
    exit 0
  fi

  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$TOTAL" ]; then
    echo -e "${RED}Opção inválida.${RESET}"
    sleep 1
    continue
  fi

  IFS='|' read -r env label <<< "${DEVICES[$choice]}"

  if [ "$env" = "ALL" ]; then
    build_all
  else
    build_device "$env" "$label"
    # oferecer flash se existir o bin
    bin="${OUTPUT_DIR}/Bruce-${env}.bin"
    [ -f "$bin" ] && flash_prompt "$bin"
  fi

  echo ""
  read -rp "  Pressione ENTER para voltar ao menu..."
done
