#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

header "Apps Status"

# Check if any apps registered
APP_COUNT=$(grep -cv '^#\|^$' "$APPS_CONF" || true)

if [[ "$APP_COUNT" -eq 0 ]]; then
    info "No apps deployed yet."
    echo "  Deploy one with: ./scripts/deploy.sh <repo-url> <app-name>"
    exit 0
fi

# Print table header
printf "${BOLD}%-20s %-5s %-10s %-20s %-18s %-30s %-5s${NC}\n" \
    "NAME" "SLOT" "STATUS" "FRONTEND" "IP" "URL" "CTRS"
printf '%.0s─' {1..110}
echo ""

while IFS='|' read -r name slot repo status npm_id frontend port app_ip npm_ip_id; do
    # Skip comments and empty lines
    [[ "$name" =~ ^#.*$ ]] && continue
    [[ -z "$name" ]] && continue

    # Count running containers
    DEPLOY_COMPOSE=$(get_compose_file "$name")
    CTRS=0
    if [[ -f "$DEPLOY_COMPOSE" ]]; then
        CTRS=$(docker compose -f "$DEPLOY_COMPOSE" -p "$name" ps -q 2>/dev/null | wc -l)
    fi

    # Determine actual status
    if [[ "$CTRS" -gt 0 ]]; then
        DISPLAY_STATUS="${GREEN}running${NC}"
    else
        DISPLAY_STATUS="${RED}stopped${NC}"
    fi

    URL="http://${name}.${DOMAIN_SUFFIX}"
    DISPLAY_IP="${app_ip:-—}"

    printf "%-20s %-5s %-10b %-20s %-18s %-30s %-5s\n" \
        "$name" "$slot" "$DISPLAY_STATUS" "${frontend}:${port}" "$DISPLAY_IP" "$URL" "$CTRS"
done < "$APPS_CONF"

echo ""
info "Network mode: ${NETWORK_MODE}"
info "Proxy network: ${PROXY_NETWORK}"
