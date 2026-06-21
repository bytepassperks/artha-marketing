#!/usr/bin/env bash
# Artha Marketing (Mautic) — background cron loop (Scalingo worker process).
# Mautic relies on periodic maintenance commands; this runs the core set on a
# fixed interval so segments, campaigns and email queue stay live.
set -uo pipefail
export MAUTIC_ENV="${MAUTIC_ENV:-prod}"

run() { php bin/console "$@" --no-interaction >/dev/null 2>&1 || true; }

# Give the web process time to install the schema on first deploy.
sleep 90
while true; do
  run mautic:segments:update
  run mautic:campaigns:update
  run mautic:campaigns:trigger
  run mautic:emails:send
  run mautic:messages:send
  run mautic:broadcasts:send
  sleep 120
done
