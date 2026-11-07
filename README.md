# rmx-server-infra

Infrastructure of **RMX-SERVER**, the Blade of Grass VPS (`45.81.252.43`, Ubuntu 24.04): a hardened host running a Docker Compose stack with Caddy (HTTPS for `rmx.lt`, `api.rmx.lt`), Mosquitto (MQTT over TLS on `mqtt.rmx.lt:8883`) and the backend probe.

- **Docs:** the wiki page [Server](https://github.com/rmx-lt/blade-of-grass/wiki/Server) (access, hardening, services, ports, probe deploy), [Server-Ansible](https://github.com/rmx-lt/blade-of-grass/wiki/Server-Ansible) (setup as code, CI/CD) and the [Server-Changelog](https://github.com/rmx-lt/blade-of-grass/wiki/Server-Changelog). Code comments cite them as "wiki Server §N".
- **Work:** issues on the [Blade of Grass project](https://github.com/orgs/rmx-lt/projects/1).

> No secrets in this repo: no passwords, private keys or tokens. `.gitignore` blocks common key files. The repo is public.

## Layout

```
services/   the Docker Compose stack (caddy, mosquitto, probe), run from the server clone /opt/rmx-vps
ansible/    rebuilds the server from an empty Ubuntu 24.04 VPS (bootstrap.sh), and re-applies it safely
config/     copies of the server's host config files (sshd, ufw, fail2ban, docker, sudoers, sysctl)
```

## Quick reference

```powershell
ssh rmx-vps                                          # log in as rmx (key + passphrase)
ssh rmx-vps 'git -C /opt/rmx-vps pull --ff-only'     # after pushing a change from the PC
```

Every change to the server gets a dated entry on the [Server-Changelog](https://github.com/rmx-lt/blade-of-grass/wiki/Server-Changelog) wiki page (what, why, backup, undo).

## License

Code and documentation are licensed under [Apache-2.0](LICENSE).
