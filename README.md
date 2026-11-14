# rmx-server-infra

Infrastructure of **RMX-SERVER**, the Blade of Grass VPS (`45.81.252.43`, Ubuntu 24.04): a hardened host running a Docker Compose stack with Caddy (HTTPS for `rmx.lt` with the app under `/app/`, and `api.rmx.lt`), Mosquitto (MQTT over TLS on `mqtt.rmx.lt:8883`) and rmx-server-app (the server) with its database.

- **Docs:** the wiki pages [Server-Infra](https://github.com/rmx-lt/blade-of-grass/wiki/Server-Infra) (access, hardening, services, ports, app deploy) and [Server-Infra-Ansible](https://github.com/rmx-lt/blade-of-grass/wiki/Server-Infra-Ansible) (setup as code, CI/CD). They live in this repo's [`wiki/`](wiki) folder and change by PR; rules: [Wiki-Policy](https://github.com/rmx-lt/blade-of-grass/blob/development/wiki/Wiki-Policy.md). Code comments cite them as "wiki Server-Infra §N".
- **Work:** issues on the [Blade of Grass project](https://github.com/orgs/rmx-lt/projects/1).

> No secrets in this repo: no passwords, private keys or tokens. `.gitignore` blocks common key files. The repo is public.

## Layout

```
services/   the Docker Compose stack (caddy, mosquitto, app), run from the server clone /opt/rmx-vps
ansible/    rebuilds the server from an empty Ubuntu 24.04 VPS (bootstrap.sh), and re-applies it safely
config/     copies of the server's host config files (sshd, ufw, fail2ban, docker, sudoers, sysctl)
```

## Quick reference

```powershell
ssh rmx-vps                                          # log in as rmx (key + passphrase)
ssh rmx-vps 'git -C /opt/rmx-vps pull --ff-only'     # after pushing a change from the PC
```

## License

Code and documentation are licensed under [Apache-2.0](LICENSE).
