# Server-Infra (rmx-server-infra): access and hardening

| | |
|---|---|
| Server | RMX-SERVER / VPS-1, `45.81.252.43`, hostname `vps3124` |
| OS | Ubuntu 24.04.5 LTS, kernel `6.8.0-147-generic` (after reboot) |
| Memory | ~1 GB RAM + 2 GB swapfile `/swapfile` (`vm.swappiness=10`) |
| Host key | ED25519 `SHA256:OHYSCh1xGk1SAUt6brhpWSneyloXz8wfp35j+VipXqI` |
| Admin user | `rmx` (sudo, no password; in group `docker`) |
| Admin PC | Windows 11, PowerShell, OpenSSH client |
| Setup date | 2026-10-14 (times in UTC) |
| Domain | `rmx.lt` (`@` A → this IP; `api`, `mqtt`, `www` CNAME → `rmx.lt.`) |
| Public ports | 22 (SSH), 80 + 443 (Caddy), 8883 (MQTT over TLS, Mosquitto). See [§10](#10-docker--services) |

**This page** describes the current state; history lives in git and the PRs of [rmx-server-infra](https://github.com/rmx-lt/rmx-server-infra). The [rmx-server-infra repo](https://github.com/rmx-lt/rmx-server-infra) holds the config and code. [`config/`](https://github.com/rmx-lt/rmx-server-infra/tree/development/config) holds copies of the server's config files, pulled with the commands in [§9](#9-updating-this-repo). [`services/`](https://github.com/rmx-lt/rmx-server-infra/tree/development/services) holds the Docker Compose stack, run from the server clone (see [§10](#10-docker--services)).

> No secrets in this repo: no passwords, private keys or tokens. `.gitignore` blocks common key files.

**Setup as code:** [`ansible/`](https://github.com/rmx-lt/rmx-server-infra/tree/development/ansible) rebuilds this whole server from an empty Ubuntu 24.04 VPS with one command, and re-applies it safely later (see [§11](#11-setup-as-code-ansible)). The sections below remain the record of what the server is and how it got here.

---

## 1. How to connect

From the Windows PC:

```powershell
ssh rmx-vps          # logs in as rmx with the key
sudo -i              # become root (no password)
```

Other ways in:

| Way in | Who | Requirements |
|---|---|---|
| `ssh rmx-vps` | `rmx` | Private key `~/.ssh/rmx-vps_ed25519` + its passphrase (or key loaded in ssh-agent) |
| Provider dashboard → **Terminal** tab | `root` | Root password; works **only** because sshd allows root+password from `45.81.252.94` |
| Anything else (e.g. `ssh root@45.81.252.43`) | — | **Refused** (`Permission denied (publickey)`) |

> ⚠️ Back up `%USERPROFILE%\.ssh\rmx-vps_ed25519` and remember the passphrase. If both the key and the dashboard terminal are lost, only the provider's console / rescue system can get you back in.

---

## 2. Local (Windows PC) setup

| Item | Value |
|---|---|
| `%USERPROFILE%\.ssh\` | Created (did not exist before) |
| Private key | `%USERPROFILE%\.ssh\rmx-vps_ed25519` (ed25519, passphrase-protected) |
| Public key | `%USERPROFILE%\.ssh\rmx-vps_ed25519.pub` — `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIELxb1opNw3MfIQJzUkGWRN68rBZSQbQrYgbbyFl45PY rmx-vps` |
| Key fingerprint | `SHA256:buE5PPY/pKGsMMYHrQLaRnG598ltv5jkqxvSpYVDZn4` |
| ssh-agent service | Changed from *Disabled/Stopped* → **Automatic/Running**; key added with `ssh-add` |
| `known_hosts` | Server host key added on first connect |

`%USERPROFILE%\.ssh\config` (new file):

```
Host rmx-vps
    HostName 45.81.252.43
    User rmx
    IdentityFile ~/.ssh/rmx-vps_ed25519
    IdentitiesOnly yes
```

---

## 3. Server state found before setup

- Only access: `root` + password (via keyboard-interactive/PAM).
- `/etc/ssh/sshd_config` line 47 had **`PubkeyAuthentication no`** — keys were refused entirely.
- `PermitRootLogin yes`, `KbdInteractiveAuthentication yes` (main file);
  `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf` had `PasswordAuthentication no`, but passwords still worked through keyboard-interactive.
- No firewall (ufw inactive), no fail2ban.
- Only public listener: sshd on port 22.
- Packages already up to date; a reboot was pending (newer kernel).

---

## 4. Changes made (in order)

| # | Time (UTC) | Change |
|---|---|---|
| 1 | ~19:24 | Public key appended to `/root/.ssh/authorized_keys` (via password login) |
| 2 | ~19:26 | `sshd_config` line 47 → `PubkeyAuthentication yes`, `systemctl reload ssh`. Backup: `/etc/ssh/sshd_config.bak-pubkey-off` (original file) |
| 3 | ~19:28 | `apt-get update && apt-get upgrade` — nothing to upgrade (3 phased: apparmor, libapparmor1, open-vm-tools) |
| 4 | ~19:29 | User `rmx` created (no password, shell `/bin/bash`, groups `sudo`) |
| 5 | ~19:29 | `/etc/sudoers.d/rmx` = `rmx ALL=(ALL) NOPASSWD:ALL` (root:root, 0440, checked with `visudo -c`) |
| 6 | ~19:29 | `/home/rmx/.ssh/authorized_keys` = same public key (rmx:rmx, dir 0700, file 0600) |
| 7 | ~19:49 | SSH hardening (see §5). Backup: `/etc/ssh/sshd_config.bak-pre-hardening`. Tested with a 5-min auto-rollback timer (`ssh-rollback`), cancelled after a fresh `ssh rmx-vps` login succeeded |
| 8 | ~19:51 | `ufw allow OpenSSH`, `ufw enable` |
| 9 | ~19:51 | `fail2ban` installed and enabled (default `sshd` jail) |
| 10 | ~19:56 | Rebooted → kernel `6.8.0-87` → `6.8.0-147`; everything verified after boot |
| 11 | ~20:04 | Dashboard terminal exception: root+password from `45.81.252.94` only (see §5). Backup: `/etc/ssh/sshd_config.bak-pre-dashboard`. IP whitelisted in fail2ban |
| 12 | ~20:06 | `/root/.ssh/authorized_keys` emptied — no key logs in as root any more |

---

## 5. Current SSH configuration

**`/etc/ssh/sshd_config.d/00-hardening.conf`** (new; read first, so it wins):

```
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
```

**`/etc/ssh/sshd_config`** (edited to match, so the file isn't misleading):

```
PermitRootLogin no                    # line 42
PubkeyAuthentication yes              # line 47
PasswordAuthentication no             # line 66
KbdInteractiveAuthentication no       # line 71

# appended at end of file:
# Provider dashboard web terminal (SSH bridge) - root password from this IP only
Match Address 45.81.252.94
    PermitRootLogin yes
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
```

> The `Match` block must stay at the **end** of the main file. Don't put it in `sshd_config.d/`: the drop-ins are included at the top of the main file, so a `Match` there would also apply to every setting after it.

Effective result (`sshd -T -C user=root,addr=…`):

| From | Root login | Password | Key |
|---|---|---|---|
| `45.81.252.94` (dashboard) | yes | yes | yes (but root has no keys) |
| anywhere else | **no** | **no** | yes (`rmx` only) |

Backups in `/etc/ssh/`:

| File | Contents |
|---|---|
| `sshd_config.bak-pubkey-off` | Original file (keys disabled, root+password open) |
| `sshd_config.bak-pre-hardening` | Keys enabled, before hardening |
| `sshd_config.bak-pre-dashboard` | Hardened, before the dashboard `Match` block |

---

## 6. Firewall & fail2ban

**ufw** — active, starts at boot:

```
Default: deny (incoming), allow (outgoing), disabled (routed)
22/tcp (OpenSSH)        ALLOW IN    Anywhere
22/tcp (OpenSSH (v6))   ALLOW IN    Anywhere (v6)
```

```
80/tcp                  ALLOW IN    Anywhere        # HTTP (Caddy, ACME)
443/tcp                 ALLOW IN    Anywhere        # HTTPS (Caddy)
8883/tcp                ALLOW IN    Anywhere        # MQTT over TLS (Mosquitto)
(+ the same three for v6)
```

Opening another port: `sudo ufw allow PORT/tcp comment "what it is"`.

> ⚠️ **ufw does not protect Docker ports.** A port published by a container is reachable from the internet even without a ufw rule. See [§10](#10-docker--services).

**fail2ban** — enabled, `sshd` jail on, backend `systemd`, action `nftables`.

- `/etc/fail2ban/jail.d/defaults-debian.conf` — package default (enables `[sshd]`)
- `/etc/fail2ban/jail.d/ignore-dashboard.local` (new):
  ```
  [DEFAULT]
  ignoreip = 127.0.0.1/8 ::1 45.81.252.94
  ```

Useful commands:

```bash
sudo fail2ban-client status sshd          # bans / failures
sudo fail2ban-client set sshd unbanip IP  # unban an address
sudo ufw status verbose
```

---

## 7. Security audit (2026-10-14)

**Log coverage:** logs only cover **31 Oct – 3 Nov 2025** (hostname `ubuntu-2404`) and **14 Oct 2026 from 17:25** (hostname `vps3124`). There are **no journal entries or boots in between**. The root password was set and the hostname changed right after today's boot. This looks like a provider (re)deploy from a late-2025 image, not a year of continuous uptime. Deleted logs can't be ruled out, but nothing else points to that.

**Successful logins**

| IP | When | What | Assessment |
|---|---|---|---|
| *admin PC* (home IP omitted) | 2026-10-14 | root (password, then key), rmx (key) | Admin PC — expected |
| `213.159.55.52` | 2025-11-03 09:31 & 11:44 | root (password), ~1 min each; also 5 failed attempts | **Unverified** — probably the provider building the image. Confirm with the provider if you don't recognise it |

**Failed attempts** (all on 2026-10-14, about 2.5 hours of uptime): 37 PAM authentication failures, 35 `btmp` entries, ~10 source IPs. Top: `94.232.225.98` (9), `45.148.10.141` (9). Typical internet scanning. fail2ban banned `45.148.10.141` and `193.47.62.69` right after install.

**Persistence checks — nothing found:**
- UID 0 accounts: only `root`. Login shells: only `root`, `rmx`.
- `authorized_keys` on the whole disk: only the setup key (now `rmx` only).
- Crontabs: none for users; `/etc/cron.d` contains only `e2scrub_all`, `sysstat`.
- No custom systemd units; `/tmp`, `/var/tmp`, `/dev/shm` clean; no unusual processes.
- Public listeners: only sshd on 22.

---

## 8. Undo / maintenance

| Task | How |
|---|---|
| Stop / remove Caddy or Mosquitto | See [§10 Undo](#undo) |
| Check memory / swap | `free -h`, `swapon --show`. If swap is used heavily all the time, the server needs more RAM |
| Remove the swapfile | `sudo swapoff /swapfile`, delete the `/swapfile` line from `/etc/fstab` (backup: `/etc/fstab.bak-pre-swap`), `sudo rm /swapfile /etc/sysctl.d/60-swappiness.conf`, `sudo systemctl daemon-reload` |
| Remove dashboard root access | Delete the `Match Address 45.81.252.94` block at the end of `/etc/ssh/sshd_config`, `sudo sshd -t && sudo systemctl reload ssh`; optionally remove `/etc/fail2ban/jail.d/ignore-dashboard.local` and `sudo systemctl restart fail2ban` |
| Change the root password | `sudo passwd root` (used only by the dashboard terminal) |
| Add another key / PC | Append its `.pub` line to `/home/rmx/.ssh/authorized_keys` |
| Always before restarting ssh | `sudo sshd -t`, and keep a working session open |
| Updates | `sudo apt update && sudo apt upgrade`; reboot if `/var/run/reboot-required` exists |

---

## 9. Updating this repo

After changing something on the server:

1. Update this page in the same PR if the current state changed (current state only, no dated log).
2. Put the backup file and the undo steps in the PR description when they matter.
3. Refresh the config copies (PowerShell, from the repo folder):

   ```powershell
   ssh rmx-vps 'sudo cat /etc/ssh/sshd_config' | Set-Content config\ssh\sshd_config
   ssh rmx-vps 'sudo cat /etc/ssh/sshd_config.d/00-hardening.conf' | Set-Content config\ssh\sshd_config.d\00-hardening.conf
   ssh rmx-vps 'sudo cat /etc/fail2ban/jail.d/ignore-dashboard.local' | Set-Content config\fail2ban\jail.d\ignore-dashboard.local
   ssh rmx-vps 'sudo ufw status verbose' | Set-Content config\ufw\status.txt
   ssh rmx-vps 'cat /etc/docker/daemon.json' | Set-Content config\docker\daemon.json
   ssh rmx-vps 'cat /etc/apt/sources.list.d/docker.sources' | Set-Content config\docker\docker.sources
   ssh rmx-vps 'cat /etc/sysctl.d/60-swappiness.conf' | Set-Content config\sysctl.d\60-swappiness.conf
   ```

4. Commit and push:

   ```powershell
   git add -A
   git commit -m "Short description of the change"
   git push
   ```

5. Update the copy on the server (a read-only clone in `/opt/rmx-vps`, owned by `rmx`):

   ```powershell
   ssh rmx-vps 'git -C /opt/rmx-vps pull --ff-only'
   ```

   From the dashboard terminal (logged in as root), run it as `rmx` so file ownership stays correct:

   ```bash
   sudo -u rmx git -C /opt/rmx-vps pull --ff-only
   ```

The server docs live in this wiki (since 2026-10-31); the old `~/VPS-SETUP.md` symlink to the README is gone.

The server clone can also **push**, using a repo-only deploy key (see below). Pull before editing on either side, so the PC and server copies don't diverge.

### Pushing from the server

- Deploy key `/home/rmx/.ssh/github-rmx-vps` (ed25519, no passphrase), added to this repo with **write access**. It works for this repo only, not the rest of the GitHub account.
- The playbook sets the remote of `/opt/rmx-vps` on every run (`roles/stack/tasks/repo.yml`), so a repo rename means changing that URL too.
- `~rmx/.ssh/config` has `Host github-rmx-vps` → `github.com` with that key; the remote is `git@github-rmx-vps:rmx-lt/rmx-server-infra.git`.
- Commit identity (repo-local): `jRmx0 <116594512+jRmx0@users.noreply.github.com>`.
- Always work as `rmx` (root has no access to the key):

  ```bash
  sudo -u rmx -i            # from the dashboard terminal
  cd /opt/rmx-vps && git pull --ff-only
  # edit, then:
  git add -A && git commit -m "…" && git push
  ```

- ⚠️ The repo is **public**: everything pushed from the server is published at once. Check `git diff --cached` before committing. Never commit secrets, home IPs or personal emails.
- To revoke: delete the key in GitHub → repo **Settings → Deploy keys**, then `rm ~/.ssh/github-rmx-vps*` on the server.

---

## 10. Docker & services

### Docker

- Docker Engine **29.9.1** + Compose plugin **v5.6.0**, from Docker's official apt repo (not Ubuntu's `docker.io` package).
  - Repo: `/etc/apt/sources.list.d/docker.sources` (copy in [`config/docker/`](https://github.com/rmx-lt/rmx-server-infra/tree/development/config/docker)), key `/etc/apt/keyrings/docker.asc`, fingerprint `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88` (matches Docker's docs).
  - Updates arrive with the normal `sudo apt update && sudo apt upgrade`.
- `/etc/docker/daemon.json`: container logs rotate at 10 MB × 3 files, so they can't fill the disk.
- `docker` and `containerd` start at boot. Containers with `restart: unless-stopped` normally come back after a reboot. Because Docker can miss one (seen once with Mosquitto, which exited by itself during shutdown and so counted as stopped by hand), `rmx-stack.service` also runs `docker compose up -d --no-recreate` in `services/` at every boot. It never starts the probe.
- Containers have Compose's default names, `rmx-<service>-1` (`rmx-caddy-1`, `rmx-mosquitto-1`, `rmx-probe-app-1`, `rmx-probe-db-1`). Scripts and commands use the service name through Compose (`cd /opt/rmx-vps/services && docker compose exec caddy …`), not the container name. Always run `docker compose` from `services/`: from a service folder it would start a second project.
- `rmx` is in the `docker` group, so `docker …` works without `sudo`. (That group is effectively root, but `rmx` already has passwordless sudo.)

### ⚠️ Docker bypasses ufw — port policy

Docker writes its own iptables rules for published ports. That traffic goes through the `FORWARD` chain, and ufw's rules (on `INPUT`) never see it. **A published port is open to the whole internet, whatever ufw says.**

Tested on 2026-10-15 with a throwaway `nginx` container while ufw allowed only 22:

| Published as | ufw rule for 8080? | From the internet |
|---|---|---|
| `-p 8080:80` | none | **HTTP 200: reachable** |
| `-p 127.0.0.1:8080:80` | none | timeout: not reachable (only from the server itself) |

**Rules for this server:**

1. **Databases publish no ports.** They sit on the `backend` network, and only the app can reach them.
2. **Private tools** (admin UIs, dashboards, debug ports) bind to localhost: `"127.0.0.1:PORT:PORT"`. Reach them through an SSH tunnel from the PC: `ssh -L PORT:127.0.0.1:PORT rmx-vps`, then open `http://localhost:PORT`.
3. **Public ports are deliberate:** listed in the table below, documented in the CHANGELOG, and each gets a matching ufw rule, so `ufw status` stays an honest list of what's open.

Check what is really listening: `sudo ss -tlnp` and `docker ps --format '{{.Names}} {{.Ports}}'`.

### Layout

```
services/
├── compose.yaml          # project "rmx": includes each service, defines the networks
├── caddy/
│   ├── compose.yaml      # Caddy container
│   ├── Caddyfile         # sites, TLS, redirects
│   ├── site/index.html   # placeholder page for rmx.lt
│   ├── fw-users.caddy.example  # template for private/fw-users.caddy (download logins for /fw/*)
│   ├── firmware/         # (server only, gitignored) OTA images, served at /fw/
│   ├── private/          # (server only, gitignored) fw-users.caddy
│   └── data/             # (server only, gitignored) certificates + Caddy state
├── mosquitto/
│   ├── compose.yaml      # Mosquitto container
│   ├── config/
│   │   ├── mosquitto.conf  # listeners, TLS, logins, persistence
│   │   └── acl             # access rules (source; Mosquitto reads an installed copy)
│   ├── cert-sync/        # host script + systemd timer: Caddy's cert -> Mosquitto
│   ├── tests/mqtt-tests.ps1  # test suite, run from the Windows PC
│   └── data/             # (server only, gitignored) logins, cert copy, persistence
└── probe/                # rmx-server-app-probe, Compose profile "probe" (off unless started)
    ├── compose.yaml      # probe-db (TimescaleDB) + probe-app (GHCR image)
    ├── .env.example      # template for .env (server only: passwords + PROBE_TAG, the deployed image)
    ├── deploy/           # deploy script, sudoers rule, authorized_keys template
    └── data/             # (server only, gitignored) database files, credentials.txt
```

- Per-service secrets go in `services/<name>/.env` (gitignored). Commit a `.env.example` with placeholder values next to it.
- Runtime data goes in `services/<name>/data/` (gitignored, owned by root). It lives only on the server, and nothing backs it up.

**Networks** (defined in `services/compose.yaml`):

| Network | Docker name | Members | Notes |
|---|---|---|---|
| `edge` | `rmx_edge` | Caddy, Mosquitto, probe-app (later app) | Normal bridge with internet access |
| `backend` | `rmx_backend` | probe-app, probe-db (later app, database) | `internal: true`: no internet access. Created when the first service uses it |

### Public ports

| Port | Service | ufw | Purpose |
|---|---|---|---|
| 22/tcp | sshd (host) | ✅ | SSH |
| 80/tcp | Caddy | ✅ | Let's Encrypt HTTP-01 challenge, redirect to HTTPS |
| 443/tcp | Caddy | ✅ | HTTPS (HTTP/1.1 + HTTP/2). HTTP/3 is turned off, so 443/udp stays closed |
| 8883/tcp | Mosquitto | ✅ | MQTT over TLS (`mqtt.rmx.lt`), login required |

Not public (reachable only by containers on `rmx_edge`): Mosquitto's plain MQTT **1883** (`mosquitto:1883`, the app); probe-app's **8080** (only via Caddy at `https://api.rmx.lt/probe/`). probe-db's 5432 is on `rmx_backend` only.

### Caddy

- Image `caddy:2.11` (2.11.7 when installed); container `rmx-caddy-1`.
- Sites:
  - `https://rmx.lt`: static placeholder page from `site/`
  - `https://api.rmx.lt`: placeholder JSON `{"service":"rmx-api","status":"placeholder"}`, except `/probe` and `/probe/*` → probe-app:8080 (prefix kept). The app does its own login (see [Probe](#probe-rmx-server-app-probe)); Caddy adds no auth. When the probe is off, `/probe/*` answers 502
  - `https://api.rmx.lt/fw/*`: OTA firmware images, static files with HTTP basic auth (see [Firmware images](#firmware-images-ota))
  - `https://www.rmx.lt/…` → **301** to `https://rmx.lt/…`
  - `https://mqtt.rmx.lt`: a one-line text. The block exists so that Caddy obtains and renews the certificate Mosquitto uses (see [Mosquitto](#mosquitto-mqtt)). No MQTT goes through Caddy
  - every `http://…` → **308** to `https://…`
- Certificates: Let's Encrypt (issuers `YE1`/`YE2`), one per name, obtained automatically on first start (2026-10-15, valid until 2027-01-13). Caddy renews them about 30 days before they expire. No ACME email is set (Let's Encrypt no longer sends expiry emails, and an email would end up in this public repo).
- State: `services/caddy/data/data` → `/data` (certs, ACME account key) and `services/caddy/data/config` → `/config`. If these are deleted, Caddy just requests new certificates. Let's Encrypt allows 5 duplicate certificates per week, so don't delete them in a loop.

### Firmware images (OTA)

The LTE modem board ([rmx-mower-gateway-probe](https://github.com/rmx-lt/rmx-mower-gateway-probe), wiki [Mower-Gateway-Probe → Firmware updates](Mower-Gateway-Probe#firmware-updates-ota)) downloads new firmware from `https://api.rmx.lt/fw/probe/<version>.bin`.

- Files: `services/caddy/firmware/` on the host → `/srv/fw` in Caddy, read-only. `firmware/probe/<version>.bin` is served as `/fw/probe/<version>.bin`. Range requests work (the device resumes dropped downloads); directories give 404, not a listing.
- Login: HTTP basic auth, one login per device, in `services/caddy/private/fw-users.caddy` (server only, gitignored; template [`fw-users.caddy.example`](https://github.com/rmx-lt/rmx-server-infra/blob/development/services/caddy/fw-users.caddy.example)). Plain-text copies go in `caddy/private/credentials.txt` (root, `0600`). **The file must exist or Caddy won't start**; an empty file locks `/fw/` (401 for everyone). Tested with Caddy 2.11.2 (2026-10-22, locally): no login 401, wrong password 401, right one 200, `Range` 206, directory 404, missing users file = config error, empty file = 401.
- Trust: the images are signed with a key that exists only on the PC, and the device refuses an image with any other signature. The login only keeps casual downloads away, so a hacked server can't push its own firmware.
- Upload: `tools\release.ps1` in rmx-mower-gateway-probe (scp as rmx into `firmware/probe/`).

One-time setup (on the server; create the users file **before** restarting Caddy):

```bash
cd /opt/rmx-vps/services/caddy
mkdir -p firmware/probe private
P=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-32)
H=$(cd .. && docker compose exec -T caddy caddy hash-password --plaintext "$P")   # compose from services/, not from caddy/
echo "probe-device $H" > private/fw-users.caddy
echo "probe-device $P" | sudo tee private/credentials.txt >/dev/null; sudo chmod 600 private/credentials.txt; unset P H
cd .. && docker compose up -d caddy        # new mounts: recreate the container
curl -s -o /dev/null -w "%{http_code}\n" https://api.rmx.lt/fw/probe/x.bin   # 401
```

Then copy the password into the device's `sdkconfig` (`CONFIG_PROBE_OTA_PASSWORD`) without printing it, the same way as the MQTT password. New device: add a line to `fw-users.caddy`, `docker compose restart caddy`.

### Mosquitto (MQTT)

- Image `eclipse-mosquitto:2.1-alpine` (2.1.2 when installed; there is no plain `2.1` tag); container `rmx-mosquitto-1`; `mem_limit: 64m` (it uses ~3.5 MB).
- Listeners ([`config/mosquitto.conf`](https://github.com/rmx-lt/rmx-server-infra/blob/development/services/mosquitto/config/mosquitto.conf)):
  - **8883**: MQTT over TLS, TLS 1.2 minimum (1.3 preferred), certificate for `mqtt.rmx.lt`. Published.
  - **1883**: plain MQTT for containers on `rmx_edge` (the app). Not published.
  - All: `allow_anonymous false`, logins from `data/auth/passwd`, rules from `data/auth/acl`.
- On 8883, `use_username_as_clientid true`: the client ID is always the username. A second login as `mower-01` replaces the first (the broker logs "session taken over"), so one device can't kick another off by copying its client ID.
- **No MQTT for browsers** (the production design, since 2026-10-20): browsers talk only to the app (HTTPS and its WebSocket, with a session); only devices (8883) and the app (1883) talk to the broker. The WebSocket listener 9001, Caddy's `wss://mqtt.rmx.lt/mqtt` route and the `probe-web` login were removed. That also closed the client-ID takeover over WebSockets (`use_username_as_clientid` was off on 9001) and means Mosquitto sees every device's real IP.
- Persistence on (`data/store/mosquitto.db`, saved every 5 min and on shutdown): retained messages and persistent sessions survive restarts.
- Logs go to stdout: `docker compose logs -f mosquitto`. They contain client IP addresses, so don't paste them into this repo.

**Logins and topics**

| Login | Can use | Purpose |
|---|---|---|
| `app` | `mower/#` (read + write) | The backend app (Phase 5) |
| `mower-01` | `mower/mower-01/#` only | First mower |
| `probe-app` | `probe/#` (read + write) | rmx-server-app-probe server |
| `probe-device` | write `probe/req/probe-device`; read `probe/res/probe-device`, `probe/events/#`, `probe/status/#` | The ESP32 LTE probe device ([rmx-mower-gateway-probe](https://github.com/rmx-lt/rmx-mower-gateway-probe)), password in its gitignored `sdkconfig` |

The rules in [`config/acl`](https://github.com/rmx-lt/rmx-server-infra/blob/development/services/mosquitto/config/acl): `probe-app` and `probe-device` have explicit `user` entries; every login also gets `mower/<its username>/#` (`pattern readwrite mower/%u/#`). A new mower needs a login only, no ACL change. Planned topics: `mower/<id>/telemetry`, `mower/<id>/status` (retained, also the last-will), `mower/<id>/cmd`, `mower/<id>/cmd/ack`.

How Mosquitto enforces it: a mower may **subscribe** to another mower's topic (the SUBSCRIBE is accepted), but no message from there is ever delivered to it. A **publish** to another mower's topic is dropped; with MQTT 5 and QoS 1 the client is told `Not authorized`.

Server-only files in `services/mosquitto/data/` (gitignored, no backup):

| Path | Owner / mode | Contents |
|---|---|---|
| `auth/passwd` | 1883, `0600` | Logins (salted password hashes) |
| `auth/acl` | 1883, `0600` | Installed copy of `config/acl` |
| `certs/fullchain.pem`, `certs/privkey.pem` | 1883, `0644` / `0600` | Copy of Caddy's certificate (see below) |
| `store/` | 1883, `0700` | Persistence |
| `credentials.txt` | root, `0600` | The **plain-text passwords**, one `user password` per line |

Read the passwords (on the server): `sudo cat /opt/rmx-vps/services/mosquitto/data/credentials.txt`

**Add a mower** (example `mower-02`, on the server):

```bash
cd /opt/rmx-vps/services
P=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)
docker compose exec -u mosquitto mosquitto mosquitto_passwd -b /mosquitto/auth/passwd mower-02 "$P"
echo "mower-02 $P" | sudo tee -a mosquitto/data/credentials.txt >/dev/null; unset P
docker compose kill -s HUP mosquitto      # reload logins, no disconnects
```

The mower then connects to `mqtt.rmx.lt:8883` with TLS, username `mower-02` and that password, and uses `mower/mower-02/…`.

- New password for a login: the same commands (it replaces the old one); delete the old line in `credentials.txt`.
- Remove a login: `docker compose exec -u mosquitto mosquitto mosquitto_passwd -D /mosquitto/auth/passwd mower-02`, then the HUP, then delete its line in `credentials.txt`. A client that is already connected stays connected until it reconnects (or `docker compose restart mosquitto`).
- Changed `config/acl` (after `git pull`): `sudo install -o 1883 -g 1883 -m 0600 mosquitto/config/acl mosquitto/data/auth/acl && docker compose kill -s HUP mosquitto`. Mosquitto reads a copy because it warns about ACL files that are world-readable or not owned by its user, and future versions will refuse them.
- Changed `config/mosquitto.conf`: `docker compose restart mosquitto` (after `git pull` the file bind mount keeps the old inode, like the Caddyfile).

**How the certificate gets to Mosquitto (and survives renewals)**

1. Caddy has an `mqtt.rmx.lt` site block, so it obtains the Let's Encrypt certificate and renews it automatically, about 30 days before it expires (so roughly every 60 days). It stores it root-only in `caddy/data/data/caddy/certificates/…/mqtt.rmx.lt/`.
2. Mosquitto runs as uid 1883 and can't read that folder. The host script `/usr/local/sbin/rmx-mqtt-cert-sync` (source: [`cert-sync/`](https://github.com/rmx-lt/rmx-server-infra/tree/development/services/mosquitto/cert-sync)) checks that the cert and key belong together and compares them with Mosquitto's copy. Only if they changed does it copy them to `mosquitto/data/certs/` (owner 1883, key `0600`, written atomically) and send **SIGHUP** to Mosquitto. On SIGHUP Mosquitto reloads the certificate without dropping connected clients (tested on 2026-10-15 by swapping in a self-signed cert and back).
3. `rmx-mqtt-cert-sync.timer` runs the script twice a day (03:30 and 15:30 UTC, up to 30 min later), and 5 minutes after boot. It catches up after downtime.

Why this way: no second ACME client (certbot) competing with Caddy for port 80, and Caddy's data stays root-only. Mosquitto gets a copy of only the one key it needs.

```bash
systemctl list-timers rmx-mqtt-cert-sync.timer    # next run
sudo systemctl start rmx-mqtt-cert-sync.service    # run it now
sudo journalctl -u rmx-mqtt-cert-sync.service      # what it did
```

If the script in the repo changes, reinstall it (the units likewise go to `/etc/systemd/system/`, followed by `sudo systemctl daemon-reload`):
`sudo install -m 0755 /opt/rmx-vps/services/mosquitto/cert-sync/rmx-mqtt-cert-sync.sh /usr/local/sbin/rmx-mqtt-cert-sync`

**Test from the Windows PC**

The [Mosquitto clients for Windows](https://mosquitto.org/download/) (`mosquitto_pub`, `mosquitto_sub`) are installed in `C:\Program Files\mosquitto`. Two Windows quirks:

- `--tls-use-os-certs` doesn't work on Windows (it fails with "protocol error"). Export Windows' trusted root CAs to a PEM file and pass it with `--cafile` (the test script does this).
- `mosquitto_sub -W` (timeout) doesn't stop the program on Windows. Use Ctrl+C.

The test suite checks the TLS chain, that TLS 1.1 is refused, that the own topics work, that the other mower's topics are blocked, that anonymous and wrong-password logins are refused, the client ID takeover, and that 1883 is closed. Run it from the repo folder:

```powershell
powershell -ExecutionPolicy Bypass -File services\mosquitto\tests\mqtt-tests.ps1
```

All 12 tests passed on 2026-10-15, and again on 2026-10-18 after the WebSocket listener was added (in both Windows PowerShell 5.1 and PowerShell 7).

### Everyday commands (on the server)

```bash
cd /opt/rmx-vps/services
docker compose ps                         # what is running
docker compose logs -f caddy              # follow Caddy logs (Ctrl+C to stop)
docker compose logs -f mosquitto          # follow Mosquitto logs (connections, errors)
docker compose kill -s HUP mosquitto      # reload Mosquitto logins/ACL/cert, no disconnects
docker compose up -d                      # start / apply compose changes
docker compose restart caddy              # apply Caddyfile / site changes
docker compose pull && docker compose up -d   # update images (not the probe, see Probe)
```

> ⚠️ `docker compose --profile probe stop` / `down` with no service names stops **everything** (Caddy and Mosquitto too). To stop only the probe, name its services (below).

Deploy a change made on the PC: commit + push, then `ssh rmx-vps 'git -C /opt/rmx-vps pull --ff-only'`, then run the matching command above. A changed `compose.yaml` needs `up -d`. A changed `Caddyfile` needs `restart caddy`: git replaces the file, and the container keeps seeing the old one until it restarts.

Check the certificates from the PC: `curl.exe -vI https://rmx.lt` (Windows curl verifies the chain and fails loudly if it's bad).

### Probe (rmx-server-app-probe)

[rmx-server-app-probe](https://github.com/rmx-lt/rmx-server-app-probe) is a learning/diagnostic app and a full rehearsal of the production workflow: a Go server plus a React page with a live table, CRUD over HTTPS REST, WSS and MQTT over WSS, logged to TimescaleDB. Its [Deployment](Server-App-Probe#deployment) section is the contract this setup follows. The deploy setup below will be copied for the production app.

**Containers** ([`services/probe/compose.yaml`](https://github.com/rmx-lt/rmx-server-infra/blob/development/services/probe/compose.yaml)), Compose profile `probe`, so a plain `docker compose up -d` leaves them alone:

| Container | Image | Networks | Memory | Notes |
|---|---|---|---|---|
| `probe-db` | `timescale/timescaledb:2.30.2-pg17` | `rmx_backend` | `mem_limit 256m` (~60 MB used) | No ports. Tuned small: `shared_buffers=32MB`, `work_mem=2MB`, `max_connections=20`, no parallel workers, `timescaledb.max_background_workers=3`, `timescaledb.telemetry_level=off`. Data in `probe/data/db/` |
| `probe-app` | `ghcr.io/rmx-lt/rmx-backend-probe:${PROBE_TAG}` | `rmx_edge` + `rmx_backend` | `mem_limit 64m` (~8 MB used) | No ports; Caddy proxies to `probe-app:8080`. Health check every 5 s (`/probe/health`). A static Go binary (26 MB) on `distroless/static`, `GOMEMLIMIT=40MiB` inside the 64 MB limit. Log level from `LOG_LEVEL` (`RUST_LOG` in the compose file is a leftover and ignored). Its MQTT client speaks MQTT 5; migrations run with goose, which adopts an existing database on first start (the old `_sqlx_migrations` table stays unused). The image keeps the name `rmx-backend-probe` although the repo is `rmx-server-app-probe` |

The whole probe uses about 50–70 MB of RAM while running (measured 2026-10-18: ~50 MB more "available" after stopping it).

> **The probe is OFF by default** (decided 2026-10-18). Turn it on when you want to use it, and off again afterwards. Auto-deploys keep working while it's off: they only record the new tag in `probe/.env` and pull the image, so the next `up -d` starts the latest version. Containers that are stopped stay stopped after a reboot (`restart: unless-stopped`).

**Where the values come from** (all server only, gitignored). Compose reads `probe/.env` automatically for the included `probe/compose.yaml`, because it sits next to it. It's optional: if it's missing, only the probe fails, and the rest of the stack keeps working. That's also why the compose files use no `${VAR:?}` checks: Compose checks those even for services whose profile is off.

| File | Owner / mode | Contents |
|---|---|---|
| `probe/.env` | rmx, `0600` | `PROBE_DB_PASSWORD`, `PROBE_MQTT_PASSWORD`, and `PROBE_TAG=sha-…`, the deployed image (template: [`.env.example`](https://github.com/rmx-lt/rmx-server-infra/blob/development/services/probe/.env.example)). **Only the deploy script changes `PROBE_TAG`**: a deploy is just "rewrite that line + recreate probe-app". rmx owns the file because `docker compose` (run as rmx) must read it |
| `probe/data/credentials.txt` | root, `0600` | Plain-text copies: the app login (user `probe`), DB password |
| `mosquitto/data/credentials.txt` | root, `0600` | Also holds `probe-app` and `probe-device` |

The app login itself lives in the probe database (`users` table, Argon2id hash); `credentials.txt` only keeps the plain-text copy for you.

**Routes**

| URL | Goes to | Login |
|---|---|---|
| `https://api.rmx.lt/probe/` | probe-app: the page with its login form (public), `/probe/api/…`, `/probe/ws` | The app's own login, user `probe` (session cookie) |
| `https://api.rmx.lt/probe/health` | probe-app health JSON (200 / 503) | None (only up/down and the version) |
| `mqtts://mqtt.rmx.lt:8883` | Mosquitto (devices only, e.g. `probe-device`) | MQTT login per device |

**Login** (since 2026-10-19; before that, Caddy basic auth): the app has its own login page and server-side sessions. After login the browser holds an `HttpOnly`, `Secure`, `SameSite=Strict` cookie (`__Secure-probe_session`, `Path=/probe`); the app checks it on every API request and on the WebSocket handshake, which also fixed WSS on iPhones (WebKit sends cookies on WebSocket handshakes, but not basic-auth credentials). Requests that change something and WebSocket handshakes must come from `https://api.rmx.lt` (`ALLOWED_ORIGINS` in `probe/compose.yaml`), and failed logins slow down (per username and IP). Why each choice: [Server-App-Probe → Login and sessions](Server-App-Probe#login-and-sessions).

**Users** (no sign-up page; run on the server, in `/opt/rmx-vps/services`, with the probe on). The password is piped in from stdin, so it never appears on a command line:

```bash
PW=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24)
printf '%s\n' "$PW" | docker compose exec -T probe-app /app/probe-server create-user probe    # or set-password probe (logs out everywhere)
# then replace the "app login" line in probe/data/credentials.txt (sudo) with the new password
docker compose exec -T probe-app /app/probe-server delete-user probe                           # remove a login
```

**Passwords** (read them on the server; never paste them into the repo or a chat):

```bash
sudo cat /opt/rmx-vps/services/probe/data/credentials.txt          # app login (user probe), DB password
sudo awk '$1=="probe-device"{print $2}' /opt/rmx-vps/services/mosquitto/data/credentials.txt   # MQTT login of the modem probe
```

**Turn on / off** (on the server, in `/opt/rmx-vps/services`; leave it off when you're done):

```bash
docker compose --profile probe up -d           # start (or apply compose changes)
docker compose stop probe-app probe-db         # stop only the probe (frees ~50-70 MB)
docker compose ps -a probe-app probe-db        # state
docker compose logs -f probe-app               # logs
```

⚠️ Don't use `docker compose --profile probe stop` or `down` without service names: that stops Caddy and Mosquitto too.

#### Auto-deploy (CD)

Every push to `production` in rmx-server-app-probe deploys (pushes to `development` only build and test). After the image is pushed to GHCR, the `deploy` job sends **only the tag** over SSH:

```
GitHub Actions --ssh deploy@45.81.252.43 "sha-1234abc"--> forced command
  sudo -n /usr/local/sbin/rmx-deploy-probe "sha-1234abc"   (root, via sudoers)
```

- **User `deploy`** (uid 1001): no password (locked), not in `sudo` or `docker`. Its shell is `/bin/bash` only because sshd runs forced commands through the login shell; it never gets an interactive shell.
- **`/home/deploy/.ssh/authorized_keys`**: one key with `restrict,command="sudo -n /usr/local/sbin/rmx-deploy-probe \"$SSH_ORIGINAL_COMMAND\""` (template: [`deploy/authorized_keys.example`](https://github.com/rmx-lt/rmx-server-infra/blob/development/services/probe/deploy/authorized_keys.example)). `restrict` blocks the terminal and all forwarding; `command` replaces whatever the client asks to run. Tested: `id`, `sha-…; id`, no command and `-L` port forwarding are all refused.
- **`/etc/sudoers.d/deploy`** ([source](https://github.com/rmx-lt/rmx-server-infra/blob/development/services/probe/deploy/sudoers-deploy)): `deploy` may run that one script as root, and only with an argument matching `^sha-[0-9a-f]{7}$`. Anything else is refused by sudo before the script runs ("a password is required").
- **`/usr/local/sbin/rmx-deploy-probe`** ([source](https://github.com/rmx-lt/rmx-server-infra/blob/development/services/probe/deploy/rmx-deploy-probe.sh)): checks the tag again, takes a lock (one deploy at a time), pulls the image (a failed pull changes nothing), rewrites the `PROBE_TAG` line in `probe/.env` (atomically, keeping owner and mode), recreates `probe-app` and waits up to 90 s for `healthy`. If it isn't healthy, it writes the previous tag back, recreates again and exits 1, so the GitHub job fails. Old probe images are pruned after a good deploy. If the probe is **off**, it only records and pulls the tag; a deploy never turns the probe on. Tested: good deploy, unknown tag, and a rollback (DB stopped on purpose).
- **Log**: `/var/log/rmx-deploy-probe.log` (root:adm) and the journal: `sudo journalctl -t rmx-deploy-probe`.
- **Deploy by hand** (as rmx): `sudo rmx-deploy-probe sha-1234abc`. Roll back the same way, with an older tag.
- **GitHub side** (rmx-server-app-probe → Settings → Secrets and variables → Actions): `DEPLOY_HOST` (`45.81.252.43`), `DEPLOY_SSH_KEY` (private key, exists only there), `DEPLOY_KNOWN_HOSTS` (this server's ed25519 host-key line, pinned: fingerprint in the table at the top). The job retries up to 3 times on SSH connection errors only (exit 255): new SSH connections to this VPS are sometimes dropped before they reach sshd.

**Rotate the deploy key** (from the Windows PC, in Git Bash, because PowerShell can't pass an empty passphrase to ssh-keygen):

```bash
ssh-keygen -t ed25519 -N "" -C rmx-backend-probe-deploy -f ./deploy_key
gh secret set DEPLOY_SSH_KEY -R rmx-lt/rmx-server-app-probe < ./deploy_key
```

Then on the server, replace the key part of the one line in `/home/deploy/.ssh/authorized_keys` (keep the `restrict,command=…` prefix) with the content of `deploy_key.pub`, and delete both local files. The old key stops working as soon as the line is replaced.

**If the server's host key ever changes:** `DEPLOY_KNOWN_HOSTS` must be updated (`echo "45.81.252.43 $(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"`), or every deploy fails with a host-key error. That is on purpose.

#### Remove

- Stop and delete the containers: `docker compose rm -sf probe-app probe-db`; the data: `sudo rm -rf probe/data` (no backup, by choice).
- Deploy access: `sudo rm /etc/sudoers.d/deploy /usr/local/sbin/rmx-deploy-probe && sudo userdel -r deploy`; delete the three `DEPLOY_*` secrets on GitHub (and disable the `deploy` job).
- MQTT: `mosquitto_passwd -D` for `probe-app` and `probe-device` (see above), remove their lines from `credentials.txt` and the probe block from `config/acl`.
- Caddy: remove the `@probe` handle.
- Remove the `probe/compose.yaml` include from `services/compose.yaml`.

### Undo

| Undo | How |
|---|---|
| Stop all services (keep everything) | `cd /opt/rmx-vps/services && docker compose down` |
| Stop only Mosquitto | `docker compose stop mosquitto` |
| Close 8883 | `sudo ufw delete allow 8883/tcp`. Also stop Mosquitto, because Docker keeps the port open without ufw |
| Remove Mosquitto completely | `docker compose rm -sf mosquitto`; `sudo systemctl disable --now rmx-mqtt-cert-sync.timer`; `sudo rm /etc/systemd/system/rmx-mqtt-cert-sync.* /usr/local/sbin/rmx-mqtt-cert-sync && sudo systemctl daemon-reload`; `sudo rm -rf /opt/rmx-vps/services/mosquitto/data` (logins and retained messages are lost); remove the `mqtt.rmx.lt` block from the Caddyfile and the `include` line from `services/compose.yaml` |
| Close 80/443 | `sudo ufw delete allow 80/tcp && sudo ufw delete allow 443/tcp`. Also stop Caddy, because Docker keeps the ports open without ufw |
| Remove the probe completely | See [Probe → Remove](#remove) |
| Delete Caddy's certificates and state | `sudo rm -rf /opt/rmx-vps/services/caddy/data` (after `down`) |
| Remove Docker completely | `docker compose down`, then `sudo apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras`, `sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc`, `sudo gpasswd -d rmx docker` |

---

## 11. Setup as code (Ansible)

[`ansible/`](https://github.com/rmx-lt/rmx-server-infra/tree/development/ansible) describes everything in §3–§10 as code: users, sshd, ufw, fail2ban, swap, unattended security updates, Docker, the Compose stack and its server-only files, cert-sync and the deploy script. Its secrets (SSH host keys, Mosquitto and probe passwords, `/fw/` logins, deploy key) are in `ansible/group_vars/all/vault.yml`, encrypted with Ansible Vault.

```bash
# empty Ubuntu 24.04 VPS, as root (provider dashboard terminal):
curl -fsSL https://raw.githubusercontent.com/rmx-lt/rmx-server-infra/production/ansible/bootstrap.sh | bash
# later, on the server: preview, then apply
cd /opt/rmx-vps/ansible && ./bootstrap.sh --check --diff && ./bootstrap.sh
```

Branches are `feature/*` → `development` → `production`; a push to `production` backs up (encrypted), checks and applies the playbook automatically, and CI builds the server from empty in a container on every PR. Details, one-time setup and restore: [Server-Infra-Ansible](Server-Infra-Ansible#cicd-github-actions). Full runbook and limits: [Server-Infra-Ansible](Server-Infra-Ansible). Once the live server has been rebuilt this way, change the server only through this repo; `config/` then documents what Ansible writes (it is no longer pulled from the server, §9).
