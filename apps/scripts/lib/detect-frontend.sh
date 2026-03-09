#!/usr/bin/env bash
# Auto-detect frontend service and port from a docker-compose.yml

# Requires common.sh to be sourced first (for require_yq, info, etc.)

detect_frontend() {
    local compose_file="$1"
    local app_dir="$(dirname "$compose_file")"

    local frontend_service=""
    local frontend_port="80"

    # Priority 1: Check for .apps-deploy.yml override in the repo
    if [[ -f "${app_dir}/.apps-deploy.yml" ]]; then
        local override_service override_port
        override_service=$(yq '.frontend_service // ""' "${app_dir}/.apps-deploy.yml")
        override_port=$(yq '.frontend_port // ""' "${app_dir}/.apps-deploy.yml")

        if [[ -n "$override_service" ]]; then
            frontend_service="$override_service"
            [[ -n "$override_port" ]] && frontend_port="$override_port"
            info "Frontend from .apps-deploy.yml: ${frontend_service}:${frontend_port}" >&2
            echo "${frontend_service}|${frontend_port}"
            return 0
        fi
    fi

    # Priority 2: Find service that exposes port 80 or 443
    # Use word-boundary regex to avoid matching 8000 as "80"
    local services_with_80
    services_with_80=$(yq -r '.services | to_entries[] | select(.value.ports[]? | test("(^|:)80(/|$)")) | .key' "$compose_file" 2>/dev/null | head -1)
    if [[ -n "$services_with_80" ]]; then
        frontend_service="$services_with_80"
        frontend_port="80"
        info "Frontend detected (port 80): ${frontend_service}:${frontend_port}" >&2
        echo "${frontend_service}|${frontend_port}"
        return 0
    fi

    local services_with_443
    services_with_443=$(yq -r '.services | to_entries[] | select(.value.ports[]? | test("(^|:)443(/|$)")) | .key' "$compose_file" 2>/dev/null | head -1)
    if [[ -n "$services_with_443" ]]; then
        frontend_service="$services_with_443"
        frontend_port="443"
        info "Frontend detected (port 443): ${frontend_service}:${frontend_port}" >&2
        echo "${frontend_service}|${frontend_port}"
        return 0
    fi

    # Priority 3: Match common frontend service names
    local known_names=("traefik" "nginx" "gateway" "frontend" "web" "proxy" "caddy" "httpd" "app")
    local all_services
    all_services=$(yq -r '.services | keys | .[]' "$compose_file")

    for name in "${known_names[@]}"; do
        if echo "$all_services" | grep -qix "$name"; then
            frontend_service=$(echo "$all_services" | grep -ix "$name" | head -1)
            # Try to extract the internal port from the ports mapping
            local mapped_port
            mapped_port=$(yq -r ".services.\"${frontend_service}\".ports[0] // \"\"" "$compose_file" 2>/dev/null)
            if [[ -n "$mapped_port" ]]; then
                # Extract container port from "host:container" or just "port"
                frontend_port=$(echo "$mapped_port" | sed 's/.*://' | sed 's/\/.*//')
            fi
            info "Frontend detected (name match '${name}'): ${frontend_service}:${frontend_port}" >&2
            echo "${frontend_service}|${frontend_port}"
            return 0
        fi
    done

    # Priority 4: First service in the file
    frontend_service=$(echo "$all_services" | head -1)
    if [[ -n "$frontend_service" ]]; then
        local mapped_port
        mapped_port=$(yq -r ".services.\"${frontend_service}\".ports[0] // \"\"" "$compose_file" 2>/dev/null)
        if [[ -n "$mapped_port" ]]; then
            frontend_port=$(echo "$mapped_port" | sed 's/.*://' | sed 's/\/.*//')
        fi
        warn "No obvious frontend found. Using first service: ${frontend_service}:${frontend_port}" >&2
        echo "${frontend_service}|${frontend_port}"
        return 0
    fi

    error "No services found in ${compose_file}" >&2
    return 1
}
