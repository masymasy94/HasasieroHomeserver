#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/npm-api.sh"
source "${SCRIPT_DIR}/lib/ip-alias.sh"

[[ $# -lt 1 ]] && { echo "Usage: $0 <app-name>"; exit 1; }

APP_NAME="$1"

header "Removing: ${APP_NAME}"

require_app "$APP_NAME"

APP_DIR=$(get_app_dir "$APP_NAME")
DEPLOY_COMPOSE=$(get_compose_file "$APP_NAME")
NPM_HOST_ID=$(get_app_field "$APP_NAME" 5)
APP_IP=$(get_app_field "$APP_NAME" 8)
NPM_IP_HOST_ID=$(get_app_field "$APP_NAME" 9)

# ─── Confirm ───
echo -e "${YELLOW}This will permanently remove:${NC}"
echo "  - All containers and volumes for '${APP_NAME}'"
echo "  - NPM proxy host (ID: ${NPM_HOST_ID})"
[[ -n "$APP_IP" ]] && echo "  - IP alias: ${APP_IP}"
echo "  - Directory: ${APP_DIR}"
echo "  - Registry entry"
echo ""
read -rp "Type '${APP_NAME}' to confirm: " CONFIRM
if [[ "$CONFIRM" != "$APP_NAME" ]]; then
    info "Cancelled."
    exit 0
fi

# ─── Stop and remove containers + volumes ───
if [[ -f "$DEPLOY_COMPOSE" ]]; then
    info "Stopping and removing containers..."
    docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" down -v 2>&1 | while read -r line; do
        echo "  $line"
    done
else
    warn "Deploy compose not found, attempting project-level removal..."
    docker compose -p "$APP_NAME" down -v 2>/dev/null || true
fi

# ─── Stop and remove extra compose (e.g. frontend) ───
for extra_deploy in $(find "$APP_DIR" -name "docker-compose.deploy.yml" -not -path "$DEPLOY_COMPOSE" 2>/dev/null); do
    info "Removing extra compose: ${extra_deploy#${APP_DIR}/}"
    docker compose -f "$extra_deploy" -p "${APP_NAME}-frontend" down -v 2>&1 | while read -r line; do
        echo "  $line"
    done
done

# ─── Remove NPM proxy host ───
if [[ -n "$NPM_HOST_ID" ]] && [[ "$NPM_HOST_ID" != "manual" ]]; then
    info "Removing NPM proxy host (ID: ${NPM_HOST_ID})..."
    npm_delete_proxy "$NPM_HOST_ID" && success "NPM proxy removed" || warn "NPM proxy removal failed"
else
    info "Skipping NPM cleanup (manual or no ID)"
fi

# ─── Remove IP alias and its NPM proxy ───
if [[ -n "$APP_IP" ]]; then
    if [[ -n "$NPM_IP_HOST_ID" ]]; then
        info "Removing IP proxy host (ID: ${NPM_IP_HOST_ID})..."
        npm_delete_proxy "$NPM_IP_HOST_ID" && success "IP proxy removed" || warn "IP proxy removal failed"
    fi
    info "Removing IP alias: ${APP_IP}"
    remove_ip_alias "$APP_IP" && success "IP alias removed" || warn "IP alias removal failed"
fi

# ─── Remove deployment directory ───
if [[ -d "$APP_DIR" ]]; then
    info "Removing directory: ${APP_DIR}"
    rm -rf "$APP_DIR"
fi

# ─── Remove from registry ───
sed -i "/^${APP_NAME}|/d" "$APPS_CONF"
success "Removed from registry"

echo ""
success "App '${APP_NAME}' fully removed"
