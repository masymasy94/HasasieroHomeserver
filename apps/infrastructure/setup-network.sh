#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(dirname "$SCRIPT_DIR")"
source "${APPS_ROOT}/scripts/lib/common.sh"

# ─── Install yq if not present ───
install_yq() {
    if command -v yq &>/dev/null; then
        info "yq already installed: $(yq --version)"
        return 0
    fi

    info "Installing yq..."
    YQ_VERSION="v4.44.1"
    YQ_BINARY="yq_linux_amd64"
    mkdir -p "${HOME}/bin"
    wget -qO "${HOME}/bin/yq" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}"
    chmod +x "${HOME}/bin/yq"
    export PATH="${HOME}/bin:${PATH}"
    success "yq installed: $(yq --version)"
}

# ─── Create apps-proxy bridge network ───
create_proxy_network() {
    if docker network inspect "$PROXY_NETWORK" &>/dev/null; then
        info "Network '${PROXY_NETWORK}' already exists"
    else
        info "Creating network '${PROXY_NETWORK}'..."
        docker network create "$PROXY_NETWORK"
        success "Network '${PROXY_NETWORK}' created"
    fi
}

# ─── Connect NPM container to apps-proxy ───
connect_npm() {
    if docker inspect "$NPM_CONTAINER" &>/dev/null; then
        if docker inspect "$NPM_CONTAINER" --format='{{range $net, $_ := .NetworkSettings.Networks}}{{$net}} {{end}}' | grep -q "$PROXY_NETWORK"; then
            info "NPM already connected to '${PROXY_NETWORK}'"
        else
            info "Connecting NPM to '${PROXY_NETWORK}'..."
            docker network connect "$PROXY_NETWORK" "$NPM_CONTAINER"
            success "NPM connected to '${PROXY_NETWORK}'"
        fi
    else
        warn "NPM container '${NPM_CONTAINER}' not found. Is the homeserver stack running?"
        warn "Connect it later with: docker network connect ${PROXY_NETWORK} ${NPM_CONTAINER}"
    fi
}

# ─── Create macvlan network (future, Ethernet only) ───
create_macvlan() {
    if [[ "$NETWORK_MODE" != "macvlan" ]]; then
        info "Skipping macvlan setup (NETWORK_MODE=${NETWORK_MODE})"
        return 0
    fi

    # Check if interface is up
    if ! ip link show "$MACVLAN_INTERFACE" up &>/dev/null; then
        warn "Interface '${MACVLAN_INTERFACE}' is DOWN. Skipping macvlan creation."
        warn "Connect Ethernet cable and re-run this script."
        return 0
    fi

    if docker network inspect "$MACVLAN_NETWORK" &>/dev/null; then
        info "Macvlan network '${MACVLAN_NETWORK}' already exists"
    else
        info "Creating macvlan network '${MACVLAN_NETWORK}'..."
        docker network create -d macvlan \
            --subnet="$MACVLAN_SUBNET" \
            --gateway="$MACVLAN_GATEWAY" \
            --ip-range="$MACVLAN_IP_RANGE" \
            -o parent="$MACVLAN_INTERFACE" \
            "$MACVLAN_NETWORK"
        success "Macvlan network '${MACVLAN_NETWORK}' created"
    fi
}

# ─── Create deployments directory ───
create_dirs() {
    mkdir -p "$DEPLOYMENTS_DIR"
    info "Deployments directory ready: ${DEPLOYMENTS_DIR}"
}

# ─── Main ───
header "Apps Infrastructure Setup"

install_yq
create_proxy_network
connect_npm
create_macvlan
create_dirs

echo ""
success "Setup complete!"
info "Next steps:"
echo "  1. Start infrastructure: docker compose -f ${APPS_ROOT}/infrastructure/docker-compose.yml up -d registry"
echo "  2. Deploy an app:        ${APPS_ROOT}/scripts/deploy.sh <repo-url> <app-name>"
