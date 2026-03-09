#!/usr/bin/env bash
# IP alias management — assigns dedicated LAN IPs to apps via active network interface
# Requires common.sh to be sourced first (for IP_ALIAS_* settings)

# Detect the active NetworkManager connection and interface (default route)
_detect_active_connection() {
    # Find the interface carrying the default route
    IP_ALIAS_INTERFACE=$(nmcli -t -f DEVICE route get 1.1.1.1 2>/dev/null | head -1)
    if [[ -z "$IP_ALIAS_INTERFACE" ]]; then
        IP_ALIAS_INTERFACE=$(ip route show default | awk '{print $5; exit}')
    fi

    # Resolve the NM connection name for that interface
    NM_CONNECTION=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
        | awk -F: -v dev="$IP_ALIAS_INTERFACE" '$2 == dev {print $1; exit}')

    if [[ -z "$IP_ALIAS_INTERFACE" || -z "$NM_CONNECTION" ]]; then
        error "Could not detect active network interface/connection"
        return 1
    fi
}

# Calculate IP from slot number: slot 1 → base IP, slot 2 → base+1, etc.
slot_to_ip() {
    local slot="$1"
    local base_octets
    IFS='.' read -r o1 o2 o3 o4 <<< "$IP_ALIAS_BASE"
    local ip_last=$(( o4 + slot - 1 ))
    if (( ip_last > 254 )); then
        error "IP alias overflow: slot ${slot} would give .${ip_last}"
        return 1
    fi
    echo "${o1}.${o2}.${o3}.${ip_last}"
}

# Add an IP alias to the active network interface (persistent via NetworkManager)
add_ip_alias() {
    local ip="$1"
    local mask="${IP_ALIAS_NETMASK:-24}"

    _detect_active_connection || return 1

    # Check if already assigned
    if ip addr show "${IP_ALIAS_INTERFACE}" 2>/dev/null | grep -q "inet ${ip}/"; then
        info "IP ${ip} already assigned to ${IP_ALIAS_INTERFACE}"
        return 0
    fi

    # Add to NetworkManager connection (persistent across reboots)
    nmcli connection modify "${NM_CONNECTION}" +ipv4.addresses "${ip}/${mask}" 2>/dev/null || {
        error "Failed to add ${ip} to NetworkManager connection '${NM_CONNECTION}'"
        return 1
    }

    # Apply immediately
    nmcli connection up "${NM_CONNECTION}" 2>/dev/null || {
        error "Failed to reactivate connection '${NM_CONNECTION}' after adding ${ip}"
        return 1
    }

    # Verify
    if ip addr show "${IP_ALIAS_INTERFACE}" 2>/dev/null | grep -q "inet ${ip}/"; then
        success "IP alias ${ip} added to ${IP_ALIAS_INTERFACE} (connection: ${NM_CONNECTION})"
    else
        error "IP ${ip} not found on ${IP_ALIAS_INTERFACE} after applying"
        return 1
    fi
}

# Remove an IP alias from the active network interface
remove_ip_alias() {
    local ip="$1"
    local mask="${IP_ALIAS_NETMASK:-24}"

    _detect_active_connection || return 1

    # Remove from NetworkManager connection
    nmcli connection modify "${NM_CONNECTION}" -ipv4.addresses "${ip}/${mask}" 2>/dev/null || {
        warn "Failed to remove ${ip} from NetworkManager connection '${NM_CONNECTION}'"
        return 1
    }

    # Apply
    nmcli connection up "${NM_CONNECTION}" 2>/dev/null || true

    info "IP alias ${ip} removed from ${IP_ALIAS_INTERFACE} (connection: ${NM_CONNECTION})"
}

# Create NPM proxy host for an IP address → container
create_ip_proxy() {
    local ip="$1"
    local forward_host="$2"
    local forward_port="${3:-80}"

    local host_id
    host_id=$(npm_create_proxy "$ip" "$forward_host" "$forward_port") || return 1
    echo "$host_id"
}
