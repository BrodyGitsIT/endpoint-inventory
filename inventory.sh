#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
#  inventory.sh  —  System inventory agent
#  Args: <HOST_IP> <DECRYPT_KEY>
#  Installs to: /opt/scripts/inventory/inventory.sh
#  Timer:       driven by ONCALENDAR value from server config
# ════════════════════════════════════════════════════════════════

VERSION="1.0.5"

# ── Args ──────────────────────────────────────────────────────────────────────
HOST="${1:-}"
DECRYPT_KEY="${2:-}"

if [[ -z "$HOST" || -z "$DECRYPT_KEY" ]]; then
  echo "ERROR: Usage: $0 <HOST_IP> <DECRYPT_KEY>"
  echo "       Get the install command from host.sh output."
  exit 1
fi

PORT=3333
INSTALL_BIN="/opt/scripts/inventory/inventory.sh"
SERVICE_FILE="/etc/systemd/system/inventory.service"
TIMER_FILE="/etc/systemd/system/inventory.timer"

# ── Colour helpers ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
  CYN='\033[0;36m'; RST='\033[0m'
else
  RED=''; GRN=''; YLW=''; CYN=''; RST=''
fi

info()  { echo -e "${CYN}[inv]${RST} $*"; }
ok()    { echo -e "${GRN}[inv]${RST} $*"; }
warn()  { echo -e "${YLW}[inv]${RST} $*" >&2; }
die()   { echo -e "${RED}[inv] ERROR:${RST} $*" >&2; exit 1; }

# ── Fetch + decrypt config in memory ─────────────────────────────────────────
#    Downloads server.env.enc, decrypts with the provided key — never writes
#    the plaintext to disk.  Falls back to local URL if public URL fails.
fetch_config() {
  local BASE_URL="http://${HOST}:${PORT}"
  local ENC_DATA

  ENC_DATA="$(curl -fsSL "${BASE_URL}/server.env.enc")" \
    || die "Failed to fetch server.env.enc from ${BASE_URL}"

  local PLAIN
  PLAIN="$(printf '%s' "$ENC_DATA" | \
    openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -d -a \
      -pass "pass:${DECRYPT_KEY}" 2>/dev/null)" \
    || die "Decryption failed — wrong key or corrupted file."

  # Export config vars into current shell
  while IFS='=' read -r KEY VAL; do
    [[ -z "$KEY" || "$KEY" == \#* ]] && continue
    # Strip trailing whitespace/CR
    VAL="${VAL%$'\r'}"
    VAL="${VAL%$' '}"
    export "$KEY"="$VAL"
  done <<< "$PLAIN"
}

info "Fetching config from http://${HOST}:${PORT}..."
fetch_config
ok  "Config loaded."

# ── Validate required fields ──────────────────────────────────────────────────
[[ -z "${NC_URL:-}"    ]] && die "Config missing NC_URL"
[[ -z "${NC_USER:-}"   ]] && die "Config missing NC_USER"
[[ -z "${NC_PASS:-}"   ]] && die "Config missing NC_PASS"
[[ -z "${NC_FOLDER:-}" ]] && die "Config missing NC_FOLDER"

# Default schedule if host didn't set one
ONCALENDAR="${ONCALENDAR:-Mon *-*-* 08:00:00}"

# ── Host identity ─────────────────────────────────────────────────────────────
_HOSTNAME="$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]' || uname -n)"
NC_FOLDER="${NC_FOLDER%/}/${_HOSTNAME}"

# ── Self-install to INSTALL_BIN ───────────────────────────────────────────────
install_self() {
  local REMOTE_SCRIPT
  REMOTE_SCRIPT="$(curl -fsSL "http://${HOST}:${PORT}/inventory.sh")" \
    || { warn "Could not fetch remote inventory.sh — keeping current."; return; }

  local REMOTE_VER
  REMOTE_VER="$(grep -m1 '^VERSION=' <<< "$REMOTE_SCRIPT" | cut -d'"' -f2)"

  if [[ -f "$INSTALL_BIN" ]] && [[ "$REMOTE_VER" == "$VERSION" ]]; then
    ok "Already up to date (v${VERSION}) at ${INSTALL_BIN}"
    return
  fi

  info "Installing v${REMOTE_VER} → ${INSTALL_BIN}"
  sudo mkdir -p "$(dirname "$INSTALL_BIN")"
  printf '%s\n' "$REMOTE_SCRIPT" | sudo tee "$INSTALL_BIN" >/dev/null
  sudo chmod +x "$INSTALL_BIN"
  ok "Installed."
}

# ── Systemd timer + service ───────────────────────────────────────────────────
install_systemd() {
  local CHANGED=0

  # ── Service unit ───────────────────────────────────────────────────────────
  local SVC_WANT
  SVC_WANT="[Unit]
Description=Inventory Agent

[Service]
Type=oneshot
ExecStart=${INSTALL_BIN} ${HOST} ${DECRYPT_KEY}"

  if [[ ! -f "$SERVICE_FILE" ]] || \
     ! diff -q <(echo "$SVC_WANT") "$SERVICE_FILE" >/dev/null 2>&1; then
    info "Writing ${SERVICE_FILE}"
    printf '%s\n' "$SVC_WANT" | sudo tee "$SERVICE_FILE" >/dev/null
    CHANGED=1
  fi

  # ── Timer unit ─────────────────────────────────────────────────────────────
  local TIMER_WANT
  TIMER_WANT="[Unit]
Description=Run Inventory Agent — ${ONCALENDAR}

[Timer]
OnCalendar=${ONCALENDAR}
Persistent=true

[Install]
WantedBy=timers.target"

  if [[ ! -f "$TIMER_FILE" ]] || \
     ! diff -q <(echo "$TIMER_WANT") "$TIMER_FILE" >/dev/null 2>&1; then
    info "Writing ${TIMER_FILE}"
    printf '%s\n' "$TIMER_WANT" | sudo tee "$TIMER_FILE" >/dev/null
    CHANGED=1
  fi

  if [[ "$CHANGED" -eq 1 ]]; then
    sudo systemctl daemon-reload
  fi

  sudo systemctl enable --now inventory.timer
  ok "Timer active:  $(sudo systemctl status inventory.timer \
        --no-pager -l 2>/dev/null | grep -E 'Active:|Trigger:' | xargs)"
}

# ── NC URL resolution ─────────────────────────────────────────────────────────
resolve_nc_url() {
  if curl -fsSL --max-time 4 -o /dev/null "${NC_URL}/status.php" 2>/dev/null; then
    printf '%s' "$NC_URL"
  elif [[ -n "${NC_URL_LOCAL:-}" ]]; then
    warn "Public NC unreachable — falling back to ${NC_URL_LOCAL}"
    printf '%s' "$NC_URL_LOCAL"
  else
    die "Nextcloud unreachable at ${NC_URL} and no local fallback set."
  fi
}

# ── Helpers ───────────────────────────────────────────────────────────────────
have()  { command -v "$1" >/dev/null 2>&1; }
safe()  { "$@" 2>/dev/null || echo "N/A"; }
iface() { ip route 2>/dev/null | awk '/default/ {print $5; exit}'; }

normalize_dav_path() { echo "${1%/}/"; }

# ── WebDAV mkdir -p ───────────────────────────────────────────────────────────
mkdir_dav() {
  local BASE_DAV="$1"
  local path=""
  IFS='/' read -ra parts <<< "$2"

  for p in "${parts[@]}"; do
    [[ -z "$p" ]] && continue
    path="${path}/${p}"
    local url
    url="${BASE_DAV}$(normalize_dav_path "$path")"
    local HTTP
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
      -u "${NC_USER}:${NC_PASS}" \
      -X MKCOL "$url")
    [[ "$HTTP" =~ ^(201|405|409)$ ]] || {
      warn "MKCOL failed: $url (HTTP $HTTP)"
      return 1
    }
  done
}

# ── Gather functions ──────────────────────────────────────────────────────────
Gather-Host() {
  echo -e "## 🖥 Host Information\n"
  echo "- **Hostname:** $_HOSTNAME"
  echo "- **OS:** $(uname -s)"
  echo "- **Kernel:** $(uname -r)"
  echo "- **Architecture:** $(uname -m)"
  local CPU RAM
  CPU=$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^[[:space:]]+/,"",$2); print $2}')
  RAM=$(free -h 2>/dev/null | awk '/Mem:/ {print $2}')
  echo "- **CPU:** ${CPU:-N/A}"
  echo "- **RAM:** ${RAM:-N/A}"
  echo "- **Uptime:** $(uptime -p 2>/dev/null || uptime)"
  echo ""
}

Gather-User() {
  echo -e "## 👤 User Information\n"
  echo "- **Current User:** $(whoami)"
  echo "- **Groups:** $(groups)"
  echo "- **All Users:** $(cut -d: -f1 /etc/passwd | paste -sd, -)"
  echo ""
  echo "### 🔐 Sudo Access"
  echo '```'
  sudo -n -l 2>/dev/null || echo "sudo requires password / unavailable"
  echo '```'
  echo ""
}

Gather-Network() {
  echo -e "## 🌐 Network Information\n"
  echo "- **Interface:** $(iface)"
  echo "- **IP Addresses:** $(ip -o addr show 2>/dev/null | awk '{print $4}' | paste -sd, -)"
  echo "- **MAC Addresses:** $(ip link 2>/dev/null | awk '/ether/ {print $2}' | paste -sd, -)"
  echo "- **Gateway:** $(ip route 2>/dev/null | awk '/default/ {print $3; exit}')"
  echo ""
  echo "### DNS"
  echo "- resolv.conf: $(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd, -)"
  echo ""
  echo "### 🔌 Listening Ports"
  echo '```'
  safe ss -tulpn
  echo '```'
  echo ""
}

Gather-Virtualization() {
  echo -e "## 🧱 Virtualization\n"
  local found=0

  if have docker; then
    found=1
    echo "### 🐳 Docker"
    echo '```'
    sudo docker ps -a 2>/dev/null
    echo '```'
    echo ""
  fi

  if have virsh; then
    found=1
    echo "### 🖥 Libvirt"
    echo '```'
    sudo virsh list --all 2>/dev/null
    echo '```'
    echo ""
  fi

  if have pct; then
    found=1
    echo "### 📦 LXC (Proxmox)"
    echo '```'
    sudo pct list 2>/dev/null
    echo '```'
    echo ""
  elif have lxc-ls; then
    found=1
    echo "### 📦 LXC"
    echo '```'
    sudo lxc-ls --fancy 2>/dev/null
    echo '```'
    echo ""
  fi

  [[ "$found" -eq 0 ]] && echo "_No container/VM runtime detected._" && echo ""
}

Gather-Disks() {
  echo -e "## 💾 Disk Usage\n"
  echo '```'
  df -h 2>/dev/null
  echo '```'
  echo ""
}

# ── Upload report to Nextcloud ────────────────────────────────────────────────
Upload-Report() {
  local ACTIVE_URL="$1"
  local FILE="$2"
  local DATA="$3"

  local BASE_DAV="${ACTIVE_URL}/remote.php/dav/files/${NC_USER}"

  # Ensure remote directory exists
  mkdir_dav "$BASE_DAV" "$NC_FOLDER" || return 1

  local REMOTE_PATH
  REMOTE_PATH="${BASE_DAV}/$(normalize_dav_path "$NC_FOLDER")${FILE}"

  local HTTP_STATUS
  HTTP_STATUS=$(printf '%s\n' "$DATA" | \
    curl -s -o /dev/null -w "%{http_code}" \
      -u "${NC_USER}:${NC_PASS}" \
      -T - \
      "$REMOTE_PATH")

  if [[ "$HTTP_STATUS" =~ ^(201|204)$ ]]; then
    ok "Uploaded → ${NC_FOLDER}/${FILE}  (HTTP ${HTTP_STATUS})"
  else
    warn "Upload failed (HTTP ${HTTP_STATUS}) — check NC credentials/URL"
    return 1
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
Main() {
  # 1. Ensure this script is installed and up-to-date
  install_self

  # 2. Ensure systemd timer is in place (schedule from config)
  install_systemd

  # 3. Resolve which Nextcloud URL to use
  local ACTIVE_NC_URL
  ACTIVE_NC_URL="$(resolve_nc_url)"

  # 4. Build report
  local TIMESTAMP
  TIMESTAMP="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

  local REPORT
  REPORT=$(cat <<EOF
# 🧾 System Inventory Report

| Field      | Value |
|------------|-------|
| **Version**   | ${VERSION} |
| **Timestamp** | ${TIMESTAMP} |
| **Host**      | ${_HOSTNAME} |
| **Schedule**  | ${ONCALENDAR} |

---

$(Gather-Host)
$(Gather-User)
$(Gather-Network)
$(Gather-Disks)
$(Gather-Virtualization)

---
EOF
)

  # 5. Print locally
  echo "$REPORT"

  # 6. Upload
  local FILE="${_HOSTNAME}-$(date +%Y-%m-%d_%H-%M-%S).md"
  Upload-Report "$ACTIVE_NC_URL" "$FILE" "$REPORT"
}

Main "$@"
