#!/bin/bash
# Copy Caddy's Let's Encrypt certificate for mqtt.rmx.lt to Mosquitto.
#
# Caddy obtains and renews the cert (site block in services/caddy/Caddyfile)
# and keeps it root-only in its data folder. Mosquitto runs as uid 1883 and
# can't read that folder, so this script copies the cert and key into
# services/mosquitto/data/certs/ with owner 1883. When they changed, it sends
# SIGHUP to Mosquitto, which reloads them without dropping connections.
#
# Installed as /usr/local/sbin/rmx-mqtt-cert-sync, run as root by
# rmx-mqtt-cert-sync.timer. Safe to run by hand at any time.
set -euo pipefail

DOMAIN=mqtt.rmx.lt
SERVICES=/opt/rmx-vps/services
CADDY_CERTS=$SERVICES/caddy/data/data/caddy/certificates
DEST=$SERVICES/mosquitto/data/certs
MQTT_UID=1883

# Caddy keeps one folder per CA (normally Let's Encrypt; ZeroSSL is its
# fallback). Take the newest cert for the domain from any of them.
crt=$(ls -t "$CADDY_CERTS"/*/"$DOMAIN"/"$DOMAIN".crt 2>/dev/null | head -n1 || true)
if [ -z "$crt" ]; then
	echo "No certificate for $DOMAIN in $CADDY_CERTS yet" >&2
	exit 1
fi
key=${crt%.crt}.key

# Don't install a cert/key pair that doesn't match (e.g. caught mid-write).
if ! cmp -s <(openssl x509 -in "$crt" -noout -pubkey) <(openssl pkey -in "$key" -pubout); then
	echo "Certificate and key in $(dirname "$crt") don't match, skipping" >&2
	exit 1
fi

if cmp -s "$crt" "$DEST/fullchain.pem" && cmp -s "$key" "$DEST/privkey.pem"; then
	exit 0 # unchanged
fi

install -d -o "$MQTT_UID" -g "$MQTT_UID" -m 0750 "$DEST"
# Write to temp files, then rename, so Mosquitto never sees half a file.
install -o "$MQTT_UID" -g "$MQTT_UID" -m 0644 "$crt" "$DEST/.fullchain.pem.new"
install -o "$MQTT_UID" -g "$MQTT_UID" -m 0600 "$key" "$DEST/.privkey.pem.new"
mv -f "$DEST/.fullchain.pem.new" "$DEST/fullchain.pem"
mv -f "$DEST/.privkey.pem.new" "$DEST/privkey.pem"
echo "Installed new certificate for $DOMAIN: $(openssl x509 -in "$DEST/fullchain.pem" -noout -enddate)"

# Through Compose by service name, not container name (#41).
compose() { docker compose -f "$SERVICES/compose.yaml" "$@"; }
if [ -n "$(compose ps -q --status running mosquitto 2>/dev/null)" ]; then
	compose kill -s HUP mosquitto 2>/dev/null
	echo "Sent SIGHUP to mosquitto"
fi
