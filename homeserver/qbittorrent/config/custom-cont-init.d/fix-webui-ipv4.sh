#!/bin/bash
# Force qBittorrent WebUI to bind on IPv4 (0.0.0.0) instead of IPv6-only.
# Without this, Docker port mapping (IPv4) can't reach the WebUI.

CONF="/config/qBittorrent/qBittorrent.conf"

if [ -f "$CONF" ]; then
    sed -i 's/^WebUI\\Address=.*/WebUI\\Address=0.0.0.0/' "$CONF"
    echo "WebUI address set to 0.0.0.0 (IPv4)"
fi
