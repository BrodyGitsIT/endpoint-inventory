#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
#  inventory-host  —  Server-side setup wizard
#  Hosts: inventory.sh  server.env.enc  server.env.key
# ════════════════════════════════════════════════════════════════
set -euo pipefail

VERSION="1.0.0"
PORT=3333
INSTALL_DIR="/opt/scripts/inventory"
SERVICE_NAME="inventory-host"
ENV_FILE="./server.env"
ENV_ENC="./server.env.enc"
KEY_FILE="./server.env.key"

# ── Colour helpers ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
  CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
else
  RED=''; GRN=''; YLW=''; CYN=''; BLD=''; RST=''
fi

info()  { echo -e "${CYN}[host]${RST} $*"; }
ok()    { echo -e "${GRN}[host]${RST} $*"; }
warn()  { echo -e "${YLW}[host]${RST} $*"; }
die()   { echo -e "${RED}[host] ERROR:${RST} $*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "Required tool not found: $1"; }

# ── Dependency check ──────────────────────────────────────────────────────────
require openssl
require python3
require systemctl
require ip

echo ""
echo -e "${BLD}══════════════════════════════════════════${RST}"
echo -e "${BLD}   Inventory Tool  —  Host Setup Wizard   ${RST}"
echo -e "${BLD}══════════════════════════════════════════${RST}"
echo ""

# ── Schedule prompt ───────────────────────────────────────────────────────────
prompt_schedule() {
  echo -e "${BLD}── Agent Run Schedule ──────────────────────${RST}"
  echo "  1) Weekly   (pick a weekday + time)"
  echo "  2) Monthly  (first Monday of month)"
  echo "  3) Daily    (pick a time)"
  echo ""
  read -rp "Choose schedule [1-3]: " SCHED_CHOICE

  case "$SCHED_CHOICE" in
    1)
      echo ""
      echo "  Weekday: 1=Mon 2=Tue 3=Wed 4=Thu 5=Fri 6=Sat 7=Sun"
      read -rp "  Weekday number [1]: " WDAY_IN
      WDAY_IN="${WDAY_IN:-1}"
      read -rp "  Hour (0-23) [8]: " HR_IN
      HR_IN="${HR_IN:-8}"
      read -rp "  Minute (0-59) [0]: " MIN_IN
      MIN_IN="${MIN_IN:-0}"

      # Map 1-7 to systemd day names
      declare -A DAY_MAP=([1]=Mon [2]=Tue [3]=Wed [4]=Thu [5]=Fri [6]=Sat [7]=Sun)
      DAY_NAME="${DAY_MAP[$WDAY_IN]:-Mon}"

      SYSTEMD_ONCALENDAR="${DAY_NAME} *-*-* $(printf '%02d' "$HR_IN"):$(printf '%02d' "$MIN_IN"):00"
      SCHEDULE_HUMAN="Every ${DAY_NAME} at $(printf '%02d' "$HR_IN"):$(printf '%02d' "$MIN_IN")"
      ;;
    2)
      read -rp "  Hour (0-23) [8]: " HR_IN
      HR_IN="${HR_IN:-8}"
      read -rp "  Minute (0-59) [0]: " MIN_IN
      MIN_IN="${MIN_IN:-0}"

      SYSTEMD_ONCALENDAR="Mon *-*-1..7 $(printf '%02d' "$HR_IN"):$(printf '%02d' "$MIN_IN"):00"
      SCHEDULE_HUMAN="Monthly (first Monday) at $(printf '%02d' "$HR_IN"):$(printf '%02d' "$MIN_IN")"
      ;;
    3)
      read -rp "  Hour (0-23) [8]: " HR_IN
      HR_IN="${HR_IN:-8}"
      read -rp "  Minute (0-59) [0]: " MIN_IN
      MIN_IN="${MIN_IN:-0}"

      SYSTEMD_ONCALENDAR="*-*-* $(printf '%02d' "$HR_IN"):$(printf '%02d' "$MIN_IN"):00"
      SCHEDULE_HUMAN="Daily at $(printf '%02d' "$HR_IN"):$(printf '%02d' "$MIN_IN")"
      ;;
    *)
      warn "Invalid choice — defaulting to Weekly Monday 08:00"
      SYSTEMD_ONCALENDAR="Mon *-*-* 08:00:00"
      SCHEDULE_HUMAN="Every Mon at 08:00 (default)"
      ;;
  esac

  echo ""
  ok "Schedule: ${SCHEDULE_HUMAN}"
  ok "OnCalendar: ${SYSTEMD_ONCALENDAR}"
  echo ""
}

# ── Collect or reuse config ───────────────────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
  echo -e "${YLW}[host] Existing server.env found.${RST}"
  read -rp "       Re-use it? [Y/n]: " REUSE
  REUSE="${REUSE:-Y}"
  if [[ "${REUSE,,}" != "y" ]]; then
    rm -f "$ENV_FILE" "$ENV_ENC" "$KEY_FILE"
  fi
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo -e "${BLD}── Nextcloud Connection ────────────────────${RST}"
  read -rp "  Nextcloud URL (https://cloud.example.com): " NC_URL
  read -rp "  Nextcloud bot username: "                    NC_USER
  read -rsp "  Nextcloud app password: "                   NC_PASS
  echo ""
  read -rp "  Nextcloud folder path (/Systems): "          NC_FOLDER
  NC_FOLDER="${NC_FOLDER:-/Systems}"

  # Optional: local fallback URL (LAN access when public DNS fails)
  read -rp "  Local/LAN Nextcloud URL (leave blank to skip): " NC_URL_LOCAL
  echo ""

  prompt_schedule

  info "Saving plaintext config..."
  umask 077
  cat > "$ENV_FILE" <<EOF
NC_URL=${NC_URL}
NC_URL_LOCAL=${NC_URL_LOCAL:-}
NC_USER=${NC_USER}
NC_PASS=${NC_PASS}
NC_FOLDER=${NC_FOLDER}
ONCALENDAR=${SYSTEMD_ONCALENDAR}
EOF

else
  # Reusing existing — still need schedule vars for this run
  source "$ENV_FILE"
  SYSTEMD_ONCALENDAR="${ONCALENDAR:-Mon *-*-* 08:00:00}"
  SCHEDULE_HUMAN="(loaded from existing server.env)"
fi

# ── Encrypt server.env → server.env.enc ───────────────────────────────────────
info "Encrypting server.env..."

# Generate a random 256-bit key (hex)
KEY="$(openssl rand -hex 32)"
printf '%s' "$KEY" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

# Encrypt: AES-256-CBC, PBKDF2, base64 output (-a = base64, text-safe for HTTP)
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -a \
  -pass "pass:${KEY}" \
  -in  "$ENV_FILE" \
  -out "$ENV_ENC"

ok "Encrypted  → ${ENV_ENC}"
ok "Key stored → ${KEY_FILE}  (keep this safe — agents need it at install time)"
echo ""
warn "The plaintext server.env is still on disk for reference."
warn "Delete it after deployment if you want:  rm ./server.env"
echo ""

# ── Install files to serve dir ────────────────────────────────────────────────
info "Installing files to ${INSTALL_DIR}..."
sudo mkdir -p "$INSTALL_DIR"

# Copy inventory agent
SCRIPT_SRC="./inventory.sh"
[[ -f "$SCRIPT_SRC" ]] || die "inventory.sh not found in current directory."
sudo cp "$SCRIPT_SRC"  "$INSTALL_DIR/inventory.sh"
sudo chmod +x          "$INSTALL_DIR/inventory.sh"

# Copy encrypted env + key (key is served so agents can decrypt in-memory)
sudo cp "$ENV_ENC"  "$INSTALL_DIR/server.env.enc"
sudo cp "$KEY_FILE" "$INSTALL_DIR/server.env.key"

# Lock everything down
sudo chmod 644 "$INSTALL_DIR/server.env.enc"   # readable by http server
sudo chmod 644 "$INSTALL_DIR/server.env.key"   # readable by http server
sudo chmod 644 "$INSTALL_DIR/inventory.sh"
sudo chown -R root:root "$INSTALL_DIR"

ok "Files installed:"
sudo ls -lah "$INSTALL_DIR"
echo ""

# ── systemd HTTP server ───────────────────────────────────────────────────────
info "Installing systemd service (HTTP on port ${PORT})..."

sudo tee /etc/systemd/system/${SERVICE_NAME}.service >/dev/null <<EOF
[Unit]
Description=Inventory Host HTTP Server (port ${PORT})
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server ${PORT} --directory ${INSTALL_DIR}
WorkingDirectory=${INSTALL_DIR}
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable  "${SERVICE_NAME}"
sudo systemctl restart "${SERVICE_NAME}"

sleep 1
if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
  ok "HTTP server is running on port ${PORT}"
else
  die "Service failed to start. Run: journalctl -u ${SERVICE_NAME} -n 30"
fi

# ── Print client install command ──────────────────────────────────────────────
HOST_IP="${HOST_IP:-$(ip route get 1.1.1.1 2>/dev/null | awk 'NR==1{print $7}')}"

KEY_VAL="$(cat "$KEY_FILE")"

echo ""
echo -e "${BLD}══════════════════════════════════════════${RST}"
echo -e "${BLD}         CLIENT INSTALL COMMAND           ${RST}"
echo -e "${BLD}══════════════════════════════════════════${RST}"
echo ""
echo -e "${YLW}Run this one-liner on every endpoint (as root or with sudo):${RST}"
echo ""
echo -e "${CYN}bash <(curl -fsSL http://${HOST_IP}:${PORT}/inventory.sh) ${HOST_IP} ${KEY_VAL}${RST}"
echo ""
echo -e "${YLW}Or two-step:${RST}"
echo ""
echo "  curl -fsSL http://${HOST_IP}:${PORT}/inventory.sh -o /tmp/inventory.sh"
echo "  sudo bash /tmp/inventory.sh ${HOST_IP} ${KEY_VAL}"
echo ""
echo -e "${BLD}══════════════════════════════════════════${RST}"
echo ""
echo -e "  Schedule:   ${SCHEDULE_HUMAN}"
echo -e "  Serve dir:  ${INSTALL_DIR}"
echo -e "  Port:       ${PORT}"
echo -e "  Host IP:    ${HOST_IP}"
echo ""
ok "Setup complete."
