#!/bin/bash
# Deploy one image tag of rmx-server-app. Installed as
# /usr/local/sbin/rmx-deploy-app (root:root 0755). See wiki Server-Infra §10 "App".
#
# Called by GitHub Actions over SSH as the user "deploy". That user's
# authorized_keys entry forces this command, and sudoers lets it run this
# script as root, with this one argument shape, and nothing else:
#   ssh deploy@45.81.252.43 sha-1234abc
# By hand (as rmx): sudo rmx-deploy-app sha-1234abc
#
# Steps: validate the tag -> pull -> rewrite APP_TAG in app/.env ->
# recreate app and wait for "healthy"; if it isn't healthy in time, put the
# previous tag back and fail. The app is always on, so this always recreates
# it (a deploy also starts it if it was stopped).
set -euo pipefail
umask 077

SERVICES=/opt/rmx-vps/services
# Holds the passwords and APP_TAG; only the APP_TAG line is rewritten.
ENV_FILE=$SERVICES/app/.env
IMAGE=ghcr.io/rmx-lt/rmx-server-app
LOG=/var/log/rmx-deploy-app.log
HEALTH_TIMEOUT=90

log() {
	local line
	line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
	echo "$line"
	echo "$line" >>"$LOG"
	logger -t rmx-deploy-app -- "$*" || true
}

# Over SSH, the requested tag arrives as the whole "command" the client sent.
TAG=${1:-}
if [[ ! $TAG =~ ^sha-[0-9a-f]{7}$ ]]; then
	# Don't echo the raw input back into the log: it is untrusted.
	log "REFUSED: tag is not sha-<7 hex> (caller ${SUDO_USER:-$USER})"
	exit 2
fi

# One deploy at a time.
exec 9>/run/lock/rmx-deploy-app.lock
flock -w 300 9 || { log "REFUSED $TAG: another deploy is still running"; exit 3; }

cd "$SERVICES"
compose() { docker compose "$@"; }

if [[ ! -f $ENV_FILE ]]; then
	log "REFUSED $TAG: $ENV_FILE is missing (see wiki Server-Infra §10 App)"
	exit 1
fi
PREV=$(sed -n 's/^APP_TAG=\(sha-[0-9a-f]\{7\}\)$/\1/p' "$ENV_FILE")

# Replace only the APP_TAG line, atomically, keeping the file's owner and
# mode (rmx 0600: rmx's own `docker compose` reads it).
write_tag() {
	local tmp
	tmp=$(mktemp "$ENV_FILE.XXXXXX")
	grep -v '^APP_TAG=' "$ENV_FILE" >"$tmp" || true
	printf 'APP_TAG=%s\n' "$1" >>"$tmp"
	chown --reference="$ENV_FILE" "$tmp"
	chmod --reference="$ENV_FILE" "$tmp"
	mv "$tmp" "$ENV_FILE"
}

wait_healthy() {
	local status="" i
	for ((i = 0; i < HEALTH_TIMEOUT; i += 3)); do
		status=$(compose ps --format '{{.Health}}' app 2>/dev/null || true)
		[[ $status == healthy ]] && return 0
		sleep 3
	done
	log "app is '${status:-missing}' after ${HEALTH_TIMEOUT}s"
	return 1
}

log "START $TAG (previous: ${PREV:-none}, caller ${SUDO_USER:-$USER})"

if ! docker pull -q "$IMAGE:$TAG" >/dev/null; then
	log "FAILED $TAG: pull failed, nothing changed"
	exit 1
fi

write_tag "$TAG"

compose up -d --no-deps app
if wait_healthy; then
	log "OK $TAG: app healthy"
	# Remove old app images (the running one is kept; a rollback re-pulls).
	docker image prune -af --filter "label=org.opencontainers.image.source=https://github.com/rmx-lt/rmx-server-app" >/dev/null || true
	exit 0
fi

if [[ -z $PREV || $PREV == "$TAG" ]]; then
	log "FAILED $TAG: unhealthy, and no other tag to roll back to"
	exit 1
fi

log "ROLLBACK $TAG -> $PREV"
write_tag "$PREV"
compose up -d --no-deps app
if wait_healthy; then
	log "FAILED $TAG: rolled back to $PREV (healthy)"
else
	log "FAILED $TAG: rolled back to $PREV, which is unhealthy too"
fi
exit 1
