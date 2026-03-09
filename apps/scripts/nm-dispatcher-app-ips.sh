#!/usr/bin/env bash
# NetworkManager dispatcher script
# Ensures app alias IPs and SERVER_IP are present on whichever interface becomes active
#
# Installed to: /etc/NetworkManager/dispatcher.d/99-app-ips
# Called by NM with: $1 = interface, $2 = action

INTERFACE="$1"
ACTION="$2"

# Only act on "up" events for physical interfaces
[[ "$ACTION" != "up" ]] && exit 0
[[ "$INTERFACE" == lo ]] && exit 0
[[ "$INTERFACE" == docker* ]] && exit 0
[[ "$INTERFACE" == br-* ]] && exit 0
[[ "$INTERFACE" == veth* ]] && exit 0
[[ "$INTERFACE" == tailscale* ]] && exit 0

SETTINGS="/home/masy/Desktop/docker/apps/config/settings.conf"
LOGFILE="/var/log/app-ip-dispatcher.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$INTERFACE:$ACTION] $*" >> "$LOGFILE"; }

[[ ! -f "$SETTINGS" ]] && exit 0
source "$SETTINGS"

APPS_CONF="${APPS_CONF:-${APPS_ROOT}/config/apps.conf}"
MASK="${IP_ALIAS_NETMASK:-24}"

# Collect all IPs that need to be on the active interface
declare -a REQUIRED_IPS=()

# 1) SERVER_IP (primary server IP for non-app containers)
if [[ -n "$SERVER_IP" ]]; then
    REQUIRED_IPS+=("$SERVER_IP")
fi

# 2) All app alias IPs from the registry
if [[ -f "$APPS_CONF" ]]; then
    while IFS='|' read -r name slot repo status npm_id fe_svc fe_port app_ip _; do
        [[ -z "$app_ip" || "$name" == \#* ]] && continue
        [[ "$status" == "removed" ]] && continue
        REQUIRED_IPS+=("$app_ip")
    done < "$APPS_CONF"
fi

if [[ ${#REQUIRED_IPS[@]} -eq 0 ]]; then
    log "No IPs to manage"
    exit 0
fi

# Add any missing IPs to the interface that just came up
for ip in "${REQUIRED_IPS[@]}"; do
    if ip addr show "$INTERFACE" 2>/dev/null | grep -q "inet ${ip}/"; then
        log "IP ${ip} already present on ${INTERFACE}"
    else
        if ip addr add "${ip}/${MASK}" dev "$INTERFACE" 2>/dev/null; then
            log "Added ${ip}/${MASK} to ${INTERFACE}"
        else
            log "Failed to add ${ip}/${MASK} to ${INTERFACE}"
        fi
    fi
done
