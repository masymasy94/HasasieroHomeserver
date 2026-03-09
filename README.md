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
| | Prowlarr Search | `8888` | Custom torrent search UI |
| | Jackett | `9117` | Torrent indexer proxy |
| | qBittorrent | `8085` | Torrent client (VPN-routed) |
| **AI** | Ollama | `11434` | LLM inference (NVIDIA GPU) |
| | Open WebUI | `8080` | Chat interface for Ollama |
| | Telegram Bot | — | Telegram interface for Ollama |
| **Smart Home** | Home Assistant | `8123` | Home automation |
| **VPN** | Gluetun | — | NordVPN WireGuard gateway |
| | FlareSolverr | `8191` | Cloudflare bypass |
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
│   ├── Ollama → Open WebUI, Telegram Bot
│   ├── Jackett, Prowlarr Search, NUT, Registry
│   │
│   └── Gluetun VPN (NordVPN WireGuard)
│       ├── Prowlarr (9696)
│       ├── FlareSolverr (8191)
│       └── qBittorrent (8085)
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
2. Auto-detects the frontend service (traefik, nginx, web, etc.)
3. Generates `docker-compose.deploy.yml` — strips ports, adds proxy network
4. Assigns a dedicated LAN IP (192.168.3.200+) via NetworkManager
5. Registers the app on Homepage dashboard via Docker labels

### Network Modes

| Mode | Description |
|------|-------------|
| **IP Alias** (default) | Each app gets a dedicated LAN IP on the WiFi interface |
| **WiFi / NPM** | Apps share the server IP, routed via Nginx Proxy Manager domains |
| **Macvlan** | Dedicated LAN IPs via macvlan (requires Ethernet) |

### CI/CD

Apps deploy automatically via GitHub Actions. Include `RELEASE` in a commit message to trigger a deploy. The self-hosted runner picks up the job and runs `update.sh` on the server.

### Configuration

| File | Description |
|------|-------------|
| `apps/config/settings.conf` | Network mode, NPM credentials, server IP |
| `apps/config/apps.conf` | App registry (managed by scripts) |
| `apps/config/secrets/<name>/` | Per-app secrets, copied on deploy |

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
