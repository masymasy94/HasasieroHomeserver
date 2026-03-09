#!/usr/bin/env bash
# Shared variables, colors, and helpers for all scripts

# ─── Ensure ~/bin is in PATH (for yq) ───
export PATH="${HOME}/bin:${PATH}"

# ─── Load ACCESS_TOKEN from infrastructure/.env or Docker secret ───
if [[ -z "${ACCESS_TOKEN:-}" ]]; then
    _infra_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/infrastructure/.env"
    if [[ -f "$_infra_env" ]]; then
        ACCESS_TOKEN=$(grep '^ACCESS_TOKEN=' "$_infra_env" | cut -d= -f2- || true)
    fi
    # Fallback: read from Docker secret (runner container)
    if [[ -z "${ACCESS_TOKEN:-}" ]] && [[ -f /run/secrets/access_token ]]; then
        ACCESS_TOKEN=$(tr -d '[:space:]' < /run/secrets/access_token)
    fi
    export ACCESS_TOKEN
fi

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── Logging ───
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fatal()   { error "$@"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}\n"; }

# ─── Load settings ───
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "${COMMON_DIR}/../.." && pwd)"
SETTINGS_FILE="${APPS_ROOT}/config/settings.conf"

_SAVED_GIT_BRANCH="${GIT_BRANCH:-}"
if [[ -f "$SETTINGS_FILE" ]]; then
    source "$SETTINGS_FILE"
else
    fatal "Settings file not found: ${SETTINGS_FILE}"
fi
# Restore CI-provided branch override (settings.conf must not clobber it)
if [[ -n "$_SAVED_GIT_BRANCH" ]]; then
    GIT_BRANCH="$_SAVED_GIT_BRANCH"
fi
unset _SAVED_GIT_BRANCH

# Re-export computed paths (settings.conf may reference APPS_ROOT)
DEPLOYMENTS_DIR="${APPS_ROOT}/deployments"
APPS_CONF="${APPS_ROOT}/config/apps.conf"

# ─── Validation helpers ───
validate_app_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] && [[ ! "$name" =~ ^[a-z0-9]$ ]]; then
        fatal "Invalid app name '${name}'. Use lowercase alphanumeric and hyphens (e.g., my-app)."
    fi
}

app_exists() {
    local name="$1"
    grep -q "^${name}|" "$APPS_CONF" 2>/dev/null
}

app_is_running() {
    local name="$1"
    local containers
    containers=$(docker compose -p "$name" ps -q 2>/dev/null | wc -l)
    [[ "$containers" -gt 0 ]]
}

# ─── App registry helpers ───
get_app_field() {
    # get_app_field <app-name> <field-number> (1-indexed: name=1, slot=2, repo=3, status=4, npm_id=5, frontend=6, port=7, app_ip=8, npm_ip_id=9)
    local name="$1" field="$2"
    grep "^${name}|" "$APPS_CONF" | cut -d'|' -f"$field"
}

update_app_field() {
    # update_app_field <app-name> <field-number> <new-value>
    local name="$1" field="$2" value="$3"
    awk -v app="$name" -v f="$field" -v v="$value" 'BEGIN{FS=OFS="|"} $1==app {$f=v} {print}' \
        "$APPS_CONF" > "${APPS_CONF}.tmp" && mv "${APPS_CONF}.tmp" "$APPS_CONF"
}

next_slot() {
    local max=0
    while IFS='|' read -r _ slot _rest; do
        [[ "$slot" =~ ^[0-9]+$ ]] && (( slot > max )) && max=$slot
    done < <(grep -v '^#' "$APPS_CONF" | grep -v '^$')
    echo $(( max + 1 ))
}

# ─── Docker helpers ───
get_compose_file() {
    local app_name="$1"
    echo "${DEPLOYMENTS_DIR}/${app_name}/docker-compose.deploy.yml"
}

get_app_dir() {
    local app_name="$1"
    echo "${DEPLOYMENTS_DIR}/${app_name}"
}

require_app() {
    local name="$1"
    if ! app_exists "$name"; then
        fatal "App '${name}' is not deployed. See: ./scripts/status.sh"
    fi
}

require_yq() {
    if ! command -v yq &>/dev/null; then
        fatal "yq is not installed. Run: ./infrastructure/setup-network.sh"
    fi
}
