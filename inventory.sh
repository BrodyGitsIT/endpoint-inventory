#!/bin/bash
VERSION="1.0.5"

# ── Require HOST ──────────────────────────────────────────────────────────────
HOST="${1:-}"

if [[ -z "$HOST" ]]; then
  echo "ERROR: Missing HOST."
  echo "Run host.sh on server and reinstall agent."
  exit 1
fi

# ── Fetch config blob ─────────────────────────────────────────────────────────
CONFIG_URL="http://${HOST}:3333/server.env"
CONFIG="$(curl -fsS "$CONFIG_URL")"

if [[ -z "$CONFIG" ]]; then
  echo "ERROR: Failed to fetch config from $HOST"
  exit 1
fi

# ── Parse config safely ───────────────────────────────────────────────────────
NC_URL=$(echo "$CONFIG" | grep '^NC_URL=' | cut -d'=' -f2-)
NC_URL_LOCAL=$(echo "$CONFIG" | grep '^NC_URL_LOCAL=' | cut -d'=' -f2-)
NC_USER=$(echo "$CONFIG" | grep '^NC_USER=' | cut -d'=' -f2-)
NC_PASS=$(echo "$CONFIG" | grep '^NC_PASS=' | cut -d'=' -f2-)
NC_FOLDER=$(echo "$CONFIG" | grep '^NC_FOLDER=' | cut -d'=' -f2-)
UPDATE_URL=$(echo "$CONFIG" | grep '^UPDATE_URL=' | cut -d'=' -f2-)

# ── Host identity ─────────────────────────────────────────────────────────────
_HOSTNAME="$(cat /etc/hostname 2>/dev/null || uname -n)"
NC_FOLDER="$NC_FOLDER/$_HOSTNAME"

# ── Safety check ──────────────────────────────────────────────────────────────
if [[ -z "$NC_URL" || -z "$NC_USER" || -z "$NC_PASS" ]]; then
  echo "ERROR: Invalid config received. Reinstall required."
  exit 1
fi

# ── Update source ─────────────────────────────────────────────────────────────
UPDATE_URL="http://${HOST}:3333/inventory.sh"
SELF="/opt/scripts/inventory/inventory.sh"

# ── Persistence Setup (auto systemd install for inventory) ────────────────

HOST="${HOST:-$1}"

if [[ -z "$HOST" ]]; then
  echo "ERROR: Missing HOST. Reinstall required."
  exit 1
fi

INSTALL_BIN="/opt/scripts/inventory/inventory.sh"
SERVICE_FILE="/etc/systemd/system/inventory.service"
TIMER_FILE="/etc/systemd/system/inventory.timer"

# ── Install script if missing or outdated ────────────────────────────────────
if [[ ! -f "$INSTALL_BIN" ]]; then
  echo "[inventory] installing binary from host..."

  curl -fsSL "http://${HOST}:3333/inventory.sh" -o "$INSTALL_BIN"
  chmod +x "$INSTALL_BIN"
fi

# ── Install systemd service (oneshot runner) ─────────────────────────────────
if [[ ! -f "$SERVICE_FILE" ]]; then
  cat <<EOF | sudo tee "$SERVICE_FILE" >/dev/null
[Unit]
Description=Inventory Script

[Service]
Type=oneshot
ExecStart=/usr/local/bin/inventory.sh
EOF
fi

# ── Install systemd timer (weekly execution) ─────────────────────────────────
if [[ ! -f "$TIMER_FILE" ]]; then
  cat <<EOF | sudo tee "$TIMER_FILE" >/dev/null
[Unit]
Description=Run Inventory Weekly

[Timer]
OnCalendar=Mon *-*-* 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
fi

# ── Enable systemd components ───────────────────────────────────────────────
sudo systemctl daemon-reload
sudo systemctl enable --now inventory.timer

# ── Helpers ───────────────────────────────────────────────────────────────────
have()  { command -v "$1" >/dev/null 2>&1; }

normalize_dav_path() {
    echo "${1%/}/"
}

# Resolve which NC_URL to use — fall back to localhost if DNS fails
_resolve_nc_url() {
    if curl -fsSL --max-time 3 -o /dev/null "$NC_URL/status.php" 2>/dev/null; then
        echo "$NC_URL"
    else
        echo "[nc] DNS/TLS failed for $NC_URL — falling back to $NC_URL_LOCAL" >&2
        echo "$NC_URL_LOCAL"
    fi
}
safe()  { "$@" 2>/dev/null || echo "N/A"; }
iface() { ip route 2>/dev/null | awk '/default/ {print $5; exit}'; }

# Escape a string for safe embedding in a JSON value
json_esc() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ── Self-update ───────────────────────────────────────────────────────────────
Self-Update() {
    local TMPFILE
    TMPFILE="$(mktemp /tmp/inventory.update.XXXXXX)"

    if ! curl -fsSL -o "$TMPFILE" "$UPDATE_URL" 2>/dev/null; then
        echo "[update] WARNING: Could not reach $UPDATE_URL — continuing with current version." >&2
        rm -f "$TMPFILE"
        return
    fi

    local REMOTE_VER
    REMOTE_VER=$(grep -m1 '^VERSION=' "$TMPFILE" | cut -d'"' -f2)

    if [[ -z "$REMOTE_VER" ]]; then
        echo "[update] WARNING: Could not parse remote version — skipping update." >&2
        rm -f "$TMPFILE"
        return
    fi

    if [[ "$REMOTE_VER" == "$VERSION" ]]; then
        echo "[update] Already up to date (v$VERSION)." >&2
        rm -f "$TMPFILE"
        return
    fi

    echo "[update] New version detected: v$REMOTE_VER (current: v$VERSION) — updating..." >&2

    if sudo cp "$TMPFILE" "$SELF" && sudo chmod +x "$SELF"; then
        rm -f "$TMPFILE"
        echo "[update] Update applied. Re-executing..." >&2
        exec sudo "$SELF" "$@"
    else
        echo "[update] ERROR: Failed to write $SELF — check permissions." >&2
        rm -f "$TMPFILE"
    fi
}

# ── WebDAV mkdir -p ───────────────────────────────────────────────────────────
mkdir_dav() {
    local path=""
    IFS='/' read -ra parts <<< "$1"

    for p in "${parts[@]}"; do
        [[ -z "$p" ]] && continue
        path="$path/$p"

        local url
        url="$NC_URL/remote.php/dav/files/$NC_USER$(normalize_dav_path "$path")"

        HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
            -u "$NC_USER:$NC_PASS" \
            -X MKCOL "$url")

        [[ "$HTTP" =~ ^(201|405|409)$ ]] || {
            echo "MKCOL failed: $url (HTTP $HTTP)" >&2
            return 1
        }
    done
}

# ── 🖥 HOST INFO ───────────────────────────────────────────────
Gather-Host() {
    echo -e "## 🖥 Host Information\n"

    echo "- **Hostname:** $_HOSTNAME"
    echo "- **OS:** $(uname -s)"
    echo "- **Kernel:** $(uname -r)"
    echo "- **Architecture:** $(uname -m)"

    CPU=$(lscpu 2>/dev/null | awk -F: '/Model name/ {print $2}' | xargs)
    RAM=$(free -h 2>/dev/null | awk '/Mem:/ {print $2}')

    echo "- **CPU:** ${CPU:-N/A}"
    echo "- **RAM:** ${RAM:-N/A}"
    echo
}

# ── 👤 USER INFO ──────────────────────────────────────────────
Gather-User() {
    echo -e "## 👤 User Information\n"

    echo "- **Current User:** $(whoami)"
    echo "- **Groups:** $(groups)"
    echo "- **All Users:** $(cut -d: -f1 /etc/passwd | paste -sd, -)"

    echo -e "\n### 🔐 Sudo Access"
    sudo -n -l 2>/dev/null || echo "sudo requires password / unavailable"
    echo
}

# ── 🌐 NETWORK INFO ───────────────────────────────────────────
Gather-Network() {
    echo -e "## 🌐 Network Information\n"

    echo "- **Interface:** $(iface)"
    echo "- **IP Addresses:** $(ip -o addr show | awk '{print $4}' | paste -sd, -)"
    echo "- **MAC Addresses:** $(ip link | awk '/ether/ {print $2}' | paste -sd, -)"
    echo "- **Gateway:** $(ip route | awk '/default/ {print $3; exit}')"

    echo -e "\n### DNS"
    echo "- resolv.conf: $(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd, -)"

    echo -e "\n### 🔌 Listening Ports"
    echo '```'
    safe ss -tulpn
    echo '```'
    echo
}

# ── 🧱 VIRTUALIZATION ─────────────────────────────────────────
Gather-Virtualization() {
    echo -e "## 🧱 Virtualization\n"

    if have docker; then
        echo "### 🐳 Docker"
        echo '```'
        sudo docker ps -a 2>/dev/null
        echo '```'
        echo
    fi

    if have virsh; then
        echo "### 🖥 Libvirt"
        echo '```'
        sudo virsh list --all 2>/dev/null
        echo '```'
        echo
    fi

    if have pct; then
        echo "### 📦 LXC (Proxmox)"
        echo '```'
        sudo pct list 2>/dev/null
        echo '```'
        echo
    elif have lxc-ls; then
        echo "### 📦 LXC"
        echo '```'
        sudo lxc-ls --fancy 2>/dev/null
        echo '```'
        echo
    fi
}

# ── Upload ─────────────────────────────────────────────────────
Upload-Report() {
    local FILE="$1"
    local DATA="$2"
    local TMPFILE="/tmp/$FILE"
    local BASE="$NC_URL/remote.php/dav/files/$NC_USER/$(normalize_dav_path "$NC_FOLDER")"

    mkdir_dav "$NC_FOLDER" || return 1

    printf "%s\n" "$DATA" > "$TMPFILE"
    echo "Saved:     $TMPFILE"
    echo "Uploading: $BASE/$FILE"

    local HTTP_STATUS
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "$NC_USER:$NC_PASS" -T "$TMPFILE" "$BASE/$FILE")

    echo "HTTP=$HTTP_STATUS"

    if [[ "$HTTP_STATUS" =~ ^(201|204)$ ]]; then
        echo "Uploaded:  $NC_FOLDER/$FILE"
        rm -f "$TMPFILE"
    else
        echo "Upload failed (HTTP $HTTP_STATUS)" >&2
        return 1
    fi
}

# ── MAIN REPORT BUILDER ───────────────────────────────────────
Main() {
    Self-Update "$@"
    NC_URL=$(_resolve_nc_url)

    TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

    REPORT=$(
        cat <<EOF
# 🧾 System Inventory Report

- **Version:** $VERSION  
- **Timestamp:** $TIMESTAMP  
- **Host:** $_HOSTNAME  

---

$(Gather-Host)
$(Gather-User)
$(Gather-Network)
$(Gather-Virtualization)

---


EOF
)

    FILE="$_HOSTNAME-$(date +%Y-%m-%d_%H-%M-%S).md"

    echo "$REPORT"
    Upload-Report "$FILE" "$REPORT"
}

Main "$@"
