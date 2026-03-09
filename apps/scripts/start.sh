#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

[[ $# -lt 1 ]] && { echo "Usage: $0 <app-name>"; exit 1; }

APP_NAME="$1"

header "Starting: ${APP_NAME}"

require_app "$APP_NAME"

DEPLOY_COMPOSE=$(get_compose_file "$APP_NAME")

if [[ ! -f "$DEPLOY_COMPOSE" ]]; then
    fatal "Deploy compose not found: ${DEPLOY_COMPOSE}"
fi

docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" up -d 2>&1 | while read -r line; do
    echo "  $line"
done

update_app_field "$APP_NAME" 4 "running"

CONTAINER_COUNT=$(docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" ps -q | wc -l)
success "App '${APP_NAME}' started — ${CONTAINER_COUNT} container(s)"
