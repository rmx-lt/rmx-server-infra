#!/bin/bash
# Empty Ubuntu 24.04 VPS -> RMX-SERVER. Run as root, e.g. in the provider
# dashboard's terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/rmx-lt/rmx-server-infra/production/ansible/bootstrap.sh | bash
#
# It installs git + Ansible, clones this repo to /opt/rmx-vps and runs the
# playbook on this machine. It asks for the vault password (type it; it is
# never written to disk). Run it again any time: it pulls the repo and applies
# the playbook, changing only what differs. Extra arguments go to ansible:
#
#   bash bootstrap.sh --check --diff     show what would change
#   bash bootstrap.sh -e probe=on        also start the probe
set -euo pipefail

REPO=https://github.com/rmx-lt/rmx-server-infra.git
BRANCH=production
DIR=/opt/rmx-vps
ADMIN=rmx

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo -i)." >&2; exit 1; }
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] || echo "Warning: written for Ubuntu 24.04, this is ${PRETTY_NAME:-unknown}." >&2

export DEBIAN_FRONTEND=noninteractive
# A fresh image runs its first-boot update for a while: wait for the apt lock
# instead of failing (#50).
APT=(apt-get -o DPkg::Lock::Timeout=1200)
echo "Installing git and Ansible (a few minutes; waits if apt is busy)..."
"${APT[@]}" update -qq
"${APT[@]}" install -y -qq git ansible-core python3-apt >/dev/null

# The admin user owns the clone (read-only; wiki Server §9). Created here because
# the clone comes first; the playbook sets up the rest of it.
id "$ADMIN" &>/dev/null || useradd --create-home --shell /bin/bash "$ADMIN"

if [[ -d $DIR/.git ]]; then
	sudo -u "$ADMIN" git -C "$DIR" pull --ff-only -q
else
	install -d -o "$ADMIN" -g "$ADMIN" "$DIR"
	sudo -u "$ADMIN" git clone -q -b "$BRANCH" "$REPO" "$DIR"
fi

cd "$DIR/ansible"
# Vault password: from the terminal (works with `curl | bash` too).
exec ansible-playbook site.yml --ask-vault-pass "$@" </dev/tty
