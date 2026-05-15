# cloudflared

Cloudflare Tunnel connector. Serves:

- `hasasierofy.fyi` → `http://192.168.3.201:8000` (hasasierofy api)
- `hasasiero-jellyfin.fyi` → `http://192.168.3.54:8096` (jellyfin)

## Files (tracked)

- `config.yml` — tunnel ID + ingress rules
- `README.md` — this file

## Files (NOT tracked, must be provisioned on each host)

- `<tunnel-id>.json` — tunnel credentials, downloaded once via `cloudflared tunnel create` / `cloudflared login`
- `cert.pem` — origin cert from `cloudflared login`

Both live under `~/.cloudflared/` after a `cloudflared login` + `tunnel create`. Copy them into this directory (mode 644 is OK — folder perms protect them) before `docker compose up -d cloudflared`.

## Notes

- Service uses `network_mode: host` so it can reach the LAN-bound origins (192.168.3.x) directly.
- Watchtower is enabled — cloudflared updates daily.
