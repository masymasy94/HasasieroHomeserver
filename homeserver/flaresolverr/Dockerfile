# L'immagine upstream e' ferma al Chromium 152 (v3.5.2): qui si aggiorna quello di Debian.
# ponytail: watchtower non la ricostruisce; quando l'upstream esce con un Chromium recente
# togli il `build:` dal compose e torna a `image: ghcr.io/flaresolverr/flaresolverr:latest`.
FROM ghcr.io/flaresolverr/flaresolverr:latest
USER root
# FlareSolverr usa /app/chromedriver (spostato li' nel build upstream), non /usr/bin
RUN apt-get update \
 && apt-get install -y --no-install-recommends --only-upgrade chromium chromium-common chromium-driver \
 && mv /usr/bin/chromedriver /app/chromedriver && chown flaresolverr:flaresolverr /app/chromedriver \
 && rm -rf /var/lib/apt/lists/*
USER flaresolverr
