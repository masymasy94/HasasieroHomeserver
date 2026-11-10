#!/usr/bin/env bash
# Backup con restic dei dati che non si ricreano: volumi docker (campagne e
# personaggi di solo-dm, animehub), config di Home Assistant, certificati
# di NPM, il vault sops e la chiave age che lo apre.
#
# NON ATTIVO: la destinazione la sceglie chi lo accende. Prima volta, da root:
#   1. /etc/restic-homeserver.env (chmod 600), con dentro:
#        RESTIC_REPOSITORY=<destinazione: sftp:..., rest:..., s3:..., una cartella>
#        RESTIC_PASSWORD_FILE=/root/.restic-homeserver-password
#      La password tenerla ANCHE fuori da questa macchina: nel backup c'e' la
#      chiave age, ma senza password del repo non si apre niente.
#   2. set -a; . /etc/restic-homeserver.env; set +a; restic init
#   3. ./backup.sh          (backup + retention + restic check)
#      ./backup.sh prova    (ripristina l'ultimo snapshot in una cartella temporanea e controlla;
#                            serve spazio quanto il backup in BACKUP_TMPDIR, default /var/tmp)
#   4. timer: homeserver-backup.service/.timer in questa cartella (vedi lì).
#
# Volumi docker salvati come file dal loro Mountpoint, con i container che li
# scrivono fermi (SQLite a meta' scrittura non si ripristina). La doc restic non
# ha una pagina sui volumi docker: https://restic.readthedocs.io/en/stable/040_backup.html
# Ripristino di un volume: docker stop <c>; restic restore latest --target / --include <mountpoint>; docker start <c>

set -euo pipefail

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY non impostata (destinazione del backup)}"
[[ -n "${RESTIC_PASSWORD:-}${RESTIC_PASSWORD_FILE:-}" ]] || { echo "RESTIC_PASSWORD o RESTIC_PASSWORD_FILE non impostata" >&2; exit 1; }

DOCKER_ROOT="${DOCKER_ROOT:-/home/masy/Desktop/docker}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-homeserver}"
TAG="${BACKUP_TAG:-homeserver}"
AGE_KEY="/home/masy/.config/sops/age/keys.txt"
# Niente plex-config (5 GB): Plex non serve, c'e' Jellyfin (scelta dell'utente, 10/11).
VOLUMES=(solo-dm-campagne solo-dm-personaggi animehub-data)
BIND_PATHS=(
  "${DOCKER_ROOT}/homeserver/homeassistant/config"
  "${DOCKER_ROOT}/homeserver/nginx-proxy-manager/letsencrypt"
  "${DOCKER_ROOT}/homeserver/env.sops.yaml"   # senza il vault la chiave age non serve
  "$AGE_KEY"
)
# Container fermati durante il backup (scrivono nei volumi qui sopra).
read -r -a STOP_CONTAINERS <<< "${BACKUP_STOP:-solo-dm animehub homeassistant}"

log() { echo "[backup] $(date '+%F %T') $*"; }

command -v restic >/dev/null || { echo "restic non installato (apt install restic)" >&2; exit 1; }

# Elenco dei percorsi da salvare; un percorso mancante e' un errore, non un salto.
paths() {
  local v mp p
  for v in "${VOLUMES[@]}"; do
    mp=$(docker volume inspect -f '{{ .Mountpoint }}' "${COMPOSE_PROJECT}_${v}") || { echo "volume ${COMPOSE_PROJECT}_${v} non trovato" >&2; return 1; }
    echo "$mp"
  done
  for p in "${BIND_PATHS[@]}"; do
    [[ -e "$p" ]] || { echo "percorso mancante: $p" >&2; return 1; }
    echo "$p"
  done
}

STOPPED=()
restart_stopped() {
  # Rimette su solo quelli che erano accesi, anche se il backup e' fallito.
  if ((${#STOPPED[@]})); then
    docker start "${STOPPED[@]}" >/dev/null
    log "riavviati: ${STOPPED[*]}"
  fi
}

do_backup() {
  local list c
  list=$(paths)
  mapfile -t PATHS <<< "$list"

  trap restart_stopped EXIT
  for c in "${STOP_CONTAINERS[@]}"; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == "true" ]]; then
      docker stop "$c" >/dev/null
      STOPPED+=("$c")
    fi
  done
  log "fermati: ${STOPPED[*]:-nessuno}"

  restic backup --tag "$TAG" "${PATHS[@]}"
  restart_stopped
  STOPPED=()

  restic forget --tag "$TAG" --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
  restic check
  log "fatto"
}

# Prova di ripristino: l'ultimo snapshot in una cartella temporanea, poi ogni
# percorso deve esserci e la chiave age deve essere identica all'originale.
do_prova() {
  local list p
  list=$(paths)
  # tmp globale: la trap EXIT gira dopo la fine della funzione.
  tmp=$(mktemp -d "${BACKUP_TMPDIR:-/var/tmp}/restic-prova.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  restic restore latest --tag "$TAG" --target "$tmp"
  while read -r p; do
    [[ -e "${tmp}${p}" ]] || { echo "PROVA FALLITA: manca ${p} nel ripristino" >&2; exit 1; }
  done <<< "$list"
  cmp -s "$AGE_KEY" "${tmp}${AGE_KEY}" \
    || { echo "PROVA FALLITA: keys.txt ripristinata diversa dall'originale" >&2; exit 1; }
  log "prova di ripristino ok ($(du -sh "$tmp" | cut -f1) in ${tmp}, ora cancellata)"
}

case "${1:-backup}" in
  backup) do_backup ;;
  prova)  do_prova ;;
  *) echo "uso: $0 [backup|prova]" >&2; exit 1 ;;
esac
