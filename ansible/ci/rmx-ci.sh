#!/bin/bash
# Installed as /usr/local/sbin/rmx-ci. Runs as root. Two callers:
#   GitHub Actions, as user "ci" (forced ssh command + sudoers, see roles/users):
#     rmx-ci backup              config + database dump as a tar.gz on stdout
#     rmx-ci check:<sha>         fast-forward the repo to <sha>, ansible --check --diff
#     rmx-ci apply:<sha>         fast-forward the repo to <sha>, run the playbook
#   You, on the server, to get data back after a rebuild:
#     sudo rmx-ci restore FILE   FILE = decrypted backup tar.gz (wiki Server-Infra §11)
# check / apply read the vault password from the first line of stdin; it only
# lives in a root-only file on tmpfs for the length of the run.
set -euo pipefail

REPO=${RMX_REPO:-/opt/rmx-vps}
ADMIN=${RMX_ADMIN:-rmx}
BRANCH=production
DB_NAME=app
DB_USER=app

log() { echo "rmx-ci: $*" >&2; }
die() { log "$*"; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"

mk_tmp() {
	TMP=$(mktemp -d /run/rmx-ci.XXXXXX)
	trap 'rm -rf "$TMP"' EXIT
}

# Services are addressed through Compose (by service name), never by
# container name (#41).
compose() { docker compose -f "$REPO/services/compose.yaml" "$@"; }
running() { [[ -n $(compose ps -q --status running "$1" 2>/dev/null) ]]; }

backup() {
	mk_tmp
	if running db; then
		compose exec -T db pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc >"$TMP/app.dump"
		log "database dumped ($(stat -c %s "$TMP/app.dump") bytes)"
	else
		log "db is not running: no database dump"
	fi
	# The raw database folder is skipped (a dump of a live one is not
	# consistent); .git comes back with the next clone.
	local rc=0 repo=${REPO#/}
	tar -czf - --exclude="$repo/.git" --exclude="$repo/services/app/data/db" \
		-C / etc "$repo" -C "$TMP" . || rc=$?
	((rc <= 1)) || die "tar failed ($rc)" # 1 = a file changed while reading
}

restore() {
	local file=${1:-}
	[[ -f $file ]] || die "usage: rmx-ci restore BACKUP.tar.gz"
	mk_tmp
	local rel=${REPO#/}
	tar -xzf "$file" -C "$TMP" ./app.dump "$rel/services/mosquitto/data/store" \
		"$rel/services/app/firmware" "$rel/services/app/.env" 2>/dev/null || true

	if [[ -f $TMP/app.dump ]]; then
		running db || die "db is not running (start it: docker compose up -d db)"
		local app_was_up=false psql=(compose exec -T db psql -U "$DB_USER" -v ON_ERROR_STOP=1 -q)
		if running app; then
			app_was_up=true
			compose stop app 2>/dev/null
		fi
		# A fresh database: the timescaledb restore procedure needs one.
		"${psql[@]}" -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE)" -c "CREATE DATABASE $DB_NAME"
		"${psql[@]}" -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS timescaledb" -c "SELECT timescaledb_pre_restore()"
		compose exec -T db pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner <"$TMP/app.dump"
		"${psql[@]}" -d "$DB_NAME" -c "SELECT timescaledb_post_restore()"
		if $app_was_up; then compose start app 2>/dev/null; fi
		log "database restored"
	else
		log "no database dump in this backup"
	fi

	# OTA images the app serves over MQTT: owned by the admin user, read-only for the app.
	local fw=$TMP/$rel/services/app/firmware
	if [[ -d $fw ]]; then
		mkdir -p "$REPO/services/app/firmware"
		cp -a "$fw/." "$REPO/services/app/firmware/"
		chown -R "$ADMIN:$ADMIN" "$REPO/services/app/firmware"
		log "firmware images restored"
	fi

	# The app image that was deployed, not the (possibly older) one in the vault.
	local tag
	tag=$(sed -n 's/^APP_TAG=//p' "$TMP/$rel/services/app/.env" 2>/dev/null | head -n1 || true)
	if [[ $tag =~ ^sha-[0-9a-f]{7}$ ]]; then
		if running app; then
			/usr/local/sbin/rmx-deploy-app "$tag"
			log "app image set to $tag"
		else
			log "app is not running: deploy $tag later with rmx-deploy-app"
		fi
	fi

	local store=$TMP/$rel/services/mosquitto/data/store
	if [[ -d $store ]]; then
		local dest=$REPO/services/mosquitto/data/store was_up=false
		if running mosquitto; then
			was_up=true
			compose stop mosquitto 2>/dev/null
		fi
		mkdir -p "$dest"
		cp -a "$store/." "$dest/"
		if $was_up; then compose start mosquitto 2>/dev/null; fi
		log "mosquitto store restored"
	fi
}

# Move the clone to <sha>, which must already be on origin/production.
sync_repo() {
	local sha=$1 as=(sudo -u "$ADMIN")
	"${as[@]}" git -C "$REPO" fetch -q origin "$BRANCH"
	"${as[@]}" git -C "$REPO" merge-base --is-ancestor "$sha" FETCH_HEAD ||
		die "$sha is not on origin/$BRANCH"
	if [[ $("${as[@]}" git -C "$REPO" branch --show-current) == "$BRANCH" ]]; then
		"${as[@]}" git -C "$REPO" merge -q --ff-only "$sha"
	else
		"${as[@]}" git -C "$REPO" checkout -q -B "$BRANCH" "$sha"
	fi
	log "repo at $(git -C "$REPO" rev-parse --short HEAD)"
}

play() {
	local sha=$1
	shift
	mk_tmp
	local pw=$TMP/vault-pass
	(umask 077 && IFS= read -r line && printf '%s\n' "$line" >"$pw") || die "no vault password on stdin"
	sync_repo "$sha"
	cd "$REPO/ansible"
	ansible-playbook site.yml --vault-password-file "$pw" "$@"
}

case ${1:-} in
backup) backup ;;
restore) restore "${2:-}" ;;
check:*) [[ ${1#check:} =~ ^[0-9a-f]{40}$ ]] || die "bad sha"; play "${1#check:}" --check --diff ;;
apply:*) [[ ${1#apply:} =~ ^[0-9a-f]{40}$ ]] || die "bad sha"; play "${1#apply:}" ;;
*) die "usage: rmx-ci backup | restore FILE | check:<sha> | apply:<sha>" ;;
esac
