#!/usr/bin/env bash

set -e

PORT=3333
INSTALL_DIR="/opt/scripts/inventory"
SERVICE_NAME="inventory-host"

echo "======================================="
echo "   Inventory Tool Server Setup Wizard"
echo "======================================="

# ── Create config if missing ──────────────────────────────────────────────────
if [[ ! -f "./server.env" ]]; then
  echo ""
  echo "[host] no server.env found — creating new config"
  echo ""

  read -rp "Nextcloud URL (https://cloud.example.com): " NC_URL
  read -rp "Nextcloud bot username: " NC_USER
  read -rp "Nextcloud app password: " NC_PASS
  read -rp "Nextcloud folder path (/Systems): " NC_FOLDER
  echo ""
  echo "Saving configuration..."

  cat > server.env <<EOF
NC_URL=$NC_URL
NC_USER=$NC_USER
NC_PASS=$NC_PASS
NC_FOLDER=$NC_FOLDER
EOF

  echo "[host] saved secure config to ./server.env"
fi

source ./server.env

# ── System identity ───────────────────────────────────────────────────────────
_HOSTNAME="$(cat /etc/hostname 2>/dev/null || uname -n)"
HOST_IP="${HOST_IP:-$(ip route get 1.1.1.1 | awk '{print $7; exit}')}"

echo ""
echo "[host] installing systemd service on port $PORT"

# ── Install systemd service ───────────────────────────────────────────────────
cat <<EOF | sudo tee /etc/systemd/system/${SERVICE_NAME}.service >/dev/null
[Unit]
Description=Inventory Host Server
After=network.target

[Service]
ExecStart=/usr/bin/python3 -m http.server ${PORT} --directory ${INSTALL_DIR}
WorkingDirectory=${INSTALL_DIR}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# ── Enable + start service ────────────────────────────────────────────────────
sudo systemctl daemon-reexec
sudo systemctl enable ${SERVICE_NAME}
sudo systemctl restart ${SERVICE_NAME}

echo ""
echo "======================================="
echo "        CLIENT INSTALL COMMAND"
echo "======================================="
echo ""
echo "Run this on all endpoints:"
echo ""
echo "curl -fsSL http://${HOST_IP}:${PORT}/inventory.sh -o inventory.sh && \\"
echo "bash inventory.sh ${HOST_IP}"
echo ""
echo "======================================="
echo "[host] server is now running persistently on port ${PORT}"
echo "[host] directory: ${INSTALL_DIR}"
echo ""
