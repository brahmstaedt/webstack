#!/usr/bin/env bash
# Auto-update for the proxy stack and all deployed apps.
#
#   1. Run verify.sh. If the system is already broken, change nothing (exit 2).
#   2. Pull newer images for the pinned tags (e.g. traefik:v3.7 -> latest v3.7.x patch).
#   3. Recreate the containers whose running image differs from the image of their tag
#      (this also applies images that were pulled earlier but never applied).
#   4. Run verify.sh again. On failure, roll back to the previously running images (exit 4 or 5).
#
# Only stacks that have containers are handled: an app directory you never deployed, or
# stopped with `docker compose down`, is left alone. An app directory containing a file named
# .no-auto-update is skipped as well.
#
# The automatic run makes no login test (TEST_USER/TEST_PASSWORD are ignored), so no password
# has to be stored on the server. Run ./verify.sh with them by hand for the login checks.
#
# Exit codes: 0 ok / nothing to do, 2 pre-check failed, 3 pull failed,
#             4 update failed and was rolled back, 5 rollback also failed verification.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

log() { echo "[$(date -Is)] $*"; }
verify() { env -u TEST_USER -u TEST_PASSWORD ./verify.sh; }
compose() { local s="$1"; shift; docker compose -f "$s/docker-compose.yml" "$@"; }

# Deployed stacks: those with at least one container (running or stopped).
stacks=()
for d in proxy apps/*/; do
  d="${d%/}"
  [[ -f "$d/docker-compose.yml" ]] || continue
  if [[ -e "$d/.no-auto-update" ]]; then log "skip $d (.no-auto-update)"; continue; fi
  if [[ -z "$(compose "$d" ps -a -q 2>/dev/null)" ]]; then log "skip $d (not deployed)"; continue; fi
  stacks+=("$d")
done

up_all() {
  local rc=0
  for s in "${stacks[@]}"; do
    compose "$s" up -d --wait --wait-timeout 180 || { log "WARN: $s did not become ready"; rc=1; }
  done
  sleep 15   # give Traefik time to pick up routes and certificates
  return $rc
}

# 1. Pre-check
log "pre-check: ./verify.sh"
if ! out="$(verify 2>&1)"; then
  echo "$out"
  log "verify.sh fails BEFORE updating. Nothing was changed. Fix the system first."
  exit 2
fi

# 2. Remember the image each container is running (per tag), then pull
declare -A running=()
for s in "${stacks[@]}"; do
  while read -r cid; do
    [[ -n "$cid" ]] || continue
    read -r ref id < <(docker inspect -f '{{.Config.Image}} {{.Image}}' "$cid")
    [[ -n "${running[$ref]:-}" ]] || running["$ref"]="$id"
  done < <(compose "$s" ps -a -q)
  if ! compose "$s" pull --quiet --ignore-buildable; then
    log "pull failed for $s. No container was changed."
    exit 3
  fi
done

# 3. Tags whose image differs from what is running
changed=()
for ref in "${!running[@]}"; do
  new="$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null || true)"
  [[ -n "$new" && "$new" != "${running[$ref]}" ]] && changed+=("$ref")
done
if ((${#changed[@]} == 0)); then
  log "no updates available"
  exit 0
fi
log "new images: ${changed[*]}"
up_all

# 4. Verify, roll back on failure
log "post-check: ./verify.sh"
if verify; then
  docker image prune -f >/dev/null   # old images are kept until the update is verified
  log "update OK"
  exit 0
fi

log "verification FAILED after update. Rolling back: ${changed[*]}"
for ref in "${changed[@]}"; do
  docker tag "${running[$ref]}" "$ref"
done
up_all
if verify; then
  log "rollback OK. The update needs manual attention (see output above)."
  exit 4
fi
log "ROLLBACK ALSO FAILS VERIFICATION. Manual intervention required."
exit 5
