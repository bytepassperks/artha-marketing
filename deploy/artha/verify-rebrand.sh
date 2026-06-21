#!/usr/bin/env bash
# Asserts the Artha Marketing white-label layer is intact in the working tree.
#
# Run after merging upstream mautic/mautic commits: if upstream overwrote any
# branded file, an assertion fails LOUDLY here so the pipeline stops instead of
# shipping a half-branded (or Mautic-leaking) build. Exit 0 = rebrand intact.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

fail=0
need() {
  local file="$1" pat="$2" desc="$3"
  if [ ! -f "$file" ]; then
    printf ' !! MISSING FILE: %s (%s)\n' "$file" "$desc" >&2; fail=1; return
  fi
  if ! grep -qiF "$pat" "$file"; then
    printf ' !! REBRAND DRIFT: %s no longer contains "%s" (%s)\n' "$file" "$pat" "$desc" >&2; fail=1
  fi
}
present() {
  local file="$1" desc="$2"
  [ -f "$file" ] || { printf ' !! MISSING FILE: %s (%s)\n' "$file" "$desc" >&2; fail=1; }
}

# ── Brand identity must be present ────────────────────────────────────────────
need "app/bundles/CoreBundle/Resources/views/Default/base.html.twig" "Artha Marketing" "page title default (full layout)"
need "app/bundles/CoreBundle/Resources/views/Default/slim.html.twig" "Artha Marketing" "page title default (slim layout)"
need "app/bundles/CoreBundle/Resources/views/Default/head.html.twig" "Artha Marketing" "html <title> fallback"

# Branded logo + favicon assets must exist (Artha mark replaces Mautic's)
present "app/assets/images/mautic_logo_db200.png" "dark-bg brand logo"
present "app/assets/images/mautic_logo_lb200.png" "light-bg brand logo"
present "favicon.ico" "favicon"

# ── Deploy scaffolding must be present ────────────────────────────────────────
need ".buildpacks" "php-buildpack" "Scalingo buildpack manifest"
need "Procfile" "artha-deploy-boot.sh" "Procfile boots via Artha boot script"
present "bin/artha-deploy-boot.sh" "boot script"
present "deploy/apache_mautic.conf" "apache include"

if [ "$fail" -ne 0 ]; then
  printf '\n !! verify-rebrand FAILED — Artha Marketing branding/scaffolding drifted.\n' >&2
  exit 1
fi
printf '==> verify-rebrand OK: Artha Marketing white-label layer intact.\n'
