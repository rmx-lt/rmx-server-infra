#!/bin/bash
# Collect every secret of the CURRENT hand-built server into
# group_vars/all/vault.yml (plain text, then encrypted), so a rebuild keeps
# the same passwords and SSH host keys. Run once, as the admin user on the
# old server, before reinstalling:
#
#   cd /opt/rmx-vps/ansible && sudo ./export-vault.sh
#   ansible-vault encrypt group_vars/all/vault.yml     (asks for a new password)
#   git add group_vars/all/vault.yml && git commit && git push
#
# Nothing is printed. The file is created 0600 and never left unencrypted:
# the script refuses to run if one already exists. Fields it cannot find are
# left as "change-me": fill them in with `ansible-vault edit`.
set -euo pipefail
umask 077

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
cd "$(dirname "$0")"
OUT=group_vars/all/vault.yml
SERVICES=/opt/rmx-vps/services
[[ ! -e $OUT ]] || { echo "$OUT exists already; move it away first." >&2; exit 1; }

# user password lines of a credentials file -> "  user: password"
pairs() { awk 'NF==2 {print "  " $1 ": " $2}' "$1" 2>/dev/null || true; }

{
	echo "# Secrets of RMX-SERVER, exported $(date -u +%F) by export-vault.sh."
	echo "# Encrypt before committing: ansible-vault encrypt $OUT"
	echo
	echo "vault_ssh_host_keys:"
	for t in ed25519 ecdsa rsa; do
		k=/etc/ssh/ssh_host_${t}_key
		[[ -f $k ]] || continue
		echo "  - type: $t"
		echo "    private: |"
		sed 's/^/      /' "$k"
		echo "    public: $(cut -d' ' -f1,2 "$k.pub") root@$(hostname)"
	done
	echo
	echo "vault_mosquitto_users:"
	pairs "$SERVICES/mosquitto/data/credentials.txt"
	echo
	echo "vault_caddy_fw_users:"
	if [[ -f $SERVICES/caddy/private/fw-users.caddy ]]; then
		while read -r name hash; do
			[[ -n $name ]] || continue
			pw=$(awk -v n="$name" '$1==n {print $2}' "$SERVICES/caddy/private/credentials.txt" 2>/dev/null || true)
			echo "  - name: $name"
			echo "    password: ${pw:-change-me}"
			echo "    hash: '$hash'"
		done <"$SERVICES/caddy/private/fw-users.caddy"
	fi
	echo
	echo "vault_probe_db_password: $(sed -n 's/^PROBE_DB_PASSWORD=//p' "$SERVICES/probe/.env" 2>/dev/null | head -1 | grep . || echo change-me)"
	echo "vault_probe_app_users:"
	awk '$1=="app-login" {print "  " $2 ": " $3}' "$SERVICES/probe/data/credentials.txt" 2>/dev/null || true
	echo
	echo "# The public half of DEPLOY_SSH_KEY, from /home/deploy/.ssh/authorized_keys."
	echo "vault_deploy_ssh_key: $(sed -n 's/^.*\(ssh-ed25519 [A-Za-z0-9+\/=]* [^ ]*\)$/\1/p' /home/deploy/.ssh/authorized_keys 2>/dev/null | head -1)"
	echo
	echo "vault_github_deploy_key: |"
	if [[ -f /home/rmx/.ssh/github-rmx-vps ]]; then sed 's/^/  /' /home/rmx/.ssh/github-rmx-vps; else echo "  "; fi
} >"$OUT"
chmod 600 "$OUT"
chown "${SUDO_USER:-root}": "$OUT"
echo "Wrote $OUT ($(wc -l <"$OUT") lines). Encrypt it now: ansible-vault encrypt $OUT"
