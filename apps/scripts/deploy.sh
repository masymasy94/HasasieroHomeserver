#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/npm-api.sh"
source "${SCRIPT_DIR}/lib/detect-frontend.sh"
source "${SCRIPT_DIR}/lib/maven-build.sh"
source "${SCRIPT_DIR}/lib/ip-alias.sh"

# ─── Usage ───
usage() {
    echo "Usage: $0 <repo-url-or-path> <app-name>"
    echo ""
    echo "Deploy a Docker Compose app from a git repository or local path."
    echo ""
    echo "Arguments:"
    echo "  repo-url-or-path   Git clone URL or local path to a project with docker-compose.yml"
    echo "  app-name           Unique name for this deployment (lowercase, alphanumeric, hyphens)"
    echo ""
    echo "Examples:"
    echo "  $0 https://github.com/user/myapp.git myapp"
    echo "  $0 /home/user/projects/myapp myapp"
    exit 1
}

[[ $# -lt 2 ]] && usage

REPO="$1"
APP_NAME="$2"

# ─── Step 1: Validate ───
header "Deploying: ${APP_NAME}"

validate_app_name "$APP_NAME"
require_yq

if app_exists "$APP_NAME"; then
    fatal "App '${APP_NAME}' is already deployed. Use update.sh or remove.sh first."
fi

APP_DIR="${DEPLOYMENTS_DIR}/${APP_NAME}"
DEPLOY_COMPOSE="${APP_DIR}/docker-compose.deploy.yml"

# Clean up stale directory (exists on disk but not in registry)
if [[ -d "$APP_DIR" ]]; then
    warn "Stale directory found at ${APP_DIR} — removing"
    rm -rf "$APP_DIR"
fi

# ─── Step 2: Assign slot ───
SLOT=$(next_slot)
info "Assigned slot: ${SLOT}"

# ─── Step 3: Clone or copy ───
if [[ -d "$REPO" ]]; then
    info "Copying from local path: ${REPO}"
    cp -r "$REPO" "$APP_DIR"
    # Init git if not already a repo (so update.sh can pull later)
    if [[ ! -d "${APP_DIR}/.git" ]]; then
        git -C "$APP_DIR" init -q
        git -C "$APP_DIR" add -A
        git -C "$APP_DIR" commit -q -m "Initial import from local path"
    fi
else
    CLONE_URL="$REPO"
    # For private repos: inject ACCESS_TOKEN into HTTPS URL if available
    if [[ -n "${ACCESS_TOKEN:-}" ]] && [[ "$CLONE_URL" == https://github.com/* ]]; then
        CLONE_URL="${CLONE_URL/https:\/\/github.com/https://${ACCESS_TOKEN}@github.com}"
    fi
    info "Cloning: ${REPO} (branch: ${GIT_BRANCH})"
    git clone --depth=1 --branch "$GIT_BRANCH" "$CLONE_URL" "$APP_DIR"
    # Store clean URL (without token) as remote
    if [[ "$CLONE_URL" != "$REPO" ]]; then
        git -C "$APP_DIR" remote set-url origin "$REPO"
    fi
fi

# Ensure files are accessible (runner may clone as root)
chmod -R a+rwX "$APP_DIR" 2>/dev/null || true

# Find the docker-compose.yml
ORIGINAL_COMPOSE=""
for candidate in "docker-compose.yml" "docker-compose.yaml" "compose.yml" "compose.yaml"; do
    if [[ -f "${APP_DIR}/${candidate}" ]]; then
        ORIGINAL_COMPOSE="${APP_DIR}/${candidate}"
        break
    fi
done

if [[ -z "$ORIGINAL_COMPOSE" ]]; then
    rm -rf "$APP_DIR"
    fatal "No docker-compose.yml found in repository."
fi

info "Found compose file: $(basename "$ORIGINAL_COMPOSE")"

# ─── Step 3b: Detect registry mode ───
REGISTRY=""
if [[ -f "${APP_DIR}/.apps-deploy.yml" ]] && command -v yq &>/dev/null; then
    REGISTRY=$(yq '.registry // ""' "${APP_DIR}/.apps-deploy.yml")
fi
USE_REGISTRY=$( [[ -n "$REGISTRY" ]] && echo true || echo false )
if [[ "$USE_REGISTRY" == "true" ]]; then
    info "Registry mode: images will be pulled from ${REGISTRY}"
fi

# ─── Step 4: Maven build (if Maven project, skip in registry mode) ───
if [[ "$USE_REGISTRY" != "true" ]]; then
    if [[ -f "${APP_DIR}/pom.xml" ]] || [[ -f "${APP_DIR}/services/common/pom.xml" ]]; then
        header "Maven Build"
        maven_build "$APP_DIR"
    else
        info "No Maven project detected — skipping build step"
    fi
fi

# ─── Step 5: Detect frontend ───
DETECTION=$(detect_frontend "$ORIGINAL_COMPOSE")
FRONTEND_SERVICE=$(echo "$DETECTION" | cut -d'|' -f1)
FRONTEND_PORT=$(echo "$DETECTION" | cut -d'|' -f2)

# ─── Step 6: Generate docker-compose.deploy.yml ───
info "Generating deployment compose file..."

# Start from original
cp "$ORIGINAL_COMPOSE" "$DEPLOY_COMPOSE"

# Rebind all ports to the app's dedicated IP (prevents host conflicts between apps)
# e.g. "8081:8081" becomes "192.168.x.201:8081:8081"
APP_IP=$(slot_to_ip "$SLOT")
if [[ "${IP_ALIAS_ENABLED:-false}" == "true" ]] && [[ -n "$APP_IP" ]]; then
    info "Rebinding all ports to ${APP_IP}..."
    for svc in $(yq -r '.services | keys | .[]' "$DEPLOY_COMPOSE"); do
        PORT_COUNT=$(yq -r ".services.\"${svc}\".ports | length" "$DEPLOY_COMPOSE" 2>/dev/null)
        if [[ "$PORT_COUNT" != "0" ]] && [[ "$PORT_COUNT" != "null" ]]; then
            for (( i=0; i<PORT_COUNT; i++ )); do
                PORT_ENTRY=$(yq -r ".services.\"${svc}\".ports[$i]" "$DEPLOY_COMPOSE")
                # Strip any existing IP binding and extract host:container ports
                CLEAN_PORT=$(echo "$PORT_ENTRY" | sed -E 's/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+://')
                yq -i ".services.\"${svc}\".ports[$i] = \"${APP_IP}:${CLEAN_PORT}\"" "$DEPLOY_COMPOSE"
            done
        fi
    done

    # Add port 80 mapping to frontend service if it doesn't already expose port 80
    # This ensures http://<app-ip>/ works regardless of the app's internal port
    if [[ "$FRONTEND_PORT" != "80" ]] && [[ -n "$FRONTEND_SERVICE" ]]; then
        local has_80
        has_80=$(yq -r ".services.\"${FRONTEND_SERVICE}\".ports[]? | select(test(\"(^|:)80(/|$)\"))" "$DEPLOY_COMPOSE" 2>/dev/null)
        if [[ -z "$has_80" ]]; then
            info "Adding port 80 → ${FRONTEND_PORT} mapping to ${FRONTEND_SERVICE}"
            yq -i ".services.\"${FRONTEND_SERVICE}\".ports = [\"${APP_IP}:80:${FRONTEND_PORT}\"] + .services.\"${FRONTEND_SERVICE}\".ports" "$DEPLOY_COMPOSE"
        fi
    fi
else
    # Fallback: strip all ports if IP aliases not enabled
    yq -i 'del(.services[].ports)' "$DEPLOY_COMPOSE"
fi

# Strip ALL container_name to let docker compose use project-prefixed naming
yq -i 'del(.services[].container_name)' "$DEPLOY_COMPOSE"

# Strip version field (deprecated, avoids warnings)
yq -i 'del(.version)' "$DEPLOY_COMPOSE"

# Add apps-proxy as external network at top level
yq -i ".networks.\"${PROXY_NETWORK}\" = {\"external\": true}" "$DEPLOY_COMPOSE"

# Connect frontend service to apps-proxy network
# First, ensure the service has a networks key
EXISTING_NETWORKS=$(yq -r ".services.\"${FRONTEND_SERVICE}\".networks // \"\"" "$DEPLOY_COMPOSE")
if [[ "$EXISTING_NETWORKS" == "" ]] || [[ "$EXISTING_NETWORKS" == "null" ]]; then
    # Service uses default network; explicitly add default + proxy
    yq -i ".services.\"${FRONTEND_SERVICE}\".networks = [\"default\", \"${PROXY_NETWORK}\"]" "$DEPLOY_COMPOSE"
elif [[ "$EXISTING_NETWORKS" == *"- "* ]] || [[ "$(yq -r ".services.\"${FRONTEND_SERVICE}\".networks | type" "$DEPLOY_COMPOSE")" == "!!seq" ]]; then
    # Already a list — append
    yq -i ".services.\"${FRONTEND_SERVICE}\".networks += [\"${PROXY_NETWORK}\"]" "$DEPLOY_COMPOSE"
else
    # It's a map — add proxy network as empty map entry
    yq -i ".services.\"${FRONTEND_SERVICE}\".networks.\"${PROXY_NETWORK}\" = {}" "$DEPLOY_COMPOSE"
fi

success "Generated: docker-compose.deploy.yml"

# ─── Step 6b: Inject Homepage auto-discovery labels ───
APP_IP=$(slot_to_ip "$SLOT")
info "Adding Homepage labels to frontend service..."
yq -i ".services.\"${FRONTEND_SERVICE}\".labels.\"homepage.group\" = \"Apps\"" "$DEPLOY_COMPOSE"
yq -i ".services.\"${FRONTEND_SERVICE}\".labels.\"homepage.name\" = \"${APP_NAME}\"" "$DEPLOY_COMPOSE"
yq -i ".services.\"${FRONTEND_SERVICE}\".labels.\"homepage.icon\" = \"docker\"" "$DEPLOY_COMPOSE"
yq -i ".services.\"${FRONTEND_SERVICE}\".labels.\"homepage.href\" = \"http://${APP_IP}\"" "$DEPLOY_COMPOSE"
yq -i ".services.\"${FRONTEND_SERVICE}\".labels.\"homepage.description\" = \"${APP_IP}\"" "$DEPLOY_COMPOSE"
yq -i ".services.\"${FRONTEND_SERVICE}\".labels.\"homepage.server\" = \"local\"" "$DEPLOY_COMPOSE"

# ─── Step 7: Handle .env and secrets ───
if [[ -f "${APP_DIR}/.env.example" ]] && [[ ! -f "${APP_DIR}/.env" ]]; then
    cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
    info "Created .env from .env.example (review and update as needed)"
fi

# Copy secret files from config/secrets/<app-name>/ if they exist
SECRETS_DIR="${APPS_ROOT}/config/secrets/${APP_NAME}"
if [[ -d "$SECRETS_DIR" ]] && [[ -n "$(ls -A "$SECRETS_DIR" 2>/dev/null)" ]]; then
    info "Copying secret files from ${SECRETS_DIR}..."
    cp "$SECRETS_DIR"/. "$APP_DIR"/ -a 2>/dev/null || true
    success "Secret files copied"
fi

# ─── Step 7b: Bake IMAGE_TAG into deploy compose (registry mode) ───
if [[ "$USE_REGISTRY" == "true" ]] && [[ -n "${IMAGE_TAG:-}" ]]; then
    info "Pinning IMAGE_TAG=${IMAGE_TAG} in deploy compose"
    sed -i "s/\${IMAGE_TAG:-latest}/${IMAGE_TAG}/g" "$DEPLOY_COMPOSE"
fi

# ─── Step 8: Start ───
if [[ "$USE_REGISTRY" == "true" ]]; then
    info "Pulling images from registry..."
    if ! docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" pull 2>&1 | while read -r line; do echo "  $line"; done; then
        rm -rf "$APP_DIR"
        fatal "Pull from registry failed. Deployment aborted."
    fi
    info "Starting containers..."
    docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" up -d --force-recreate --remove-orphans 2>&1 | while read -r line; do
        echo "  $line"
    done
else
    info "Building and starting containers..."
    docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" up -d --build --remove-orphans 2>&1 | while read -r line; do
        echo "  $line"
    done
fi

# ─── Step 8b: Start extra compose files (e.g. frontend) ───
for extra_compose in $(find "$APP_DIR" -path "*/frontend-deploy/docker-compose.yml" -o -path "*/frontend-deploy/compose.yml" 2>/dev/null); do
    info "Processing extra compose: ${extra_compose#${APP_DIR}/}"
    EXTRA_DEPLOY="${extra_compose%/*}/docker-compose.deploy.yml"
    cp "$extra_compose" "$EXTRA_DEPLOY"
    # Strip ports to avoid host conflicts
    yq -i 'del(.services[].ports)' "$EXTRA_DEPLOY"
    # Strip container_name to use project-prefixed naming
    yq -i 'del(.services[].container_name)' "$EXTRA_DEPLOY"
    yq -i 'del(.version)' "$EXTRA_DEPLOY"
    # Add apps-proxy network so NPM can reach it
    yq -i ".networks.\"${PROXY_NETWORK}\" = {\"external\": true}" "$EXTRA_DEPLOY"
    # Inject API_HOST so init-clone can patch env.js to use Traefik (same origin)
    if [[ -n "$APP_IP" ]]; then
        INIT_SVC=$(yq -r '.services | keys | .[]' "$EXTRA_DEPLOY" | grep init | head -1)
        if [[ -n "$INIT_SVC" ]]; then
            yq -i ".services.\"${INIT_SVC}\".environment += [\"API_HOST=${APP_IP}\"]" "$EXTRA_DEPLOY"
        fi
    fi
    # Connect the web-serving service (frontend/nginx) to apps-proxy
    EXTRA_SVC=$(yq -r '.services | keys | .[]' "$EXTRA_DEPLOY" | grep -v init | head -1)
    if [[ -n "$EXTRA_SVC" ]]; then
        yq -i ".services.\"${EXTRA_SVC}\".networks = [\"default\", \"${PROXY_NETWORK}\"]" "$EXTRA_DEPLOY"
        # Route frontend through Traefik (same origin as APIs — avoids CORS)
        yq -i ".services.\"${EXTRA_SVC}\".labels.\"traefik.enable\" = \"true\"" "$EXTRA_DEPLOY"
        yq -i '.services."'"${EXTRA_SVC}"'".labels."traefik.http.routers.frontend.rule" = "PathPrefix(`/`)"' "$EXTRA_DEPLOY"
        yq -i ".services.\"${EXTRA_SVC}\".labels.\"traefik.http.routers.frontend.entrypoints\" = \"web\"" "$EXTRA_DEPLOY"
        yq -i ".services.\"${EXTRA_SVC}\".labels.\"traefik.http.routers.frontend.priority\" = \"1\"" "$EXTRA_DEPLOY"
        yq -i ".services.\"${EXTRA_SVC}\".labels.\"traefik.http.services.frontend.loadbalancer.server.port\" = \"80\"" "$EXTRA_DEPLOY"
        yq -i ".services.\"${EXTRA_SVC}\".labels.\"traefik.docker.network\" = \"${PROXY_NETWORK}\"" "$EXTRA_DEPLOY"
    fi
    info "Starting: ${EXTRA_DEPLOY#${APP_DIR}/}"
    docker compose -f "$EXTRA_DEPLOY" -p "${APP_NAME}-frontend" up -d --remove-orphans 2>&1 | while read -r line; do
        echo "  $line"
    done
done

# ─── Step 9: Wait for frontend ───
info "Waiting for frontend to be ready..."
FRONTEND_CONTAINER="${APP_NAME}-${FRONTEND_SERVICE}-1"
RETRIES=30
for (( i=1; i<=RETRIES; i++ )); do
    STATUS=$(docker inspect -f '{{.State.Status}}' "$FRONTEND_CONTAINER" 2>/dev/null || echo "missing")
    if [[ "$STATUS" == "running" ]]; then
        success "Frontend container is running"
        break
    fi
    if [[ $i -eq $RETRIES ]]; then
        warn "Frontend container not ready after ${RETRIES}s. Continuing anyway."
    fi
    sleep 1
done

# ─── Step 10: Register NPM proxy ───
DOMAIN="${APP_NAME}.${DOMAIN_SUFFIX}"
NPM_HOST_ID=""

info "Registering NPM proxy: ${DOMAIN} → ${FRONTEND_CONTAINER}:${FRONTEND_PORT}"
NPM_HOST_ID=$(npm_create_proxy "$DOMAIN" "$FRONTEND_CONTAINER" "$FRONTEND_PORT") || true

if [[ -n "$NPM_HOST_ID" ]]; then
    success "NPM proxy host created (ID: ${NPM_HOST_ID})"
else
    warn "NPM registration failed. Register manually in NPM admin (port 81)."
    warn "  Domain: ${DOMAIN}"
    warn "  Forward: ${FRONTEND_CONTAINER}:${FRONTEND_PORT}"
    NPM_HOST_ID="manual"
fi

# ─── Step 10b: Assign dedicated IP ───
APP_IP=""
NPM_IP_HOST_ID=""
if [[ "${IP_ALIAS_ENABLED:-false}" == "true" ]]; then
    APP_IP=$(slot_to_ip "$SLOT")
    info "Assigning dedicated IP: ${APP_IP}"
    if add_ip_alias "$APP_IP"; then
        info "Creating NPM proxy: ${APP_IP} → ${FRONTEND_CONTAINER}:${FRONTEND_PORT}"
        NPM_IP_HOST_ID=$(create_ip_proxy "$APP_IP" "$FRONTEND_CONTAINER" "$FRONTEND_PORT") || true
        if [[ -n "$NPM_IP_HOST_ID" ]]; then
            success "IP proxy host created (ID: ${NPM_IP_HOST_ID})"
        else
            warn "IP proxy registration failed. App still accessible via ${DOMAIN}."
        fi
    else
        warn "Failed to assign IP ${APP_IP}. App still accessible via ${DOMAIN}."
    fi
fi

# ─── Step 11: Record in registry ───
echo "${APP_NAME}|${SLOT}|${REPO}|running|${NPM_HOST_ID}|${FRONTEND_SERVICE}|${FRONTEND_PORT}|${APP_IP}|${NPM_IP_HOST_ID}" >> "$APPS_CONF"
success "Registered in apps.conf"

# ─── Step 12: Summary ───
CONTAINER_COUNT=$(docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" ps -q | wc -l)

echo ""
header "Deployment Complete"
echo -e "  ${BOLD}App:${NC}        ${APP_NAME}"
echo -e "  ${BOLD}Slot:${NC}       ${SLOT}"
echo -e "  ${BOLD}Frontend:${NC}   ${FRONTEND_SERVICE}:${FRONTEND_PORT}"
echo -e "  ${BOLD}URL:${NC}        http://${DOMAIN}"
if [[ -n "$APP_IP" ]]; then
echo -e "  ${BOLD}IP:${NC}         http://${APP_IP}"
fi
echo -e "  ${BOLD}Containers:${NC} ${CONTAINER_COUNT}"
echo -e "  ${BOLD}Directory:${NC}  ${APP_DIR}"
echo ""
if [[ -n "$APP_IP" ]]; then
info "Access from any device on the network:"
echo "  http://${APP_IP}"
echo ""
fi
info "Or add to /etc/hosts for friendly URL:"
echo "  ${SERVER_IP}  ${DOMAIN}"
echo ""
info "Manage with:"
echo "  ./scripts/status.sh           # View all apps"
echo "  ./scripts/update.sh ${APP_NAME}   # Pull & rebuild"
echo "  ./scripts/logs.sh ${APP_NAME}     # View logs"
echo "  ./scripts/stop.sh ${APP_NAME}     # Stop"
echo "  ./scripts/remove.sh ${APP_NAME}   # Full cleanup"
