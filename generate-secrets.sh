#!/usr/bin/env bash
# Creates the random secrets Authelia needs and proxy/.env with the user Authelia runs as.
# Existing secrets are never overwritten (changing storage_encryption_key would make the
# existing database unreadable).
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
dir="$root/proxy/authelia/secrets"

# Authelia runs as the owner of the repository, so its files stay editable without sudo.
envfile="$root/proxy/.env"
if [[ -f "$envfile" ]] && grep -q '^PUID=' "$envfile"; then
  echo "keep     $envfile"
else
  # make sure the appended lines don't end up on the last line of an existing file
  [[ -s "$envfile" && -n "$(tail -c1 "$envfile")" ]] && echo >> "$envfile"
  printf 'PUID=%s\nPGID=%s\n' "$(stat -c %u "$root")" "$(stat -c %g "$root")" >> "$envfile"
  echo "added    PUID=$(stat -c %u "$root"), PGID=$(stat -c %g "$root") to $envfile"
  if [[ "$(stat -c %u "$root")" == 0 ]]; then
    echo "WARNING: the repository is owned by root, so Authelia would run as root." >&2
    echo "         Let a normal user (in group docker) own it, e.g. sudo chown -R <user>: $root," >&2
    echo "         then remove the PUID/PGID lines from $envfile and run this script again." >&2
  fi
fi
mkdir -p "$root/proxy/authelia/data"
mkdir -p "$dir"
chmod 700 "$dir"
# The files below must be readable by PUID: if this runs via sudo, hand them to the repo owner.
trap 'chown -R "$(stat -c %u:%g "$root")" "$dir" "$root/proxy/authelia/data" "$envfile" 2>/dev/null || true' EXIT

for name in jwt_secret session_secret storage_encryption_key; do
  f="$dir/$name"
  if [[ -s "$f" ]]; then
    echo "keep     $f"
  else
    (umask 077; openssl rand -hex 64 > "$f")
    echo "created  $f"
  fi
done
