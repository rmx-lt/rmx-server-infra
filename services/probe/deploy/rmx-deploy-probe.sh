#!/bin/bash
# Deploy one image tag of rmx-backend-probe. Installed as
# /usr/local/sbin/rmx-deploy-probe (root:root 0755). See wiki Server §10 "Probe".
#
# Called by GitHub Actions over SSH as the user "deploy". That user's
# authorized_keys entry forces this command, and sudoers lets it run this
# script as root, with this one argument shape, and nothing else:
#   ssh deploy@45.81.252.43 sha-1234abc
# By hand (as rmx): sudo rmx-deploy-probe sha-1234abc
#
# Steps: validate the tag -> pull -> rewrite PROBE_TAG in probe/.env ->
# if the probe is running, recreate probe-app and wait for "healthy";
# if it isn't healthy in time, put the previous tag back and fail.
# If the probe is off (profile stopped), only record and pull the tag:
# a deploy never turns the probe on.
set -euo pipefail
umask 077

SERVICES=/opt/rmx-vps/services
# Holds the passwords and PROBE_TAG; only the PROBE_TAG line is rewritten.
ENV_FILE=$SERVICES/probe/.env
IMAGE=ghcr.io/rmx-lt/rmx-backend-probe
LOG=/var/log/rmx-deploy-probe.log
HEALTH_TIMEOUT=90

log() {
	local line
	line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
	echo "$line"
	echo "$line" >>"$LOG"
	logger -t rmx-deploy-probe -- "$*" || true
}

# Over SSH, the requested tag arrives as the whole "command" the client sent.
TAG=${1:-}
if [[ ! $TAG =~ ^sha-[0-9a-f]{7}$ ]]; then
	# Don't echo the raw input back into the log: it is untrusted.
	log "REFUSED: tag is not sha-<7 hex> (caller ${SUDO_USER:-$USER})"
	exit 2
fi

# One deploy at a time.
exec 9>/run/lock/rmx-deploy-probe.lock
flock -w 300 9 || { log "REFUSED $TAG: another deploy is still running"; exit 3; }

cd "$SERVICES"
compose() { docker compose --profile probe "$@"; }

if [[ ! -f $ENV_FILE ]]; then
	log "REFUSED $TAG: $ENV_FILE is missing (see wiki Server §10 Probe)"
	exit 1
fi
PREV=$(sed -n 's/^PROBE_TAG=\(sha-[0-9a-f]\{7\}\)$/\1/p' "$ENV_FILE")

# Replace only the PROBE_TAG line, atomically, keeping the file's owner and
# mode (rmx 0600: rmx's own `docker compose` reads it).
write_tag() {
	local tmp
	tmp=$(mktemp "$ENV_FILE.XXXXXX")
	grep -v '^PROBE_TAG=' "$ENV_FILE" >"$tmp" || true
	printf 'PROBE_TAG=%s\n' "$1" >>"$tmp"
	chown --reference="$ENV_FILE" "$tmp"
	chmod --reference="$ENV_FILE" "$tmp"
	mv "$tmp" "$ENV_FILE"
}

wait_healthy() {
	local status="" i
	for ((i = 0; i < HEALTH_TIMEOUT; i += 3)); do
		status=$(compose ps --format '{{.Health}}' probe-app 2>/dev/null || true)
		[[ $status == healthy ]] && return 0
		sleep 3
	done
	log "probe-app is '${status:-missing}' after ${HEALTH_TIMEOUT}s"
	return 1
}

log "START $TAG (previous: ${PREV:-none}, caller ${SUDO_USER:-$USER})"

if ! docker pull -q "$IMAGE:$TAG" >/dev/null; then
	log "FAILED $TAG: pull failed, nothing changed"
	exit 1
fi

# Containers are found through Compose by service name, not container name (#41).
RUNNING=$(compose ps -q --status running probe-app 2>/dev/null || true)
write_tag "$TAG"

if [[ -z $RUNNING ]]; then
	log "OK $TAG: recorded and pulled; the probe is off, so nothing was started"
	exit 0
fi

compose up -d --no-deps probe-app
if wait_healthy; then
	log "OK $TAG: probe-app healthy"
	# Remove old probe images (the running one is kept; a rollback re-pulls).
	docker image prune -af --filter "label=org.opencontainers.image.source=https://github.com/rmx-lt/rmx-backend-probe" >/dev/null || true
	exit 0
fi

if [[ -z $PREV || $PREV == "$TAG" ]]; then
	log "FAILED $TAG: unhealthy, and no other tag to roll back to"
	exit 1
fi

log "ROLLBACK $TAG -> $PREV"
write_tag "$PREV"
compose up -d --no-deps probe-app
if wait_healthy; then
	log "FAILED $TAG: rolled back to $PREV (healthy)"
else
	log "FAILED $TAG: rolled back to $PREV, which is unhealthy too"
fi
exit 1
