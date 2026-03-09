#!/usr/bin/env bash
# NPM (Nginx Proxy Manager) API functions

# Requires common.sh to be sourced first (for NPM_API_URL, NPM_API_EMAIL, etc.)

NPM_TOKEN=""

npm_login() {
    local response
    response=$(curl -s -X POST "${NPM_API_URL}/tokens" \
        -H "Content-Type: application/json" \
        -d "{\"identity\":\"${NPM_API_EMAIL}\",\"secret\":\"${NPM_API_PASSWORD}\"}")

    NPM_TOKEN=$(echo "$response" | jq -r '.token // empty')
    if [[ -z "$NPM_TOKEN" ]]; then
        error "NPM login failed. Response: ${response}"
        error "Check NPM_API_EMAIL and NPM_API_PASSWORD in config/settings.conf"
        return 1
    fi
}

npm_auth_header() {
    echo "Authorization: Bearer ${NPM_TOKEN}"
}

npm_create_proxy() {
    local domain="$1"
    local forward_host="$2"
    local forward_port="${3:-80}"

    if [[ -z "$NPM_TOKEN" ]]; then
        npm_login || return 1
    fi

    local payload
    payload=$(cat <<ENDJSON
{
    "domain_names": ["${domain}"],
    "forward_scheme": "http",
    "forward_host": "${forward_host}",
    "forward_port": ${forward_port},
    "access_list_id": 0,
    "certificate_id": 0,
    "ssl_forced": false,
    "caching_enabled": false,
    "block_exploits": false,
    "advanced_config": "",
    "allow_websocket_upgrade": true,
    "http2_support": false,
    "hsts_enabled": false,
    "hsts_subdomains": false,
    "meta": {
        "managed_by": "apps-deploy",
        "app_name": "${domain%%.*}"
    }
}
ENDJSON
)

    local response
    response=$(curl -s -X POST "${NPM_API_URL}/nginx/proxy-hosts" \
        -H "$(npm_auth_header)" \
        -H "Content-Type: application/json" \
        -d "$payload")

    local host_id
    host_id=$(echo "$response" | jq -r '.id // empty')
    if [[ -z "$host_id" ]]; then
        error "Failed to create NPM proxy host. Response: ${response}"
        return 1
    fi

    echo "$host_id"
}

npm_delete_proxy() {
    local host_id="$1"

    if [[ -z "$NPM_TOKEN" ]]; then
        npm_login || return 1
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
        "${NPM_API_URL}/nginx/proxy-hosts/${host_id}" \
        -H "$(npm_auth_header)")

    if [[ "$http_code" != "200" ]]; then
        warn "Failed to delete NPM proxy host ${host_id} (HTTP ${http_code})"
        return 1
    fi
}

npm_find_proxy() {
    local domain="$1"

    if [[ -z "$NPM_TOKEN" ]]; then
        npm_login || return 1
    fi

    local response
    response=$(curl -s -X GET "${NPM_API_URL}/nginx/proxy-hosts" \
        -H "$(npm_auth_header)")

    echo "$response" | jq -r ".[] | select(.domain_names[] == \"${domain}\") | .id // empty"
}
