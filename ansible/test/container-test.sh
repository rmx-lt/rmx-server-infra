#!/bin/bash
# Build the whole server from empty in a throwaway Ubuntu 24.04 container
# (systemd + Docker inside), then check that a second run changes nothing and
# that --check sees a manual change. Needs Docker with --privileged.
#   ansible/test/container-test.sh
# Not covered: the smoke test and Let's Encrypt (no DNS in a container), the swapfile, a real reboot.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
NAME=rmx-test
IMAGE=rmx-test-base
LOG=$(mktemp)
trap 'docker rm -f -v "$NAME" >/dev/null 2>&1 || true; rm -f "$LOG"' EXIT

ct() { docker exec "$NAME" bash -c "$*"; }

docker build -q -t "$IMAGE" - >/dev/null <<'DOCKERFILE'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq systemd systemd-sysv dbus sudo git curl ca-certificates \
    python3 python3-apt ansible-core iproute2 iptables kmod openssh-server >/dev/null \
 && apt-get clean
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
DOCKERFILE

docker rm -f -v "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
	--tmpfs /run --tmpfs /run/lock -v /var/lib/docker -v /var/lib/containerd "$IMAGE" >/dev/null
for _ in $(seq 30); do
	[[ $(ct 'systemctl is-system-running 2>/dev/null || true') =~ running|degraded ]] && break
	sleep 1
done

# The repo as a git clone at /opt/rmx-vps, owned by the admin user (what bootstrap.sh makes).
ct 'useradd --create-home --shell /bin/bash rmx; install -d -o rmx -g rmx /opt/rmx-vps'
tar -C "$REPO" --exclude=.git -cf - . | docker exec -i "$NAME" tar -C /opt/rmx-vps -xf -
ct 'chown -R rmx:rmx /opt/rmx-vps'
docker exec "$NAME" cp /opt/rmx-vps/ansible/test/vault.yml /opt/rmx-vps/ansible/group_vars/all/vault.yml

# The image drops its package lists after every apt run (docker-clean); a real VPS keeps them.
ct 'rm -f /etc/apt/apt.conf.d/docker-clean; apt-get update -qq; apt-cache policy unattended-upgrades | grep -q Candidate'

# No DNS here, so Caddy can't get a certificate and Mosquitto would restart
# forever (every run "starts" it again). Give it a self-signed one where Caddy keeps its own.
ct 'd=/opt/rmx-vps/services/caddy/data/data/caddy/certificates/test/mqtt.rmx.lt && mkdir -p $d &&
	openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=mqtt.rmx.lt -keyout $d/mqtt.rmx.lt.key -out $d/mqtt.rmx.lt.crt 2>/dev/null'

play() { ct "cd /opt/rmx-vps/ansible && ansible-playbook site.yml --skip-tags smoke $*"; }

echo "== run 1: from empty"
if ! play >"$LOG" 2>&1; then
	grep -B1 -A14 -E '^(fatal|failed):' "$LOG" | head -80 || true
	tail -40 "$LOG"
	echo "== diagnostics" >&2
	ct 'docker run --rm --network none -v /tmp:/x --user 1883 eclipse-mosquitto:2.1-alpine id; journalctl -u docker -n 20 --no-pager' 2>&1 | tail -30 || true
	exit 1
fi
tail -30 "$LOG"
echo "== run 2: must change nothing"
second=$(play | tee /dev/stderr)
grep -Eq 'changed=0 .*failed=0' <<<"$second" || { echo "FAIL: second run changed something" >&2; exit 1; }
echo "== --check after a manual change must report it"
ct "sed -i 's/^X11Forwarding no/X11Forwarding yes/' /etc/ssh/sshd_config.d/00-rmx.conf"
third=$(play --check --diff | tee /dev/stderr)
grep -q 'X11Forwarding' <<<"$third" || { echo "FAIL: --check did not see the manual change" >&2; exit 1; }
echo "OK: built from empty, idempotent, drift visible"
