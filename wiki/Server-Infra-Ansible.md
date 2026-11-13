# RMX-SERVER as code (Ansible)

An empty Ubuntu 24.04 VPS becomes RMX-SERVER with one command. The playbook describes the **end state**, so it is safe to run again: it changes only what differs, and `--check --diff` shows what it would change without touching anything.

| Role | What it sets up |
|---|---|
| `base` | `apt` upgrade, unattended security updates (reboot at 04:30 when needed), 2 GB swapfile, kernel settings |
| `users` | admin user `rmx` (key only, sudo), `deploy` user for GitHub Actions (forced command) |
| `ssh` | sshd: keys only, no root except from the provider dashboard, host keys from the vault |
| `firewall` | ufw: only the ports in `group_vars/all/vars.yml` (`public_ports`); fail2ban |
| `docker` | Docker Engine + Compose from Docker's apt repo (key fingerprint checked) |
| `stack` | the clone in `/opt/rmx-vps`, the secrets of Caddy / Mosquitto / probe, cert-sync timer, deploy script, `docker compose up`, then a smoke test |

Everything [Server-Infra](Server-Infra) §3–§10 did by hand is in these roles. Settings that aren't secret are in [`group_vars/all/vars.yml`](https://github.com/rmx-lt/rmx-server-infra/blob/development/ansible/group_vars/all/vars.yml); secrets are in `group_vars/all/vault.yml`, encrypted.

## The vault

`vault.yml` holds every secret a rebuild needs: SSH host keys, Mosquitto passwords, the probe's database and app passwords, the deploy key. It is committed **encrypted** (AES-256, Ansible Vault); the repo is public, so use a long random vault password and keep it in your password manager. Lose it and the vault can't be opened.

```bash
# keep the passwords of the CURRENT server (once, on the old server, before reinstalling)
cd /opt/rmx-vps/ansible && sudo ./export-vault.sh     # writes group_vars/all/vault.yml, prints nothing secret
ansible-vault encrypt group_vars/all/vault.yml        # asks for the new vault password
git add group_vars/all/vault.yml && git commit -m "Vault" && git push

ansible-vault edit group_vars/all/vault.yml           # change a value later
```

Template with every field: [`group_vars/all/vault.yml.example`](https://github.com/rmx-lt/rmx-server-infra/blob/development/ansible/group_vars/all/vault.yml.example). Do not commit an unencrypted `vault.yml`: CI fails the pull request if the file doesn't start with `$ANSIBLE_VAULT`.

## Build a server from empty

1. Provider dashboard → reinstall Ubuntu 24.04 (this erases everything).
2. Open the dashboard terminal (root) and run:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/rmx-lt/rmx-server-infra/production/ansible/bootstrap.sh | bash
   ```

   It installs git and Ansible, clones this repo to `/opt/rmx-vps`, asks for the vault password and runs the playbook on the server itself. About 10 minutes.
   If it stops with "Could not get lock /var/lib/dpkg/lock-frontend", the fresh image is still running its first-boot update. Wait until `pgrep -x apt-get` prints nothing, then run the line again. The package step prints nothing for a few minutes: don't interrupt it.
3. Check: the smoke test at the end of the run answers for the sites and MQTT's TLS port (passing tasks are not printed; look for `failed=0`). Then `ssh rmx-vps` from the PC (the host key is the same as before, so no warning). Until the playbook has run, the fresh image has its own host key: don't `ssh-keygen -R`, just wait.
4. Start the probe: `bash /opt/rmx-vps/ansible/bootstrap.sh -e probe=on`.
5. Get the data back (probe database, Mosquitto store, firmware images, probe tag). On the PC, download the newest `rmx-backup-<sha>` artifact of the `deploy` workflow (`gh run download <run-id> -R rmx-lt/rmx-server-infra`), decrypt it with `age -d -i age.key -o backup.tar.gz <file>` (in PowerShell never `>`: it corrupts binary files), then:

   ```bash
   scp backup.tar.gz rmx-vps:/tmp/
   ssh rmx-vps "sudo rmx-ci restore /tmp/backup.tar.gz; rm -f /tmp/backup.tar.gz"
   ```

   Delete the local copies afterwards. This whole rebuild has been rehearsed end to end once.

DNS must already point at the server's IP: Caddy gets its certificates from Let's Encrypt during the run. Without DNS the run continues, Mosquitto waits for its certificate, and the cert-sync timer retries twice a day.

## Day to day

Change the repo, push, then on the server:

```bash
cd /opt/rmx-vps/ansible
./bootstrap.sh --check --diff        # what would change (nothing is applied)
./bootstrap.sh                       # apply
./bootstrap.sh --tags ssh            # only one role: base users ssh firewall docker stack
./bootstrap.sh -e probe=on           # also start the probe and create its app logins
./bootstrap.sh -e reset_mqtt_passwords=true   # after editing Mosquitto passwords in the vault
```

Run it from the PC instead (WSL, or any Linux with Ansible): `ansible-playbook site.yml --ask-vault-pass -e target=remote`.

Run `--check --diff` now and then. A difference means somebody changed the server by hand: either put it in the repo or let the next run undo it.

## CI/CD (GitHub Actions)

Branches: `feat/*` → PR → `development` → PR → `production`. Both stable branches are protected (PR only, the CI checks must pass); the server follows `production`.

Feature branches are named `feat/<issue#>-slug`, and are deleted when their PR is merged (the repo deletes them automatically).

| When | What runs ([`ansible.yml`](https://github.com/rmx-lt/rmx-server-infra/blob/development/.github/workflows/ansible.yml), [`deploy.yml`](https://github.com/rmx-lt/rmx-server-infra/blob/development/.github/workflows/deploy.yml)) |
|---|---|
| every PR and push | syntax, ansible-lint, vault encrypted · `test/container-test.sh` builds the server from empty in a container, a second run must change nothing, `--check` must see a manual change · `test/db-roundtrip.sh` backs up and restores a throwaway TimescaleDB and a Mosquitto store |
| push to `production` | encrypted backup → `ansible --check --diff` → `ansible apply` (with its own smoke test) → smoke test from outside |

**Backup before every deploy.** The runner asks the server for a tar.gz (`/etc`, `/opt/rmx-vps` with its secrets and Mosquitto's `store/`, and a `pg_dump` of the probe database when it runs), encrypts it with `age` and uploads it as an artifact kept for 7 days. The server never sees the private key. Download one from the run's page, then on the PC: `age -d -i key.txt rmx-backup-xxxxxxx.tar.gz.age > backup.tar.gz`. Changes between the last deploy and a wipe are not in it.

**Restore data** after a rebuild (the playbook rebuilds config; this puts the data back): copy `backup.tar.gz` to the server, start the probe (`./bootstrap.sh -e probe=on`), then `sudo rmx-ci restore backup.tar.gz`. It recreates the database from the dump with TimescaleDB's restore procedure and puts Mosquitto's store back. Mosquitto saves its store every 5 minutes, so retained messages can be that old.

**One-time setup (the maintainer):**

1. Create branches `development` and `production` from the initial commit; protect them (Settings → Branches: require a PR and the `check`, `db-roundtrip` and `container` checks). Add a `production` environment (Settings → Environments) limited to the `production` branch.
2. `ssh-keygen -t ed25519 -N "" -C rmx-vps-ci -f ci_key`. Put the **public** half in the vault as `vault_ci_ssh_key`, the **private** half in the environment secret `CI_SSH_KEY`, then delete both files.
3. `age-keygen -o age.key` on the PC: the public key (`age1…`) is the secret `AGE_PUBLIC_KEY`; keep `age.key` in the password manager.
4. `VAULT_PASSWORD` = the Ansible Vault password; `CI_KNOWN_HOSTS` = `45.81.252.43 ` + the first two fields of `/etc/ssh/ssh_host_ed25519_key.pub`.
5. Apply once by hand (`./bootstrap.sh`) so the `ci` user and `rmx-ci` exist. The server's clone does not have to be switched by hand: the first deploy runs `git checkout -B production <sha>` itself (`rmx-ci`). On a server that was **not** built by `bootstrap.sh`, install `ansible-core` first (`sudo apt install -y ansible-core`); `bootstrap.sh` does it on a fresh one, and the `base` role keeps it (and `python3-apt`) installed from then on ([rmx-server-infra#17](https://github.com/rmx-lt/rmx-server-infra/issues/17)).

**What the CI key can do.** Its `authorized_keys` line forces `sudo rmx-ci "$SSH_ORIGINAL_COMMAND"`, and sudoers only allows `backup`, `check:<40 hex>` and `apply:<40 hex>`: no shell, no forwarding. `apply` first checks that the commit is on `origin/production`. Still, whoever can push to `production` or edit the workflow can run any playbook as root, so branch protection is the real boundary. If a bad deploy locks you out: provider dashboard terminal (root), fix and `./bootstrap.sh`, or reinstall and run `bootstrap.sh`.

## What it does not do

- Create or reinstall the VPS, DNS records, GitHub secrets, the device firmware: all outside the server.
- Restore **data** by itself: after a reinstall the probe database and Mosquitto's retained messages start empty until you run `rmx-ci restore` with a backup (see CI/CD above).
- Remove things you delete from the playbook. A deleted task leaves its result on the server; add an explicit `state: absent` first, or reinstall.
- Passwords of existing Mosquitto logins: it adds missing logins only (salted hashes can't be compared). To change one, edit the vault and run with `-e reset_mqtt_passwords=true`.
- Probe: the database password only takes effect when the database is first created; the app logins only when you run with `-e probe=on`.

## Test it without risk

The playbook was run against a fresh `ubuntu:24.04` container with systemd (swap is skipped in containers): second run `changed=0`, `--check` shows nothing, and a manual change to `sshd` is reported. Do the same before a big change; a throwaway VPS from any hourly provider works too.
