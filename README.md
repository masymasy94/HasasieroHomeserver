# Hasasiero Homeserver

![Docker](https://img.shields.io/badge/Docker_Compose-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![Self-Hosted](https://img.shields.io/badge/Self--Hosted-333?style=for-the-badge&logo=homebridge&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)

Docker-based homeserver running 20+ self-hosted services and a multi-app deployment platform. Everything is managed through Docker Compose on a single machine (`192.168.3.54`).

## Repository Structure

```
.
├── homeserver/          # Core services stack (media, AI, VPN, monitoring, ...)
│   ├── docker-compose.yml
│   ├── homepage/config/
│   ├── prowlarr-search/
│   ├── telegram-ollama-bot/
│   ├── github-runner/
│   └── ...
│
└── apps/                # Multi-app deployment platform
    ├── scripts/         # deploy, update, start, stop, remove, status, logs
    ├── infrastructure/  # GitHub runner, network setup
    ├── templates/       # Example compose & workflow files
    ├── config/          # App registry & settings
    ├── deployments/     # Cloned app repos (gitignored)
    └── homepage/config/
```

---

## Homeserver Stack

A single `docker-compose.yml` running all core services.

### Services

| Category | Service | Port | Description |
|----------|---------|------|-------------|
| **Media** | Plex | `32400` | Media server (NAS) |
| | Prowlarr | `9696` | Indexer manager (VPN-routed) |
| | Prowlarr Search | `8888` | Custom torrent search UI |
| | Jackett | `9117` | Torrent indexer proxy |
| | qBittorrent | `8099` | Torrent client (VPN-routed) |
| **AI** | Ollama | `11434` | LLM inference (NVIDIA GPU) |
| | Open WebUI | `8080` | Chat interface for Ollama |
| | Telegram Bot | — | Telegram interface for Ollama |
| **Smart Home** | Home Assistant | `8123` | Home automation |
| **DNS** | AdGuard Home | `53` `853` `3053` | Network-wide DNS + ad blocker |
| **VPN** | Gluetun | `9696` `8191` `8099` `6881` | NordVPN WireGuard gateway |
| | FlareSolverr | `8191` | Cloudflare bypass (VPN-routed) |
| **Infra** | Homepage | `3000` | Central dashboard |
| | Nginx Proxy Manager | `80` `443` `81` | Reverse proxy + SSL |
| | Portainer | `9000` | Container management |
| | Uptime Kuma | `3001` | Service monitoring |
| | Glances | `61208` | System monitor |
| | Registry | `5000` | Local Docker registry |
| | GitHub Runner | — | Multi-repo Actions runner |
| | Watchtower | — | Auto image updates (daily 04:00) |
| **Gaming** | NUT | `9090` | Nintendo Switch installer |

### Network Architecture

```
HOST (192.168.3.54)
│
├── Host Network
│   ├── Plex (32400)
│   ├── Home Assistant (8123)
│   └── GitHub Runner
│
├── home-net (bridge)
│   ├── Portainer, Homepage, Uptime Kuma, Glances
│   ├── Nginx Proxy Manager (80, 443, 81)
│   ├── AdGuard Home (53, 853, 3053)
│   ├── Ollama → Open WebUI, Telegram Bot
│   ├── Jackett, Prowlarr Search, NUT, Registry
│   │
│   └── Gluetun VPN (NordVPN WireGuard)
│       ├── Prowlarr (9696)
│       ├── FlareSolverr (8191)
│       └── qBittorrent (8099)
│
└── Watchtower
```

### Setup

```bash
cd homeserver/
cp .env.example .env   # Fill in secrets (VPN key, Telegram token, GitHub PAT)
docker compose up -d
docker compose --profile runner up -d   # Optional: GitHub runner
```

Open the dashboard at `http://192.168.3.54:3000`

---

## Apps Platform

Deploy and manage isolated Docker Compose applications. Each app gets its own IP, containers, and volumes — no port conflicts.

### Commands

```bash
./apps/scripts/deploy.sh <repo-url> <name>   # Deploy a new app
./apps/scripts/update.sh <name>               # Pull latest + rebuild
./apps/scripts/start.sh <name>                # Start stopped app
./apps/scripts/stop.sh <name>                 # Stop app containers
./apps/scripts/remove.sh <name>               # Full cleanup
./apps/scripts/status.sh                      # Show all apps
./apps/scripts/logs.sh <name> [-f]            # View logs
```

### How It Works

1. `deploy.sh` clones the repo into `apps/deployments/<name>/`
2. Auto-detects the frontend service (traefik, nginx, web, etc.) — or reads it from `.apps-deploy.yml`
3. Detects **registry mode** if `.apps-deploy.yml` contains a `registry` field (skips local build, pulls from GHCR)
4. Generates `docker-compose.deploy.yml` — rebinds ports to dedicated IP, adds proxy network
5. Assigns a dedicated LAN IP (192.168.3.200+) via NetworkManager IP aliases
6. Registers NPM proxy host and Homepage dashboard labels
7. Records the app in `apps/config/apps.conf`

### Deploy Modes

Apps can be deployed in two ways:

#### Local build (default)

The self-hosted runner clones the repo and builds Docker images locally on the homeserver.

```
GitHub push (RELEASE) → self-hosted runner → clone → maven build → docker compose build → up
```

Best for: lightweight apps, apps without CI pipelines, quick prototypes.

#### Registry mode (GHCR)

Images are built on GitHub-hosted runners and pushed to GitHub Container Registry. The homeserver only pulls pre-built images.

```
GitHub push (RELEASE) → GitHub runner: maven build → docker build+push to GHCR (matrix)
                       → self-hosted runner: docker compose pull → up
```

To enable registry mode, add a `.apps-deploy.yml` in the app repo root:

```yaml
frontend_service: gateway    # which service is the entrypoint
frontend_port: 80
registry: ghcr.io/<owner>/<repo>
```

The workflow should set `IMAGE_TAG` as an env var (e.g. `sha-${{ github.sha }}`). Both `deploy.sh` and `update.sh` will pin the tag in the generated compose file via `${IMAGE_TAG:-latest}` substitution.

See `apps/deployments/dndproject/.github/workflows/deploy-on-homeserver.yml` for a working 3-job example (maven-build → build-and-push → deploy).

### Update Flow

`update.sh` handles subsequent deploys with a safe rollback strategy:

1. Pulls latest code from git
2. In registry mode: skips Maven build, does `docker compose pull` instead of `build`
3. Regenerates `docker-compose.deploy.yml` (rebinds ports, networks, labels)
4. Pins `IMAGE_TAG` if set (registry mode)
5. Backs up the previous compose file for rollback
6. Deploys with `--force-recreate --remove-orphans`
7. Waits 60s, then runs health checks (container state + restart count + HTTP smoke test)
8. On failure: rolls back to previous compose + images and aborts

### Network Modes

| Mode | Description |
|------|-------------|
| **IP Alias** (default) | Each app gets a dedicated LAN IP on the WiFi interface |
| **WiFi / NPM** | Apps share the server IP, routed via Nginx Proxy Manager domains |
| **Macvlan** | Dedicated LAN IPs via macvlan (requires Ethernet) |

IP aliases are assigned from `IP_ALIAS_BASE` in `settings.conf` (default: `192.168.3.200`). Slot 1 gets `.200`, slot 2 gets `.201`, etc. All ports in the app's compose file are rebound to the dedicated IP, so multiple apps can expose the same port without conflicts.

### CI/CD

Apps deploy automatically via GitHub Actions. Include `RELEASE` in a commit message to trigger a deploy. Add `CLEAN` to also wipe volumes (useful for database migration resets).

The self-hosted runner (in `homeserver/github-runner/`) picks up jobs and calls `ci-deploy.sh`, which:
- Runs `deploy.sh` if the app doesn't exist yet (first deploy)
- Runs `update.sh` if the app is already registered

The workflow template is at `apps/templates/github-workflow.yml`.

### Configuration

| File | Description |
|------|-------------|
| `apps/config/settings.conf` | Network mode, NPM credentials, server IP, IP alias range |
| `apps/config/apps.conf` | App registry (managed by scripts, format: `name\|slot\|repo\|status\|npm_id\|frontend\|port\|ip\|npm_ip_id`) |
| `apps/config/secrets/<name>/` | Per-app secrets, copied into the app dir on deploy |
| `<app-repo>/.apps-deploy.yml` | Optional per-app overrides: frontend service/port, registry URL |

---

## Prerequisites

- Docker Engine + Docker Compose v2
- NVIDIA GPU + [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) (for Ollama)
- NAS/external storage mounted for media volumes (Plex)

## Secrets

All secrets are gitignored. Template files are provided:

- `homeserver/.env.example` — homeserver stack secrets
- `apps/config/settings.conf.example` — apps platform settings

Never commit `.env`, `settings.conf`, or anything in `*/secrets/`.
