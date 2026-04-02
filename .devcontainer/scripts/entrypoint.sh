#!/bin/sh
set -eu

FIREWALL_LOG=/var/log/firewall.log
REFRESH_INTERVAL="${FIREWALL_REFRESH_INTERVAL:-300}"
STATUS_INTERVAL="${FIREWALL_STATUS_INTERVAL:-60}"

# Set up network firewall (runs as root) and keep a readable status snapshot for the dev user.
/opt/scripts/setup-firewall.sh --setup >>"$FIREWALL_LOG" 2>&1

(
    while sleep "$REFRESH_INTERVAL"; do
        flock -n /var/lock/firewall-refresh.lock \
            /opt/scripts/setup-firewall.sh --refresh-only >>"$FIREWALL_LOG" 2>&1 || true
    done
) &

(
    while sleep "$STATUS_INTERVAL"; do
        /opt/scripts/setup-firewall.sh --write-status >>"$FIREWALL_LOG" 2>&1 || true
    done
) &

exec su-exec dev "$@"
