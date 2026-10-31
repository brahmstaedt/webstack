#!/usr/bin/env bash
# Keeps the start page current: generates it once, then again whenever a container starts,
# stops or is removed. Bursts of events (e.g. `docker compose up` of several services) are
# combined into one run.
#
# Normally run by ops/systemd/webstack-startpage@.service. When Docker restarts,
# `docker events` ends, this script exits, and systemd starts it again.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

regenerate() { "$here/generate.sh" || echo "start page generation failed" >&2; }

regenerate
docker events --filter type=container \
  --filter event=start --filter event=die --filter event=destroy \
  --format '{{.Action}} {{.Actor.Attributes.name}}' |
while read -r _; do
  while read -r -t 2 _; do :; done   # wait until 2 s without further events
  regenerate
done
