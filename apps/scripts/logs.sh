#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    echo "Usage: $0 <app-name> [service] [--follow]"
    echo ""
    echo "Tail logs for a deployed app."
    echo ""
    echo "Arguments:"
    echo "  app-name   Name of the deployed app"
    echo "  service    Optional: specific service name (default: all)"
    echo "  --follow   Follow log output (like tail -f)"
    exit 1
}

[[ $# -lt 1 ]] && usage

APP_NAME="$1"
SERVICE=""
FOLLOW=""

shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --follow|-f) FOLLOW="--follow" ;;
        *) SERVICE="$1" ;;
    esac
    shift
done

require_app "$APP_NAME"

DEPLOY_COMPOSE=$(get_compose_file "$APP_NAME")

if [[ ! -f "$DEPLOY_COMPOSE" ]]; then
    fatal "Deploy compose not found: ${DEPLOY_COMPOSE}"
fi

docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" logs --tail=100 $FOLLOW $SERVICE
