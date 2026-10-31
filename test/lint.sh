#!/usr/bin/env bash
# Static checks, identical locally and in CI (.github/workflows/ci.yml runs this script).
#
#   test/lint.sh
#
# 1. shellcheck on all shell scripts, with a PINNED shellcheck version. New shellcheck releases
#    add checks, so an unpinned version (e.g. from the OS packages) would give different results
#    on different machines. If the installed shellcheck isn't the pinned version, the official
#    static binary is downloaded once, verified against its SHA-256 checksum, and cached in
#    ${XDG_CACHE_HOME:-~/.cache}/webstack/.
# 2. YAML syntax of all YAML files (needs python3 with PyYAML).
# 3. All compose files resolve, in every addressing mode (skipped if docker is not installed).
#
# Updating shellcheck: change SHELLCHECK_VERSION and both checksums (from the release page or
# the GitHub API's asset "digest"), then fix whatever new warnings appear.

set -euo pipefail
cd "$(dirname "$0")/.."

SHELLCHECK_VERSION=v0.11.0
declare -A SHELLCHECK_SHA256=(
  [x86_64]=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
  [aarch64]=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
)

rc=0
step() { echo; echo "== $1"; }
fail() { echo "FAIL: $*"; rc=1; }

# Prints the path of a shellcheck binary of the pinned version, downloading it if needed.
pinned_shellcheck() {
  if command -v shellcheck >/dev/null &&
     [[ "$(shellcheck --version | sed -n 's/^version: //p')" == "${SHELLCHECK_VERSION#v}" ]]; then
    command -v shellcheck; return
  fi
  local arch dir tarball sum
  arch="$(uname -m)"; [[ "$arch" == arm64 ]] && arch=aarch64
  [[ -n "${SHELLCHECK_SHA256[$arch]:-}" ]] || { echo "no pinned shellcheck for architecture $arch" >&2; return 1; }
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/webstack/shellcheck-$SHELLCHECK_VERSION-$arch"
  if [[ ! -x "$dir/shellcheck" ]]; then
    echo "downloading shellcheck $SHELLCHECK_VERSION ($arch) to $dir" >&2
    mkdir -p "$dir"
    tarball="$dir/shellcheck.tar.xz"
    curl -fsSL --max-time 120 -o "$tarball" \
      "https://github.com/koalaman/shellcheck/releases/download/$SHELLCHECK_VERSION/shellcheck-$SHELLCHECK_VERSION.linux.$arch.tar.xz"
    sum="$(sha256sum "$tarball" | cut -d' ' -f1)"
    if [[ "$sum" != "${SHELLCHECK_SHA256[$arch]}" ]]; then
      rm -f "$tarball"; echo "checksum mismatch for the shellcheck download: $sum" >&2; return 1
    fi
    tar -xJf "$tarball" -C "$dir" --strip-components=1 "shellcheck-$SHELLCHECK_VERSION/shellcheck"
    rm -f "$tarball"
  fi
  echo "$dir/shellcheck"
}

step "shellcheck $SHELLCHECK_VERSION"
if sc="$(pinned_shellcheck)"; then
  mapfile -t scripts < <(git ls-files '*.sh')
  if "$sc" -S warning "${scripts[@]}"; then echo "ok: ${#scripts[@]} scripts"; else fail "shellcheck"; fi
else
  fail "could not get shellcheck $SHELLCHECK_VERSION"
fi

step "YAML syntax"
if python3 -c 'import yaml' 2>/dev/null; then
  if git ls-files -z '*.yml' '*.yaml' | python3 -c '
import sys, yaml
files = [f for f in sys.stdin.read().split("\0") if f]
for f in files:
    with open(f) as fh:
        yaml.safe_load(fh)
print(f"ok: {len(files)} files")
'; then :; else fail "YAML syntax"; fi
else
  fail "python3 with PyYAML is needed (e.g. apt install python3-yaml)"
fi

step "compose files resolve"
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  export DOMAIN=example.com PUID=1000 PGID=1000
  checks=(
    "proxy::docker compose -f proxy/docker-compose.yml config -q"
    "startpage::docker compose -f apps/startpage/docker-compose.yml config -q"
    "whoami (own hosts)::env PRIVATE_HOST=private.example.com PUBLIC_HOST=public.example.com docker compose -f apps/whoami/docker-compose.yml config -q"
    "whoami (sub-paths)::env PRIVATE_PATH=/private PUBLIC_PATH=/public docker compose -f apps/whoami/docker-compose.yml config -q"
  )
  for c in "${checks[@]}"; do
    name="${c%%::*}"; cmd="${c#*::}"
    if $cmd; then echo "ok: $name"; else fail "compose config: $name"; fi
  done
else
  echo "skipped: docker with the compose plugin is not installed here (CI runs this step)"
fi

echo
if ((rc == 0)); then echo "lint: all checks passed"; else echo "lint: FAILED"; fi
exit $rc
