# rmx-server-infra — notes for agents

Project-wide agent rules live in the meta repo's [CLAUDE.md](https://github.com/rmx-lt/blade-of-grass/blob/development/CLAUDE.md); read it first. This file only adds what is specific to this repo.

Infrastructure of the Blade of Grass VPS: Ansible playbook, Docker Compose stack (Caddy, Mosquitto, probe) and CI/CD. Current state is documented in the wiki page [Server-Infra](https://github.com/rmx-lt/blade-of-grass/wiki/Server-Infra) (local: `wiki/Server-Infra.md`).

## Docs

- Read [Wiki-Policy](https://github.com/rmx-lt/blade-of-grass/blob/development/wiki/Wiki-Policy.md) before writing docs.
- Pages live in `wiki/` and change by PR. A server change updates `wiki/` in the same PR. There is no changelog: history is git and the PRs.
- Public repo: no passwords, tokens, private keys, home IPs, personal names or emails.

## VPS safety rules

- Ask the user before any step that could lock them out (sshd, ufw, users, sudoers, network).
- sshd changes: back up first, run `sudo sshd -t` before reload/restart, keep the current session open, and test a **new** `ssh rmx-vps` login. For risky changes, schedule an auto-rollback (`systemd-run --on-active=5min …`) and cancel it after the test passes.
- Never put a `Match` block in `sshd_config.d/`: those files are included at the top of the main file, so the `Match` would swallow the settings after it.
- Docker bypasses ufw: databases publish no ports, private tools bind to `127.0.0.1`, public ports are deliberate and documented.
- The probe stays on: never stop `probe-app`/`probe-db` unless the user asks. Never run `docker compose --profile probe stop|down` without service names (it also stops Caddy and Mosquitto).
- Run `docker compose` from `services/` (project `rmx`) and address services by service name, not container name.
- Secrets (`credentials.txt`, vault, `.env` files on the server): read them into a variable over ssh, never print them in chat, logs or commits.
- Commands that need a password or passphrase: give the user the exact command to run themselves.
- Merging to `production` deploys (encrypted backup, then the playbook). Confirm with the user before pushing anything that deploys; pushing to the public repo publishes it.
- No doxing: never commit the user's home IP, Windows username, real name or personal email; use `%USERPROFILE%` in paths.
