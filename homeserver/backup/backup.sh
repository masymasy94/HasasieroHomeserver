#!/usr/bin/env bash
# Backup con restic dei dati che non si ricreano: volumi docker (campagne e
# personaggi di solo-dm, animehub), config di Home Assistant, certificati
# di NPM, il vault sops e la chiave age che lo apre, e i database delle app
# (HasasieroGPT, Bookasiero, Shopping: SQLite; Hasasierofy: Postgres).
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

# Database delle app, percorsi presi dai loro compose (10/11). Copia coerente in
# DUMP_DIR a container accesi: SQLite con .backup (API di backup online, in sola
# lettura: niente checkpoint sul file dell'app), Postgres
# con pg_dump. Un'app che sul server non c'e' da' solo un avviso; un dump che
# fallisce non ferma il resto del backup, ma alla fine lo script esce con 1.
DUMP_DIR="/var/tmp/homeserver-backup-db"   # fisso: viene svuotata con rm -rf
SQLITE_DBS=(   # nome:file sull'host
  "hasasierogpt:/mnt/hdd/hasasierogpt/app.db"
  "bookasiero:/mnt/hdd/ebooks/bookasiero.db"
  "hasasieroshopping:${DOCKER_ROOT}/apps/deployments/hasasieroshopping/data/prices.db"
)
PG_DBS=(       # container:utente:database
  "hasasierofy-db-1:hasasierofy:hasasierofy"
)

log() { echo "[backup] $(date '+%F %T') $*"; }
avviso() { echo "[backup] AVVISO: $*" >&2; }

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

# Le app presenti sul server, una per riga: "sqlite <nome> <file>" o "pg <container> <utente> <db>".
app_dbs() {
  local e n f c u d
  for e in "${SQLITE_DBS[@]}"; do
    n=${e%%:*}; f=${e#*:}
    if [[ -f "$f" ]]; then echo "sqlite $n $f"; else avviso "manca $f: $n non salvato"; fi
  done
  for e in "${PG_DBS[@]}"; do
    IFS=: read -r c u d <<< "$e"
    if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == "true" ]]; then
      echo "pg $c $u $d"
    else
      avviso "container $c non acceso: database $d non salvato"
    fi
  done
}

DUMP_FALLITI=0
dump_dbs() {
  local tipo a b c
  rm -rf "$DUMP_DIR"
  mkdir -m 700 "$DUMP_DIR"
  while read -r tipo a b c; do
    case "$tipo" in
      sqlite)
        if ! command -v sqlite3 >/dev/null; then
          avviso "sqlite3 non installato (apt install sqlite3): $a non salvato"; DUMP_FALLITI=1
        elif ! sqlite3 -readonly -cmd '.timeout 10000' "$b" ".backup '${DUMP_DIR}/${a}.db'"; then
          avviso "copia di $b fallita"; rm -f "${DUMP_DIR}/${a}.db"; DUMP_FALLITI=1
        fi ;;
      pg)
        if ! docker exec "$a" pg_dump -U "$b" -d "$c" > "${DUMP_DIR}/${c}.sql"; then
          avviso "pg_dump di $c in $a fallito"; rm -f "${DUMP_DIR}/${c}.sql"; DUMP_FALLITI=1
        fi ;;
    esac
  done < <(app_dbs)
  log "database delle app: $(find "$DUMP_DIR" -type f | wc -l) copiati in ${DUMP_DIR}"
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

  # Le copie dei database stanno solo in restic: la cartella si cancella comunque.
  trap 'restart_stopped || true; rm -rf "$DUMP_DIR"' EXIT
  dump_dbs
  PATHS+=("$DUMP_DIR")
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
  if ((DUMP_FALLITI)); then
    echo "backup fatto, ma qualche database delle app non e' stato copiato (vedi AVVISO sopra)" >&2
    exit 1
  fi
}

# Prova di ripristino: l'ultimo snapshot in una cartella temporanea, poi ogni
# percorso deve esserci e la chiave age deve essere identica all'originale. Per
# ogni app presente oggi sul server il suo database deve esserci e aprirsi:
# SQLite con integrity_check, il dump di Postgres completo fino all'ultima riga.
do_prova() {
  local list p dbs tipo a b c f
  list=$(paths)
  dbs=$(app_dbs)
  # tmp globale: la trap EXIT gira dopo la fine della funzione.
  tmp=$(mktemp -d "${BACKUP_TMPDIR:-/var/tmp}/restic-prova.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  restic restore latest --tag "$TAG" --target "$tmp"
  while read -r p; do
    [[ -e "${tmp}${p}" ]] || { echo "PROVA FALLITA: manca ${p} nel ripristino" >&2; exit 1; }
  done <<< "$list"
  cmp -s "$AGE_KEY" "${tmp}${AGE_KEY}" \
    || { echo "PROVA FALLITA: keys.txt ripristinata diversa dall'originale" >&2; exit 1; }
  while read -r tipo a b c; do
    case "$tipo" in
      sqlite)
        f="${tmp}${DUMP_DIR}/${a}.db"
        [[ -s "$f" ]] || { echo "PROVA FALLITA: manca il database di $a nel ripristino" >&2; exit 1; }
        if command -v sqlite3 >/dev/null; then
          [[ "$(sqlite3 "$f" 'PRAGMA integrity_check')" == "ok" ]] \
            || { echo "PROVA FALLITA: il database di $a ripristinato non passa integrity_check" >&2; exit 1; }
        fi ;;
      pg)
        f="${tmp}${DUMP_DIR}/${c}.sql"
        grep -q '^-- PostgreSQL database dump complete' "$f" 2>/dev/null \
          || { echo "PROVA FALLITA: dump di $c mancante o troncato nel ripristino" >&2; exit 1; } ;;
    esac
  done <<< "$dbs"
  log "prova di ripristino ok ($(du -sh "$tmp" | cut -f1) in ${tmp}, ora cancellata)"
}

case "${1:-backup}" in
  backup) do_backup ;;
  prova)  do_prova ;;
  *) echo "uso: $0 [backup|prova]" >&2; exit 1 ;;
esac
