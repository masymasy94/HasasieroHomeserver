#!/usr/bin/env bash
set -euo pipefail

# ci-deploy.sh — Unified deploy/update for CI/CD
# Deploys if app doesn't exist, updates if it does.
#
# Usage: ci-deploy.sh <repo-url> <app-name> [branch]
#   branch defaults to GIT_BRANCH from settings.conf

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

[[ $# -lt 2 ]] && { echo "Usage: $0 <repo-url> <app-name> [branch]"; exit 1; }

REPO_URL="$1"
APP_NAME="$2"
# Override GIT_BRANCH if passed as 3rd arg
if [[ $# -ge 3 ]]; then
    export GIT_BRANCH="$3"
    info "Branch override: ${GIT_BRANCH}"
fi

if app_exists "$APP_NAME"; then
    info "App '${APP_NAME}' exists — running update"
    exec "${SCRIPT_DIR}/update.sh" "$APP_NAME"
else
    info "App '${APP_NAME}' not found — running first deploy"
    exec "${SCRIPT_DIR}/deploy.sh" "$REPO_URL" "$APP_NAME"
fi
