# homeserver — stack dei servizi core

Un solo `docker-compose.yml`, 21 servizi, su questa macchina (`192.168.3.54`). Si deploya a
mano da questa cartella:

```bash
docker compose config -q                                          # valida prima di applicare
sops exec-env env.sops.yaml 'docker compose up -d <servizio>'     # ricrea solo ciò che hai toccato
```

`.env` in chiaro è ancora sul disco e compose lo legge da sé, quindi un `docker compose up -d`
nudo funziona ancora. La forma con `sops exec-env` è quella che continuerà a funzionare quando
il `.env` sparirà: usa quella. I segreti veri di questo stack (chiave WireGuard di NordVPN,
token Telegram, PAT GitHub del runner, authkey Tailscale) stanno lì dentro.

I dati grossi stanno su `/mnt/hdd/`, non nel repo. `github-runner` è **gated da profilo**:
se un deploy resta in coda, `COMPOSE_PROFILES=runner docker compose up -d github-runner`.

## Rete: le trappole che tornano sempre

- **Dipendenti dalla netns di gluetun** (`qbittorrent`, `prowlarr`, `flaresolverr`): dopo
  ogni restart di gluetun vanno riavviati, altrimenti restano orfani su una netns morta —
  in LISTEN ma irraggiungibili. `docker restart qbittorrent prowlarr flaresolverr`.
- `autoheal` **non** copre questo caso: se il suo restart fallisce, con `unless-stopped` il
  container resta Exited per sempre. Dopo un restart di gluetun guarda `docker ps -a`, non
  solo `docker ps`.
- **Dopo un reboot** i container possono risultare "Up" e healthy con le porte chiuse:
  si sono staccati da `home-net`. Confronta `NetworkMode` con `Networks` in
  `docker inspect`, poi `docker network connect` + restart.
- **Una sola NIC attiva per LAN.** Wifi ed ethernet insieme sulla stessa rete rompono
  Tailscale.
- Il connectivity check di NetworkManager è **disabilitato di proposito**
  (`/etc/NetworkManager/conf.d/99-disable-connectivity-check.conf`): la penalità di +20000
  sulla metrica fa sbattere Tailscale. Non riabilitarlo.
- `fritz.box` va pinnato in `/etc/hosts` (`192.168.3.1`): il DNS lo risolve sull'IP
  pubblico AVM e il mount CIFS del NAS diventa stale.
- `cloudflared` è un container di questo stack, host network, config in `cloudflared/`.
  Tailscale Funnel non è più in uso. L'accesso autenticato si discrimina sul header
  `Cf-Access-Jwt-Assertion`, **mai** sull'IP sorgente (host-net → non è affidabile).

## Jellyfin

- Transcoding via **NVENC** sulla GTX 1650 (`runtime: nvidia`, `nvenc` in `encoding.xml`),
  non VAAPI. Dopo un upgrade dei driver: `sudo systemctl restart nvidia-cdi-refresh.service`
  o il recreate con `runtime: nvidia` fallisce.
- Se ti serve VAAPI: `/dev/dri/renderD129` è la **iGPU Intel**, `renderD128` è la NVIDIA —
  invertiti rispetto al solito.
- MP4 senza faststart (moov in coda) stallano il player Android: remux con
  `-c copy -movflags +faststart`.
- Anime: **solo NFO sidecar** (fetcher episodi spento, Reader=Nfo). La stagione la decide
  il **path**, non il tag `<season>` dell'NFO.
- I sottotitoli si estraggono a scan-time (plugin Subtitle Extract), non on-the-fly:
  leggere il NAS durante il playback faceva stutterare.

## Cartelle morte

Uscite da git il 2026-07-26, **cancellate dal disco il 2026-07-29**: `docker-agent/`,
`homeserver-mcp/`, `ollama/`, `netdata/`, `audiobookshelf/`, `telegram-ollama-bot/`,
`provoloni-countdown/`, `jellyfin-ts/` e `open-webui/` — nessuna aveva un riferimento in un
compose né un container, nemmeno fermo. Copia di sicurezza in
`~/attic/homeserver-cartelle-morte-2026-07-26.tar.gz`, che però **non contiene `open-webui/`**
(erano 891 MB di dati runtime, esclusi di proposito).

Alcune sottocartelle erano **root-owned** (`netdata/cache`, `netdata/lib`, `jellyfin-ts/state`):
scritte dai container come root, non cancellabili da `masy`. Si passa da un container root,
`docker run --rm -v <dir>:/w -w /w alpine sh -c "rm -r ..."`.

Prima di aggiungere una cartella qui dentro, assicurati che un servizio la usi davvero: la
regola è che ogni directory di questo stack compaia in `docker-compose.yml`. Plex e Ollama
sono stati rimossi del tutto: non reintrodurli.
