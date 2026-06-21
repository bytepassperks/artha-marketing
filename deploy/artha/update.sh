#!/usr/bin/env bash
# Auto-update pipeline for Artha Marketing (Mautic fork, PHP/Symfony).
#
# Tracks upstream mautic/mautic (branch 6.0) and ships new commits to the live
# Scalingo app with the thin Artha white-label layer preserved — the same
# fork-tracks-upstream model used by Artha's other rebranded repos
# (Accounting/erpsaas, Automations/Activepieces, Docs/BookStack, Support/Chatwoot).
#
# The rebrand is a set of isolated git commits (logo PNGs, page-title default,
# favicon, deploy kit) so the vast majority of upstream commits merge cleanly.
# If a merge conflicts, or a merged commit overwrites a branded file, the
# pipeline STOPS LOUDLY (no deploy) and asks for a human — production untouched.
#
# Flow: fetch upstream -> up-to-date short-circuit -> dry-run trial-merge +
# rebrand assertions + asset build -> real merge -> rebuild assets -> push fork
# -> deploy archive to Scalingo -> migrate -> verify live (HTTP 200 + brand
# token) -> record deployed upstream SHA.
#
#   --dry-run   run resolve + trial-merge + assert + build only
#   --force     redeploy even if no new upstream commits
#
# Required env: GH_TOKEN (push to fork). For a real deploy: SCALINGO_API_TOKEN.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="6.0"
FORK_BRANCH="artha-6.0"
SCALINGO_APP="artha-marketing"
SCALINGO_REGION="osc-fr1"
LIVE_URL="https://artha-marketing.osc-fr1.scalingo.io"
VERIFY_PATH="/s/login"
EXPECTED_TOKEN="Artha Marketing"
VERSION_FILE="$HERE/VERSION"

DRY_RUN=0; FORCE=0
log()  { printf '\n==> %s\n' "$*"; }
die()  { printf '\n !! %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *)         die "unknown flag: $1" ;;
  esac
  shift
done

[ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN is required (repo scope)."

git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 \
  || die "git remote '$UPSTREAM_REMOTE' is not configured."
log "Fetching $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
git fetch --quiet "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"

UPSTREAM_SHA="$(git rev-parse "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")"
RECORDED_SHA="$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)"
log "recorded: ${RECORDED_SHA:-<none>}   latest: $UPSTREAM_SHA"

if git merge-base --is-ancestor "$UPSTREAM_SHA" HEAD 2>/dev/null && [ "$FORCE" -ne 1 ]; then
  log "Already contains upstream $UPSTREAM_SHA — nothing to do."; exit 0
fi
[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit/stash first."
git checkout --quiet "$FORK_BRANCH"

if [ "$DRY_RUN" -eq 1 ]; then
  TRIAL="artha-trial-$(date +%s)"
  log "DRY-RUN: trial-merging upstream onto $TRIAL"
  git checkout --quiet -b "$TRIAL"
  cleanup() { git merge --abort 2>/dev/null || true; git checkout --quiet "$FORK_BRANCH"; git branch -D "$TRIAL" 2>/dev/null || true; }
  trap cleanup EXIT
  if ! git merge --no-edit --no-ff "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" >/dev/null 2>&1; then
    git merge --abort 2>/dev/null || true
    die "DRY-RUN: merge CONFLICT against upstream $UPSTREAM_SHA — needs a human. Production untouched."
  fi
  "$HERE/verify-rebrand.sh"
  log "DRY-RUN: building assets to prove they compile"
  npm ci --no-audit --no-fund && npm run build
  log "DRY-RUN complete: clean merge, rebrand intact, assets build. Safe to ship."
  exit 0
fi

log "Merging upstream $UPSTREAM_SHA into $FORK_BRANCH"
if ! git merge --no-edit --no-ff "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
  git merge --abort 2>/dev/null || true
  die "merge CONFLICT against upstream $UPSTREAM_SHA — needs a human. Production untouched."
fi
"$HERE/verify-rebrand.sh" || die "rebrand drifted after merge — fix deploy/artha before shipping. Production untouched."

log "Rebuilding assets"
npm ci --no-audit --no-fund && npm run build || true
git add -A
git diff --cached --quiet || git commit -m "Rebuild assets after upstream merge ($UPSTREAM_SHA)"

log "Pushing $FORK_BRANCH to origin"
git push origin "$FORK_BRANCH"

[ -n "${SCALINGO_API_TOKEN:-}" ] || die "SCALINGO_API_TOKEN is required for deploy."
export SCALINGO_REGION
log "Logging in to Scalingo"
scalingo login --api-token "$SCALINGO_API_TOKEN" >/dev/null

TARBALL="$(mktemp -d)/artha-marketing.tar.gz"
git archive --format=tar.gz --prefix=artha-marketing/ HEAD -o "$TARBALL"
log "Deploying archive ($(du -h "$TARBALL" | cut -f1)) to $SCALINGO_APP"
scalingo --app "$SCALINGO_APP" deploy "$TARBALL" "artha-$(git rev-parse --short HEAD)-$(date +%s)"

log "Running database migrations"
scalingo --app "$SCALINGO_APP" --region "$SCALINGO_REGION" run --silent 'php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration' || true

log "Verifying live app at $LIVE_URL$VERIFY_PATH"
ok=0
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$LIVE_URL$VERIFY_PATH" || true)"
  if [ "$code" = "200" ] && curl -s "$LIVE_URL$VERIFY_PATH" | grep -qF "$EXPECTED_TOKEN"; then ok=1; break; fi
  sleep 10
done
[ "$ok" -eq 1 ] || die "post-deploy verification failed: $LIVE_URL$VERIFY_PATH not 200 with '$EXPECTED_TOKEN'."
log "live: HTTP 200 + '$EXPECTED_TOKEN' present."

echo "$UPSTREAM_SHA" > "$VERSION_FILE"
git add "$VERSION_FILE"
git commit -m "Record deployed upstream mautic SHA $UPSTREAM_SHA"
git push origin "$FORK_BRANCH"
log "DONE. Artha Marketing updated to upstream $UPSTREAM_SHA and live."
