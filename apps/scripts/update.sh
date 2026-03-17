#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/detect-frontend.sh"
source "${SCRIPT_DIR}/lib/maven-build.sh"
source "${SCRIPT_DIR}/lib/ip-alias.sh"

# ─── Usage ───
[[ $# -lt 1 ]] && { echo "Usage: $0 <app-name>"; exit 1; }

APP_NAME="$1"

header "Updating: ${APP_NAME}"

require_app "$APP_NAME"
require_yq

APP_DIR=$(get_app_dir "$APP_NAME")
DEPLOY_COMPOSE=$(get_compose_file "$APP_NAME")

# ─── Detect registry mode ───
REGISTRY=""
if [[ -f "${APP_DIR}/.apps-deploy.yml" ]] && command -v yq &>/dev/null; then
    REGISTRY=$(yq '.registry // ""' "${APP_DIR}/.apps-deploy.yml")
fi
USE_REGISTRY=$( [[ -n "$REGISTRY" ]] && echo true || echo false )
if [[ "$USE_REGISTRY" == "true" ]]; then
    info "Registry mode: pulling images from ${REGISTRY}"
fi

# ─── Pull latest ───
# Allow git to operate on repos owned by a different user (e.g. runner container as root)
git config --global --add safe.directory "$APP_DIR" 2>/dev/null || true
if [[ -d "${APP_DIR}/.git" ]] && git -C "$APP_DIR" remote get-url origin &>/dev/null; then
    info "Pulling latest changes (branch: ${GIT_BRANCH})..."
    # For private repos: temporarily set token-authenticated URL for fetch
    if [[ -n "${ACCESS_TOKEN:-}" ]]; then
        ORIGIN_URL=$(git -C "$APP_DIR" remote get-url origin)
        if [[ "$ORIGIN_URL" == https://github.com/* ]]; then
            git -C "$APP_DIR" remote set-url origin "${ORIGIN_URL/https:\/\/github.com/https://${ACCESS_TOKEN}@github.com}"
        fi
    fi
    git -C "$APP_DIR" fetch origin "$GIT_BRANCH":"refs/remotes/origin/${GIT_BRANCH}" 2>&1 | while read -r line; do echo "  $line"; done
    git -C "$APP_DIR" reset --hard "origin/${GIT_BRANCH}" 2>&1 | while read -r line; do echo "  $line"; done
    # Restore clean URL (without token)
    if [[ -n "${ACCESS_TOKEN:-}" ]] && [[ -n "${ORIGIN_URL:-}" ]]; then
        git -C "$APP_DIR" remote set-url origin "$ORIGIN_URL"
    fi
elif [[ -d "${APP_DIR}/.git" ]]; then
    warn "Local repo with no remote — skipping pull"
else
    warn "Not a git repo — skipping pull"
fi

# ─── Maven build (if Maven project, skip in registry mode) ───
if [[ "$USE_REGISTRY" != "true" ]]; then
    if [[ -f "${APP_DIR}/pom.xml" ]] || [[ -f "${APP_DIR}/services/common/pom.xml" ]]; then
        header "Maven Build"
        maven_build "$APP_DIR"
    fi
fi

# ─── Find original compose ───
ORIGINAL_COMPOSE=""
for candidate in "docker-compose.yml" "docker-compose.yaml" "compose.yml" "compose.yaml"; do
    if [[ -f "${APP_DIR}/${candidate}" ]]; then
        ORIGINAL_COMPOSE="${APP_DIR}/${candidate}"
        break
    fi
done

[[ -z "$ORIGINAL_COMPOSE" ]] && fatal "No docker-compose.yml found in ${APP_DIR}"

# ─── Re-detect frontend ───
DETECTION=$(detect_frontend "$ORIGINAL_COMPOSE")
FRONTEND_SERVICE=$(echo "$DETECTION" | cut -d'|' -f1)
FRONTEND_PORT=$(echo "$DETECTION" | cut -d'|' -f2)

# ─── Backup existing deploy compose for rollback ───
[[ -f "$DEPLOY_COMPOSE" ]] && cp "$DEPLOY_COMPOSE" "${DEPLOY_COMPOSE}.rollback"

# ─── Regenerate deploy compose ───
info "Regenerating deployment compose..."
cp "$ORIGINAL_COMPOSE" "$DEPLOY_COMPOSE"

# Rebind all ports to the app's dedicated IP
SLOT=$(get_app_field "$APP_NAME" 2)
APP_IP=$(get_app_field "$APP_NAME" 8)
if [[ -z "$APP_IP" ]]; then
    APP_IP=$(slot_to_ip "$SLOT" 2>/dev/null || echo "")
fi
if [[ "${IP_ALIAS_ENABLED:-false}" == "true" ]] && [[ -n "$APP_IP" ]]; then
    info "Rebinding all ports to ${APP_IP}..."
    for svc in $(yq -r '.services | keys | .[]' "$DEPLOY_COMPOSE"); do
        PORT_COUNT=$(yq -r ".services.\"${svc}\".ports | length" "$DEPLOY_COMPOSE" 2>/dev/null)
        if [[ "$PORT_COUNT" != "0" ]] && [[ "$PORT_COUNT" != "null" ]]; then
            for (( i=0; i<PORT_COUNT; i++ )); do
                PORT_ENTRY=$(yq -r ".services.\"${svc}\".ports[$i]" "$DEPLOY_COMPOSE")
                CLEAN_PORT=$(echo "$PORT_ENTRY" | sed -E 's/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+://')
                yq -i ".services.\"${svc}\".ports[$i] = \"${APP_IP}:${CLEAN_PORT}\"" "$DEPLOY_COMPOSE"
            done
        fi
    done

    # Add port 80 mapping to frontend service if it doesn't already expose port 80
    if [[ "$FRONTEND_PORT" != "80" ]] && [[ -n "$FRONTEND_SERVICE" ]]; then
        has_80=$(yq -r ".services.\"${FRONTEND_SERVICE}\".ports[]? | select(test(\"(^|:)80(/|$)\"))" "$DEPLOY_COMPOSE" 2>/dev/null)
        if [[ -z "$has_80" ]]; then
            info "Adding port 80 → ${FRONTEND_PORT} mapping to ${FRONTEND_SERVICE}"
            yq -i ".services.\"${FRONTEND_SERVICE}\".ports = [\"${APP_IP}:80:${FRONTEND_PORT}\"] + .services.\"${FRONTEND_SERVICE}\".ports" "$DEPLOY_COMPOSE"
        fi
    fi
else
    yq -i 'del(.services[].ports)' "$DEPLOY_COMPOSE"
fi
yq -i 'del(.services[].container_name)' "$DEPLOY_COMPOSE"
yq -i 'del(.version)' "$DEPLOY_COMPOSE"
yq -i ".networks.\"${PROXY_NETWORK}\" = {\"external\": true}" "$DEPLOY_COMPOSE"

EXISTING_NETWORKS=$(yq -r ".services.\"${FRONTEND_SERVICE}\".networks // \"\"" "$DEPLOY_COMPOSE")
if [[ "$EXISTING_NETWORKS" == "" ]] || [[ "$EXISTING_NETWORKS" == "null" ]]; then
    yq -i ".services.\"${FRONTEND_SERVICE}\".networks = [\"default\", \"${PROXY_NETWORK}\"]" "$DEPLOY_COMPOSE"
elif [[ "$(yq -r ".services.\"${FRONTEND_SERVICE}\".networks | type" "$DEPLOY_COMPOSE")" == "!!seq" ]]; then
    yq -i ".services.\"${FRONTEND_SERVICE}\".networks += [\"${PROXY_NETWORK}\"]" "$DEPLOY_COMPOSE"
else
    yq -i ".services.\"${FRONTEND_SERVICE}\".networks.\"${PROXY_NETWORK}\" = {}" "$DEPLOY_COMPOSE"
fi

# ─── Inject Homepage labels ───
SLOT=$(get_app_field "$APP_NAME" 2)
APP_IP=$(get_app_field "$APP_NAME" 8)
if [[ -z "$APP_IP" ]]; then
    APP_IP=$(slot_to_ip "$SLOT" 2>/dev/null || echo "")
fi
if [[ -n "$APP_IP" ]]; then
    yq -i ".services.\"${FRONTEND_SERVICE}\".labels.\"homepage.group\" = \"Apps\"" "$DEPLOY_COMPOSE"
    yq -i ".services.\"${FRONTEND_SERVICE}\".labels.\"homepage.name\" = \"${APP_NAME}\"" "$DEPLOY_COMPOSE"
    yq -i ".services.\"${FRONTEND_SERVICE}\".labels.\"homepage.icon\" = \"docker\"" "$DEPLOY_COMPOSE"
    yq -i ".services.\"${FRONTEND_SERVICE}\".labels.\"homepage.href\" = \"http://${APP_IP}\"" "$DEPLOY_COMPOSE"
    yq -i ".services.\"${FRONTEND_SERVICE}\".labels.\"homepage.description\" = \"${APP_IP}\"" "$DEPLOY_COMPOSE"
    yq -i ".services.\"${FRONTEND_SERVICE}\".labels.\"homepage.server\" = \"local\"" "$DEPLOY_COMPOSE"
fi

# ─── Copy secrets ───
SECRETS_DIR="${APPS_ROOT}/config/secrets/${APP_NAME}"
if [[ -d "$SECRETS_DIR" ]] && [[ -n "$(ls -A "$SECRETS_DIR" 2>/dev/null)" ]]; then
    info "Copying secret files from ${SECRETS_DIR}..."
    cp "$SECRETS_DIR"/. "$APP_DIR"/ -a 2>/dev/null || true
    success "Secret files copied"
fi

# ─── Bake IMAGE_TAG into deploy compose (registry mode) ───
if [[ "$USE_REGISTRY" == "true" ]] && [[ -n "${IMAGE_TAG:-}" ]]; then
    info "Pinning IMAGE_TAG=${IMAGE_TAG} in deploy compose"
    sed -i "s/\${IMAGE_TAG:-latest}/${IMAGE_TAG}/g" "$DEPLOY_COMPOSE"
fi

# ─── Safe deploy: build/pull → swap → health-check → rollback on failure ───

# Tag current images for rollback (skip in registry mode — GHCR has all versions)
if [[ "$USE_REGISTRY" != "true" ]]; then
    for svc in $(docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" ps --services 2>/dev/null); do
        docker tag "${APP_NAME}-${svc}" "${APP_NAME}-${svc}:rollback" 2>/dev/null || true
    done
fi

# Build or pull images — running containers are untouched
if [[ "$USE_REGISTRY" == "true" ]]; then
    info "Pulling images from registry..."
    if ! docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" pull 2>&1 | while read -r line; do echo "  $line"; done; then
        warn "Pull failed — restoring previous compose and aborting"
        if [[ -f "${DEPLOY_COMPOSE}.rollback" ]]; then
            cp "${DEPLOY_COMPOSE}.rollback" "$DEPLOY_COMPOSE"
        fi
        rm -f "${DEPLOY_COMPOSE}.rollback"
        fatal "Pull failed. Running containers were NOT affected."
    fi
else
    info "Building images..."
    if ! docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" build 2>&1 | while read -r line; do echo "  $line"; done; then
        warn "Build failed — restoring previous compose and aborting"
        if [[ -f "${DEPLOY_COMPOSE}.rollback" ]]; then
            cp "${DEPLOY_COMPOSE}.rollback" "$DEPLOY_COMPOSE"
        fi
        rm -f "${DEPLOY_COMPOSE}.rollback"
        fatal "Build failed. Running containers were NOT affected."
    fi
fi

# ─── Clean deploy: wipe volumes if requested (e.g. Flyway migration changes) ───
if [[ "${CLEAN_DEPLOY:-false}" == "true" ]]; then
    warn "CLEAN_DEPLOY requested — wiping all volumes (fresh database, fresh state)"
    docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" down -v --remove-orphans 2>&1 | while read -r line; do echo "  $line"; done
    success "Volumes wiped — Flyway will run all migrations from scratch"
fi

# Deploy new images (--force-recreate ensures stale containers pick up new port bindings)
info "Deploying new containers..."
docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" up -d --force-recreate --remove-orphans 2>&1 | while read -r line; do
    echo "  $line"
done || true

# Health check — wait then verify containers are stable
info "Waiting for containers to stabilise..."
sleep 60

HEALTH_OK=true
# Use 'config --services' to check ALL expected services, not just running ones
for svc in $(docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" config --services 2>/dev/null); do
    CONTAINER_ID=$(docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" ps -a -q "$svc" 2>/dev/null)
    [[ -z "$CONTAINER_ID" ]] && { warn "Service ${svc} has no container"; HEALTH_OK=false; continue; }

    STATE=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_ID" 2>/dev/null)
    RESTARTS=$(docker inspect --format '{{.RestartCount}}' "$CONTAINER_ID" 2>/dev/null)
    RESTART_POLICY=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER_ID" 2>/dev/null)

    # Skip one-shot init containers (restart: "no") — if a critical init fails,
    # its dependent services won't start and will be caught by the "not running" check below
    if [[ "$RESTART_POLICY" == "no" ]] && [[ "$STATE" == "exited" ]]; then
        EXIT_CODE=$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER_ID" 2>/dev/null)
        if [[ "${EXIT_CODE:-1}" -ne 0 ]]; then
            warn "Init service ${svc} exited with code ${EXIT_CODE} (non-critical)"
        fi
        continue
    fi

    if [[ "$STATE" != "running" ]]; then
        warn "Service ${svc} is ${STATE} (expected running)"
        HEALTH_OK=false
    elif [[ "${RESTARTS:-0}" -gt 5 ]]; then
        warn "Service ${svc} has restarted ${RESTARTS} times (crash-looping)"
        HEALTH_OK=false
    fi
done

# ─── HTTP smoke test — verify the site is actually reachable ───
if [[ "$HEALTH_OK" == "true" ]] && [[ "${IP_ALIAS_ENABLED:-false}" == "true" ]] && [[ -n "$APP_IP" ]]; then
    info "Running HTTP smoke test on http://${APP_IP}..."
    # Allow extra time for Traefik/Sablier to settle
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "http://${APP_IP}/" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "000" ]]; then
        warn "HTTP smoke test FAILED — connection refused on http://${APP_IP}/"
        HEALTH_OK=false
    elif [[ "$HTTP_CODE" == "502" ]] || [[ "$HTTP_CODE" == "503" ]]; then
        warn "HTTP smoke test FAILED — got HTTP ${HTTP_CODE} on http://${APP_IP}:${FRONTEND_PORT:-80}/ (bad gateway / service unavailable)"
        HEALTH_OK=false
    else
        success "HTTP smoke test passed (HTTP ${HTTP_CODE})"
    fi
fi

if [[ "$HEALTH_OK" != "true" ]]; then
    warn "Health check failed — rolling back"
    docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" down 2>&1 | while read -r line; do echo "  $line"; done

    if [[ -f "${DEPLOY_COMPOSE}.rollback" ]]; then
        cp "${DEPLOY_COMPOSE}.rollback" "$DEPLOY_COMPOSE"
    fi

    if [[ "$USE_REGISTRY" != "true" ]]; then
        for svc in $(docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" ps --services 2>/dev/null || true); do
            docker tag "${APP_NAME}-${svc}:rollback" "${APP_NAME}-${svc}:latest" 2>/dev/null || true
        done
    fi

    docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" up -d --force-recreate --remove-orphans 2>&1 | while read -r line; do echo "  $line"; done || true
    rm -f "${DEPLOY_COMPOSE}.rollback"
    fatal "Deployment rolled back. Previous containers restored."
fi

# Cleanup rollback artifacts on success
if [[ "$USE_REGISTRY" != "true" ]]; then
    for svc in $(docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" ps --services 2>/dev/null); do
        docker rmi "${APP_NAME}-${svc}:rollback" 2>/dev/null || true
    done
fi
rm -f "${DEPLOY_COMPOSE}.rollback"
success "Deployment healthy"

# ─── Restart extra compose files (e.g. frontend) ───
for extra_compose in $(find "$APP_DIR" -path "*/frontend-deploy/docker-compose.yml" -o -path "*/frontend-deploy/compose.yml" 2>/dev/null); do
    info "Processing extra compose: ${extra_compose#${APP_DIR}/}"
    EXTRA_DEPLOY="${extra_compose%/*}/docker-compose.deploy.yml"
    [[ -f "$EXTRA_DEPLOY" ]] && cp "$EXTRA_DEPLOY" "${EXTRA_DEPLOY}.rollback"
    cp "$extra_compose" "$EXTRA_DEPLOY"
    yq -i 'del(.services[].ports)' "$EXTRA_DEPLOY"
    yq -i 'del(.services[].container_name)' "$EXTRA_DEPLOY"
    yq -i 'del(.version)' "$EXTRA_DEPLOY"
    yq -i ".networks.\"${PROXY_NETWORK}\" = {\"external\": true}" "$EXTRA_DEPLOY"
    # Inject API_HOST so init-clone can patch env.js to use Traefik (same origin)
    if [[ -n "$APP_IP" ]]; then
        INIT_SVC=$(yq -r '.services | keys | .[]' "$EXTRA_DEPLOY" | grep init | head -1)
        if [[ -n "$INIT_SVC" ]]; then
            yq -i ".services.\"${INIT_SVC}\".environment += [\"API_HOST=${APP_IP}\"]" "$EXTRA_DEPLOY"
        fi
    fi
    EXTRA_SVC=$(yq -r '.services | keys | .[]' "$EXTRA_DEPLOY" | grep -v init | head -1)
    if [[ -n "$EXTRA_SVC" ]]; then
        yq -i ".services.\"${EXTRA_SVC}\".networks = [\"default\", \"${PROXY_NETWORK}\"]" "$EXTRA_DEPLOY"
    fi
    # Tag current extra frontend images for rollback
    for svc in $(docker compose -f "$EXTRA_DEPLOY" -p "${APP_NAME}-frontend" ps --services 2>/dev/null); do
        docker tag "${APP_NAME}-frontend-${svc}" "${APP_NAME}-frontend-${svc}:rollback" 2>/dev/null || true
    done

    # Build extra frontend images only
    info "Building extra frontend: ${EXTRA_DEPLOY#${APP_DIR}/}"
    if ! docker compose -f "$EXTRA_DEPLOY" -p "${APP_NAME}-frontend" build 2>&1 | while read -r line; do echo "  $line"; done; then
        warn "Extra frontend build failed — skipping"
        if [[ -f "${EXTRA_DEPLOY}.rollback" ]]; then
            cp "${EXTRA_DEPLOY}.rollback" "$EXTRA_DEPLOY"
        fi
        rm -f "${EXTRA_DEPLOY}.rollback"
        continue
    fi

    # Deploy extra frontend
    info "Deploying extra frontend: ${EXTRA_DEPLOY#${APP_DIR}/}"
    docker compose -f "$EXTRA_DEPLOY" -p "${APP_NAME}-frontend" up -d --force-recreate 2>&1 | while read -r line; do
        echo "  $line"
    done || true

    # Health check for extra frontend
    info "Waiting for extra frontend to stabilise..."
    sleep 30

    EXTRA_HEALTH_OK=true
    for svc in $(docker compose -f "$EXTRA_DEPLOY" -p "${APP_NAME}-frontend" config --services 2>/dev/null); do
        CONTAINER_ID=$(docker compose -f "$EXTRA_DEPLOY" -p "${APP_NAME}-frontend" ps -a -q "$svc" 2>/dev/null)
        [[ -z "$CONTAINER_ID" ]] && { warn "Extra frontend service ${svc} has no container"; EXTRA_HEALTH_OK=false; continue; }

        STATE=$(docker inspect --format '{{.State.Status}}' "$CONTAINER_ID" 2>/dev/null)
        RESTARTS=$(docker inspect --format '{{.RestartCount}}' "$CONTAINER_ID" 2>/dev/null)
        RESTART_POLICY=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER_ID" 2>/dev/null)

        if [[ "$RESTART_POLICY" == "no" ]] && [[ "$STATE" == "exited" ]]; then
            EXIT_CODE=$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER_ID" 2>/dev/null)
            if [[ "${EXIT_CODE:-1}" -ne 0 ]]; then
                warn "Extra frontend init service ${svc} exited with code ${EXIT_CODE} (non-critical)"
            fi
            continue
        fi

        if [[ "$STATE" != "running" ]]; then
            warn "Extra frontend service ${svc} is ${STATE} (expected running)"
            EXTRA_HEALTH_OK=false
        elif [[ "${RESTARTS:-0}" -gt 2 ]]; then
            warn "Extra frontend service ${svc} has restarted ${RESTARTS} times (crash-looping)"
            EXTRA_HEALTH_OK=false
        fi
    done

    if [[ "$EXTRA_HEALTH_OK" != "true" ]]; then
        warn "Extra frontend health check failed — rolling back"
        docker compose -f "$EXTRA_DEPLOY" -p "${APP_NAME}-frontend" down 2>&1 | while read -r line; do echo "  $line"; done

        if [[ -f "${EXTRA_DEPLOY}.rollback" ]]; then
            cp "${EXTRA_DEPLOY}.rollback" "$EXTRA_DEPLOY"
        fi

        for svc in $(docker compose -f "$EXTRA_DEPLOY" -p "${APP_NAME}-frontend" ps --services 2>/dev/null || true); do
            docker tag "${APP_NAME}-frontend-${svc}:rollback" "${APP_NAME}-frontend-${svc}:latest" 2>/dev/null || true
        done

        docker compose -f "$EXTRA_DEPLOY" -p "${APP_NAME}-frontend" up -d --force-recreate 2>&1 | while read -r line; do echo "  $line"; done || true
        rm -f "${EXTRA_DEPLOY}.rollback"
        warn "Extra frontend rolled back to previous version"
        continue
    fi

    # Cleanup extra frontend rollback artifacts
    for svc in $(docker compose -f "$EXTRA_DEPLOY" -p "${APP_NAME}-frontend" ps --services 2>/dev/null); do
        docker rmi "${APP_NAME}-frontend-${svc}:rollback" 2>/dev/null || true
    done
    rm -f "${EXTRA_DEPLOY}.rollback"
    success "Extra frontend deployment healthy"
done

# ─── Update registry ───
update_app_field "$APP_NAME" 4 "running"
update_app_field "$APP_NAME" 6 "$FRONTEND_SERVICE"
update_app_field "$APP_NAME" 7 "$FRONTEND_PORT"

CONTAINER_COUNT=$(docker compose -f "$DEPLOY_COMPOSE" -p "$APP_NAME" ps -q | wc -l)
success "Update complete — ${CONTAINER_COUNT} container(s) running"
