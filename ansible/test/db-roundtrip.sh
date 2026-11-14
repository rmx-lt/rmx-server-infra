#!/bin/bash
# rmx-ci backup -> change the data -> rmx-ci restore, against a throwaway
# db started from the real services/compose.yaml (rmx-ci finds it
# through Compose by service name, #41). Needs Docker and root.
# Run from the repo: sudo ansible/test/db-roundtrip.sh
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
CI=$REPO/ansible/ci/rmx-ci.sh
ENV_FILE=$REPO/services/app/.env
[[ -e $ENV_FILE ]] && { echo "refusing: $ENV_FILE exists (not a test checkout?)" >&2; exit 1; }
WORK=$(mktemp -d)
compose() { docker compose -f "$REPO/services/compose.yaml" "$@"; }
cleanup() {
	compose down -v >/dev/null 2>&1 || true
	rm -rf "$WORK" "$ENV_FILE" "$REPO/services/app/data" "$REPO/services/app/firmware" "$REPO/services/mosquitto/data"
}
trap cleanup EXIT

psql() { compose exec -T db psql -U app -d "${DB:-app}" -v ON_ERROR_STOP=1 -tA "$@"; }

printf 'APP_DB_PASSWORD=test\nAPP_MQTT_PASSWORD=test\nAPP_TAG=sha-0000000\n' >"$ENV_FILE"
compose up -d --wait db
sleep 3 # the image restarts postgres once after its init scripts
for _ in $(seq 60); do compose exec -T db pg_isready -U app -q && break; sleep 1; done

psql -q -c "CREATE EXTENSION IF NOT EXISTS timescaledb" \
	-c "CREATE TABLE readings(ts timestamptz NOT NULL, v int)" \
	-c "SELECT create_hypertable('readings','ts')" \
	-c "INSERT INTO readings SELECT now() - i * interval '1 hour', i FROM generate_series(1,500) i" >/dev/null
before=$(psql -c "SELECT count(*), sum(v) FROM readings")
echo "before: $before"

mkdir -p "$REPO/services/mosquitto/data/store"
echo "retained-message-store" >"$REPO/services/mosquitto/data/store/mosquitto.db"
mkdir -p "$REPO/services/app/firmware"
echo "firmware-image" >"$REPO/services/app/firmware/app.bin"

RMX_REPO=$REPO "$CI" backup >"$WORK/backup.tar.gz"
listing=$(tar -tzf "$WORK/backup.tar.gz")
grep -qx './app.dump' <<<"$listing"
grep -q 'services/mosquitto/data/store/mosquitto.db' <<<"$listing"
grep -q 'services/app/firmware/app.bin' <<<"$listing"

psql -q -c "DELETE FROM readings WHERE v > 10" -c "INSERT INTO readings VALUES (now(), -1)" >/dev/null
rm "$REPO/services/mosquitto/data/store/mosquitto.db" "$REPO/services/app/firmware/app.bin"
echo "damaged: $(psql -c 'SELECT count(*), sum(v) FROM readings')"

RMX_REPO=$REPO RMX_ADMIN=root "$CI" restore "$WORK/backup.tar.gz"
after=$(psql -c "SELECT count(*), sum(v) FROM readings")
echo "after:  $after"
[[ $before == "$after" ]] || { echo "FAIL: data differs after restore" >&2; exit 1; }
[[ $(psql -c "SELECT count(*) FROM timescaledb_information.hypertables") == 1 ]] || { echo "FAIL: hypertable lost" >&2; exit 1; }
[[ $(cat "$REPO/services/mosquitto/data/store/mosquitto.db") == retained-message-store ]] || { echo "FAIL: mosquitto store not restored" >&2; exit 1; }
[[ $(cat "$REPO/services/app/firmware/app.bin") == firmware-image ]] || { echo "FAIL: firmware not restored" >&2; exit 1; }
echo "OK: backup and restore round trip"
