#!/usr/bin/dumb-init /bin/bash
# Multi-repo GitHub Actions Runner
# Runs one runner process per repository for a GitHub user.
# Automatically restarts when new repositories are discovered.

set -euo pipefail

# Allow runner to run as root (required inside Docker containers)
export RUNNER_ALLOW_RUNASROOT=1

GITHUB_USER="${GITHUB_USER:?GITHUB_USER is required}"
POLL_INTERVAL="${POLL_INTERVAL:-300}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-homeserver}"
LABELS="${LABELS:-self-hosted,Linux,X64,homeserver}"
RUNNER_BASE="/actions-runner"
RUNNERS_DIR="/runners"

# Read access token from Docker secret if not in env
if [[ -z "${ACCESS_TOKEN:-}" ]] && [[ -f /run/secrets/access_token ]]; then
  ACCESS_TOKEN="$(tr -d '[:space:]' < /run/secrets/access_token)"
fi
: "${ACCESS_TOKEN:?ACCESS_TOKEN is required (env or /run/secrets/access_token)}"

declare -a PIDS=()

log() { echo "[multi-runner] $(date '+%H:%M:%S') $*"; }

# --- Cleanup on exit: stop all runner processes ---
cleanup() {
  log "Shutting down all runners..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  log "All runners stopped."
}
trap cleanup EXIT

# --- Does the repo actually have workflows? ---
# Un runner registrato costa ~120 MB di RAM anche fermo. Senza questo filtro se
# ne registravano 16, uno per repo, per DUE repo che fanno CI: 1.9 GB, di cui
# 1.7 per aspettare lavoro che non arriva. 404 dal contents endpoint = nessuna
# cartella .github/workflows.
has_workflows() {
  curl -sf -o /dev/null -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "https://api.github.com/repos/$1/contents/.github/workflows"
}

# --- Fetch the repos owned by the user that have workflows ---
fetch_repos() {
  local page=1
  local all=""
  while true; do
    local batch
    batch=$(curl -sf -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      "https://api.github.com/user/repos?per_page=100&page=${page}&type=owner" \
      | jq -r '.[].full_name' 2>/dev/null) || break
    [[ -z "$batch" ]] && break
    all+="${batch}"$'\n'
    (( $(echo "$batch" | wc -l) < 100 )) && break
    ((page++))
  done
  # `|| true`: con set -e, has_workflows che fallisce sull'ultimo comando del
  # corpo del while abortirebbe lo script invece di saltare il repo.
  local repo
  while read -r repo; do
    [[ -z "$repo" ]] && continue
    has_workflows "$repo" && echo "$repo" || true
  done < <(echo "$all" | sort -u | sed '/^$/d')
}

# --- Register and start a runner for one repo ---
start_runner() {
  local repo="$1"
  local safe_name
  safe_name=$(echo "$repo" | tr '/' '-')
  local dir="${RUNNERS_DIR}/${safe_name}"

  log "Registering runner for ${repo}..."

  # Create runner directory: copy bin/ (~79MB) for independent config,
  # symlink externals/ (~596MB) to save disk space
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -r "${RUNNER_BASE}/bin" "$dir/bin"
  ln -s "${RUNNER_BASE}/externals" "$dir/externals"
  for f in config.sh run.sh env.sh safe_sleep.sh run-helper.sh.template run-helper.cmd.template; do
    [[ -f "${RUNNER_BASE}/$f" ]] && cp "${RUNNER_BASE}/$f" "$dir/"
  done

  # Get a registration token from the GitHub API
  local reg_token
  reg_token=$(curl -sf -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "https://api.github.com/repos/${repo}/actions/runners/registration-token" \
    | jq -r '.token' 2>/dev/null)

  if [[ -z "$reg_token" || "$reg_token" == "null" ]]; then
    log "WARNING: Cannot get registration token for ${repo} — skipping"
    rm -rf "$dir"
    return 1
  fi

  # Configure the runner
  local flags=(
    --unattended
    --url "https://github.com/${repo}"
    --token "$reg_token"
    --name "${RUNNER_NAME_PREFIX}-${safe_name}"
    --labels "$LABELS"
    --work "_work"
    --replace
  )
  [[ "${DISABLE_AUTO_UPDATE:-}" == "true" ]] && flags+=(--disableupdate)

  (cd "$dir" && ./config.sh "${flags[@]}") || {
    log "WARNING: Failed to configure runner for ${repo} — skipping"
    rm -rf "$dir"
    return 1
  }

  # Start the runner process in the background
  (cd "$dir" && ./run.sh) &
  PIDS+=($!)
  log "Runner for ${repo} started (PID $!)"
}

# ============================================================
# Main
# ============================================================
log "Discovering repositories for ${GITHUB_USER}..."
repos=$(fetch_repos)
repo_count=$(echo "$repos" | wc -l)
log "Found ${repo_count} repositories"

mkdir -p "$RUNNERS_DIR"

for repo in $repos; do
  start_runner "$repo" || true
done

log "${#PIDS[@]} runners active. Polling for new repos every ${POLL_INTERVAL}s..."
echo "$repos" > /tmp/known_repos

# ============================================================
# Watcher loop — detect new repos and dead processes
# ============================================================
while true; do
  sleep "$POLL_INTERVAL"

  # Check for crashed runner processes
  for i in "${!PIDS[@]}"; do
    if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
      log "Runner PID ${PIDS[$i]} died — restarting container"
      exit 1
    fi
  done

  # Check for new repositories
  current_repos=$(fetch_repos)
  known_repos=$(cat /tmp/known_repos)

  if [[ "$current_repos" != "$known_repos" ]]; then
    new_repos=$(comm -23 <(echo "$current_repos") <(echo "$known_repos")) || true
    if [[ -n "$new_repos" ]]; then
      log "New repositories detected:"
      echo "$new_repos" | while read -r r; do log "  + ${r}"; done
      log "Restarting to register new runners..."
      exit 0
    fi
    # Update known list (handles removed repos without restart)
    echo "$current_repos" > /tmp/known_repos
  fi
done
