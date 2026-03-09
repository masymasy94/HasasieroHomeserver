#!/usr/bin/dumb-init /bin/bash
# Wrapper around the upstream entrypoint that:
# 1. Reads ACCESS_TOKEN from Docker secret file (if available)
# 2. Cleans stale runner config files (.runner_migrated) to prevent crash loops

# Load ACCESS_TOKEN from secret file if not already set via env
if [[ -z "${ACCESS_TOKEN}" ]] && [[ -f "/run/secrets/access_token" ]]; then
    export ACCESS_TOKEN
    ACCESS_TOKEN="$(cat /run/secrets/access_token | tr -d '[:space:]')"
fi

# Clean stale runner configuration that causes crash loops after upgrades
# The .runner_migrated file is left behind by runner binary upgrades and
# confuses the entrypoint which only checks/removes .runner
rm -f /actions-runner/.runner_migrated /actions-runner/.runner

exec /entrypoint.sh "$@"
