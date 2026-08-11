#!/usr/bin/env bash
# Cloudflare audit-log archive — read-only capture of the account's change history.
#
# Usage:
#   scripts/cf-audit-archive.sh          walk back until the log runs dry, merge, rewrite
#   scripts/cf-audit-archive.sh <days>   only look back <days> (quick incremental top-up)
#
# WHY THIS EXISTS, AND WHY IT MUST BE RUN PERIODICALLY
# The audit log is the only record of *what changed when* — cf-sync.sh captures
# state, never history. But Cloudflare's log is finite and rolls off: policy says
# 18 months, and this account's log is additionally capped at 3000 entries over
# 3 pages of 1000 (page 4 returns nothing, whatever the window). Every day of new
# activity therefore pushes the oldest day permanently out of reach. Archived
# entries are merged with whatever is already committed and never dropped, so
# running this regularly ratchets the history further back than the API can still
# reach. Miss a long enough stretch and that stretch is gone for good.
#
# Windowing: the 3000-entry cap applies per query, so a single wide query would
# silently truncate the oldest end. This walks backwards in 15-day windows
# instead, each far below the cap, and stops after 3 consecutive empty windows.
#
# Config + token: identical to cf-sync.sh — ACCOUNT_ID from cf-sync.conf, token
# from $CLOUDFLARE_API_TOKEN or Keychain item 'cloudflare-api-token-<ACCOUNT_ID>'.
# Read-only; needs no permission cf-sync.sh doesn't already use.
#
# Output: audit-log.jsonl — one event per line, keys sorted, ordered by (when, id).
# Deterministic and append-mostly, so a re-run shows up as added lines only.
#
# PII: actor.ip is stripped before writing. It is the one field in the payload
# with no reconstruction value and real privacy weight (staff home IPs, in a repo
# colleagues clone). Actor email is kept — it attributes changes, and it is work
# email already present throughout this repo's git history.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=audit-log.jsonl
WINDOW_DAYS=15
MAX_WINDOWS=60          # ~2.5 years, comfortably past the 18-month retention wall
DRY_WINDOWS_TO_STOP=3

command -v jq >/dev/null || { echo "jq is required — brew install jq" >&2; exit 1; }

[ -f cf-sync.conf ] || { echo "cf-sync.conf not found (must run from the repo)" >&2; exit 1; }
# shellcheck disable=SC1091
. ./cf-sync.conf
[ -n "${ACCOUNT_ID:-}" ] || { echo "ACCOUNT_ID not set in cf-sync.conf" >&2; exit 1; }
KEYCHAIN_SERVICE="cloudflare-api-token-$ACCOUNT_ID"

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  CLOUDFLARE_API_TOKEN=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null) || {
    echo "No token in \$CLOUDFLARE_API_TOKEN or Keychain item '$KEYCHAIN_SERVICE'." >&2
    echo "Run scripts/cf-sync.sh once to store one (runbook §0.2)." >&2
    exit 1
  }
  export CLOUDFLARE_API_TOKEN
fi

# BSD date: -v adjustments MUST precede -f, and the +format MUST be last —
# any other order silently prints the unadjusted date in the default format.
back_days() { date -u -j -v-"$2"d -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%Y-%m-%dT%H:%M:%SZ; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
[ -f "$OUT" ] && cp "$OUT" "$TMP/acc.jsonl" || : > "$TMP/acc.jsonl"
BEFORE_COUNT=$(wc -l < "$TMP/acc.jsonl" | tr -d ' ')

cur=$(date -u +%Y-%m-%dT%H:%M:%SZ)
limit_days="${1:-}"
walked=0 dry=0 fetched=0

for _ in $(seq 1 $MAX_WINDOWS); do
  start=$(back_days "$cur" "$WINDOW_DAYS")
  n_window=0
  for page in 1 2 3; do
    resp=$(curl -s --retry 3 -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/audit_logs?since=$start&before=$cur&per_page=1000&page=$page") || {
        echo "Cloudflare unreachable for $start..$cur page $page — aborting without writing." >&2
        exit 1
      }
    if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
      # Asking for a window older than retention is a 400, not an empty result —
      # that IS the wall, so stop and keep everything gathered so far.
      msg=$(jq -r '[.errors[]?.message] | join("; ")' <<<"$resp" 2>/dev/null || true)
      case "$msg" in
        *"18 months"*|*"Invalid format for field: since"*|*"Invalid format for field: before"*)
          echo "  retention wall reached: $msg"
          break 2 ;;
        *)
          echo "Cloudflare API error for $start..$cur page $page: ${msg:-unknown} — aborting without writing." >&2
          exit 1 ;;
      esac
    fi
    n=$(jq '.result | length' <<<"$resp")
    jq -c '.result[]?' <<<"$resp" >> "$TMP/acc.jsonl"
    n_window=$((n_window + n))
    [ "$n" -lt 1000 ] && break
    [ "$page" = 3 ] && echo "  WARNING $start..$cur hit the 3-page cap — window may be truncated" >&2
  done
  fetched=$((fetched + n_window))
  printf '  %s .. %s  %5d events\n' "${start:0:10}" "${cur:0:10}" "$n_window"
  walked=$((walked + WINDOW_DAYS))
  cur="$start"
  if [ "$n_window" -eq 0 ]; then
    dry=$((dry + 1)); [ "$dry" -ge "$DRY_WINDOWS_TO_STOP" ] && break
  else
    dry=0
  fi
  [ -n "$limit_days" ] && [ "$walked" -ge "$limit_days" ] && break
done

# Merge: strip actor.ip, dedupe on the event id, order by (when, id), stable keys.
jq -s -S 'map(del(.actor.ip)) | unique_by(.id) | sort_by(.when, .id) | .[]' \
  "$TMP/acc.jsonl" | jq -c -S . > "$TMP/out.jsonl"
mv "$TMP/out.jsonl" "$OUT"

AFTER_COUNT=$(wc -l < "$OUT" | tr -d ' ')
echo
echo "fetched $fetched events over ${walked}d; archive $BEFORE_COUNT -> $AFTER_COUNT lines (+$((AFTER_COUNT - BEFORE_COUNT)))"
echo "oldest: $(head -1 "$OUT" | jq -r .when)"
echo "newest: $(tail -1 "$OUT" | jq -r .when)"
