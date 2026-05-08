# endpoint-inventory

Lightweight Linux endpoint inventory that uploads rich Markdown reports directly to Nextcloud.

`endpoint-inventory` gathers deep system information and stores it in a clean, readable `.md` format for easy auditing, documentation, and troubleshooting.

It collects:

* **System details** (hostname, OS, kernel, uptime)
* **CPU information** (model, cores, virtualization flags)
* **Memory usage** (RAM + swap)
* **Storage** (mounts, usage, filesystem types)
* **Networking**

  * Interfaces
  * IP addresses
  * DNS servers
  * Default gateway
  * Open listening ports
* **Virtualization / Containers**

  * KVM / VMware / Hyper-V / VirtualBox detection
  * Docker / Podman / LXC awareness
* **Services / runtime info**
* **And more**

All reports are uploaded automatically into organized folders in Nextcloud.

---

# Why I built this

I wanted something that was:

✅ lightweight
✅ easy to deploy
✅ centralized
✅ secure
✅ human-readable
✅ self-updating

Most inventory tools are heavy, expensive, or store data in ugly databases. This stores everything as **plain Markdown in Nextcloud**, which makes it simple to browse, search, and archive.

---

# Architecture

Endpoint → Host Server → Nextcloud

```text
Linux Endpoint
    ↓
inventory.sh
    ↓
Your Inventory Host
(serves latest script + encrypted credentials)
    ↓
HaRP / AppAPI
    ↓
Nextcloud WebDAV Upload
    ↓
/Systems/<hostname>/<report>.md
```

Only your **inventory host** stores Nextcloud credentials.

Endpoints only know:

* inventory host IP / hostname
* where to fetch updated scripts

No app passwords are stored on endpoints.

---

# Setup

## 1) Create a Nextcloud Bot Account

Create a dedicated upload account so no personal credentials are embedded anywhere.

### Steps

1. Open:

```text
https://nextcloud.example.com/settings/users
```

2. Create a new user:

Example:

```text
bot
```

3. Set yourself as manager/owner.

4. Create an Inventory folder in your main account:

```text
Inventory/
```

5. Share it directly with the bot account:

✅ Allow editing

> Group sharing is not recommended here—direct share works reliably with API access.

6. Log in as the bot user.

7. Go to:

```text
Administration Settings → Security
```

8. Create an **App Password**.

Save it—you'll need it for host setup.

---

## 2) Install Nextcloud HaRP (AppAPI)

This is what enables secure automation and uploads into Nextcloud.

Run:

```bash
docker run -d \
  --name appapi-harp \
  --restart unless-stopped \
  -p 8780:8780 \
  -p 8782:8782 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /home/youruser/certs:/certs \
  -e HP_SHARED_KEY=CHANGE_ME \
  -e NC_INSTANCE_URL=https://cloud.example.com \
  ghcr.io/nextcloud/nextcloud-appapi-harp:release
```

Then in Nextcloud:

```text
Administration Settings
→ AppAPI
→ Deploy Daemons
→ Add
```

Configure:

* **Daemon Type:** HaRP
* **Enable HaRP:** Yes
* **Shared Key:** same value as `HP_SHARED_KEY`
* **Use default ports**

Click:

```text
Check Connection
```

You should see success.

---

## 3) Setup the Inventory Host

This is your central management server.

It:

* stores encrypted credentials
* serves the latest inventory script
* generates install commands for endpoints
* keeps endpoints updated automatically

Clone repo:

```bash
git clone https://github.com/BrodyGitsIT/endpoint-inventory
cd endpoint-inventory
chmod +x host.sh
sudo ./host.sh
```

Follow prompts.

At the end you'll get:

```text
=======================================
        CLIENT INSTALL COMMAND
=======================================

curl -fsSL http://SERVER_IP:3333/inventory.sh -o inventory.sh && \
bash inventory.sh SERVER_IP

=======================================
```

That becomes your endpoint deployment command.

---

## 4) Deploy to Endpoints

Run the generated command on any Linux endpoint:

```bash
curl -fsSL http://SERVER_IP:3333/inventory.sh -o inventory.sh && \
bash inventory.sh SERVER_IP
```

Done.

The endpoint will:

* install inventory service
* self-update from host
* generate Markdown reports
* upload automatically into Nextcloud

---

# Example Output

```text
Saved:     /tmp/pop-os-2026-05-08_14-07-07.md
Uploading: https://nextcloud.example.com/remote.php/dav/files/bot/Systems/pop-os/pop-os-2026-05-08_14-07-07.md
HTTP=201
Uploaded:  /Systems/pop-os/pop-os-2026-05-08_14-07-07.md
```

Result in Nextcloud:

```text
Inventory/
└── Systems/
    ├── server01/
    ├── laptop01/
    ├── pop-os/
    └── workstation02/
```

Each endpoint gets its own history folder.

---

# Security Model

Only the inventory host stores:

* Nextcloud username
* App password
* encryption material

Endpoints do **not** store cloud credentials.

This keeps rollout simple and reduces credential exposure.

---

# Use Cases

Perfect for:

* Home labs
* MSP inventory
* Linux fleet documentation
* Security auditing
* Asset management
* Change tracking
* Incident response notes

---

# Contributing

PRs and ideas welcome.

Build cool stuff.
