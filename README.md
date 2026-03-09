# Homeserver

![Docker](https://img.shields.io/badge/Docker_Compose-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![Services](https://img.shields.io/badge/Services-18-green?style=for-the-badge)
![License](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)

A single `docker-compose.yml` stack running 18 self-hosted services on a home server, with VPN-routed torrenting, GPU-accelerated LLM inference, media serving, home automation, and a centralized dashboard.

## Services

| Service | Port | Description |
|---------|------|-------------|
| **Plex** | `32400` | Media server (Films, Series TV, Anime from NAS) |
| **Portainer** | `9000` | Docker container management UI |
| **Homepage** | `3000` | Central dashboard for all services |
| **Uptime Kuma** | `3001` | Service uptime monitoring & alerting |
| **Nginx Proxy Manager** | `80` `443` `81` | Reverse proxy with Let's Encrypt SSL |
| **Ollama** | `11434` | LLM inference engine (NVIDIA GPU) |
| **Open WebUI** | `8080` | Web chat interface for Ollama |
| **Telegram Ollama Bot** | — | Telegram bot for Ollama chat |
| **Home Assistant** | `8123` | Home automation platform |
| **NUT** | `9090` | Nintendo Switch network installer |
| **Gluetun** | — | VPN gateway (NordVPN WireGuard) |
| **Prowlarr** | `9696` | Indexer manager (VPN-routed) |
| **Prowlarr Search** | `8888` | Custom torrent search UI |
| **Jackett** | `9117` | Torrent indexer proxy |
| **FlareSolverr** | `8191` | Cloudflare bypass (VPN-routed) |
| **qBittorrent** | `8085` | Torrent client (VPN-routed) |
| **Glances** | `61208` | Real-time system & container monitor |
| **Watchtower** | — | Automatic nightly image updates |

## Network Architecture

```
HOST (192.168.3.54)
│
├── Host Network
│   ├── Plex (32400)
│   └── Home Assistant (8123)
│
├── home-net (bridge)
│   ├── Portainer, Homepage, Uptime Kuma, Glances
│   ├── Nginx Proxy Manager (80, 443, 81)
│   ├── Ollama → Open WebUI, Telegram Bot
│   ├── Jackett, Prowlarr Search, NUT
│   │
│   └── Gluetun VPN (NordVPN WireGuard, Netherlands)
│       ├── Prowlarr (9696)
│       ├── FlareSolverr (8191)
│       └── qBittorrent (8085, 6881)
│
└── Watchtower (auto-update daemon)
```

Services behind Gluetun use `network_mode: "service:gluetun"` and share its VPN tunnel.

## Prerequisites

- Docker Engine + Docker Compose v2
- NVIDIA GPU + [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) (for Ollama)
- NAS/external storage mounted for media volumes

## Getting Started

1. **Clone the repo**
   ```bash
   git clone https://github.com/masymasy94/homeserver.git
   cd homeserver
   ```

2. **Configure secrets**
   ```bash
   cp .env.example .env
   ```
   Edit `.env` and fill in your actual values:
   - `WIREGUARD_PRIVATE_KEY` — NordVPN WireGuard private key
   - `TELEGRAM_BOT_TOKEN` — Telegram bot token from [@BotFather](https://t.me/BotFather)
   - `ALLOWED_USER_IDS` — Your Telegram user ID

3. **Adjust volume paths** in `docker-compose.yml` to match your storage layout:
   - NAS media paths (Plex)
   - Torrent download directory (qBittorrent)
   - Switch games directory (NUT)

4. **Start the stack**
   ```bash
   docker compose up -d
   ```

5. **Open the dashboard** at `http://<your-server-ip>:3000`

## Project Structure

```
homeserver/
├── docker-compose.yml          # All 18 services
├── .env                        # Secrets (gitignored)
├── .env.example                # Secret template
├── homepage/config/            # Dashboard widgets & services
├── prowlarr-search/            # Custom search UI (HTML + Nginx)
├── nut/conf/                   # NUT configuration
├── jackett/config/cardigann/   # Custom indexer definitions
└── telegram-ollama-bot/        # Bot source code + Dockerfile
```

Runtime data directories (`*/data/`, `*/config/`) are gitignored and created automatically by each container.

## Configuration

All secrets are stored in a single `.env` file at the root, which Docker Compose interpolates automatically. See [`.env.example`](.env.example) for the required variables.

Service-specific settings (timezone, ports, models) are defined directly in `docker-compose.yml`. All services use `TZ=Europe/Rome`.

## Updating

[Watchtower](https://containrrr.dev/watchtower/) runs daily at 04:00 and automatically pulls new images and recreates containers. To update manually:

```bash
docker compose pull
docker compose up -d
```
