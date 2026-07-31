#!/usr/bin/env bash
# Cloudflare config sync — read-only capture of live config into this repo.
#
# Usage:
#   scripts/cf-sync.sh                     interactive menus: zone, then record type
#                                          (Enter = default = ALL for both)
#   scripts/cf-sync.sh all [type]          sync every zone (non-interactive; alias: tf)
#   scripts/cf-sync.sh <zone-name> [type]  sync one zone, e.g. example.com
#   scripts/cf-sync.sh zones               refresh zones.txt only
# type: dns | rulesets | pagerules | settings     (omitted = all types)
# With no argument and no terminal (cron/automation), behaves like "all".
# Dependencies (jq, terraform, cf-terraforming) are checked on start; if missing,
# the script prints the install commands and offers to run them via Homebrew.
#
# Progress: one line per artifact —  [NN/NN] <zone> <type> <status (count)>
# where status is NEW / UPDATED / unchanged / REMOVED / none / FAILED.
#
# Token: uses $CLOUDFLARE_API_TOKEN if already set, otherwise loads it from the
# macOS Keychain item 'cloudflare-api-token' (runbook §0.2). Never writes it to disk.
#
# Layout it maintains (all committed):
#   zones.txt                      fleet index: <zone-id> <zone-name>
#   terraform/dns-<zone>.tf        DNS records
#   terraform/settings-<zone>.tf   zone settings (incl. SSL/TLS)
#   terraform/rulesets-<zone>.tf   rulesets: redirect/transform/WAF/... phases
#   terraform/pagerules-<zone>.tf  legacy Page Rules
# An empty result (e.g. zone has no page rules) produces no file, and removes a
# stale one — absence of the file means "zone has none of these".
# Account-level Bulk Redirects: none in this account (verified 2026-07-31) — not captured.
set -euo pipefail
cd "$(dirname "$0")/.."

# Verify required tools exist; print runbook §0.1's install commands for any that
# are missing and, when interactive, offer to run them via Homebrew right away.
check_deps() {
  local missing=() cmds=() m c ans
  command -v jq              >/dev/null || missing+=(jq)
  command -v terraform       >/dev/null || missing+=(terraform)
  command -v cf-terraforming >/dev/null || missing+=(cf-terraforming)
  [ ${#missing[@]} -eq 0 ] && return 0
  echo "Missing dependencies: ${missing[*]}" >&2
  if ! command -v brew >/dev/null; then
    echo "Homebrew is required to install them — see https://brew.sh, then re-run." >&2
    exit 1
  fi
  for m in "${missing[@]}"; do
    case "$m" in
      jq)              cmds+=("brew install jq") ;;
      terraform)       cmds+=("brew tap hashicorp/tap && brew install hashicorp/tap/terraform") ;;
      cf-terraforming) cmds+=("brew tap cloudflare/cloudflare && brew install cloudflare/cloudflare/cf-terraforming") ;;
    esac
  done
  printf '  %s\n' "${cmds[@]}" >&2
  if [ ! -t 0 ]; then
    echo "Non-interactive run — install the above and re-run." >&2
    exit 1
  fi
  read -rp "Install now via Homebrew? [Y/n]: " ans
  case "${ans:-Y}" in [Yy]*) ;; *) exit 1 ;; esac
  for c in "${cmds[@]}"; do eval "$c"; done
  for m in "${missing[@]}"; do
    command -v "$m" >/dev/null || { echo "$m still missing after install — aborting." >&2; exit 1; }
  done
}

verify_token() { # 0 = valid, 1 = rejected, 2 = Cloudflare unreachable
  local resp
  resp=$(curl -s --max-time 15 -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/user/tokens/verify") || return 2
  jq -e '.success and (.result.status == "active")' <<<"$resp" >/dev/null 2>&1 || return 1
}

# Load the token (env var wins, else Keychain) and verify it against the API.
# If it's missing or rejected and we're interactive, offer to paste a new one —
# straight into the Keychain via security's hidden prompt, never through argv,
# shell history, or a file — then re-verify.
ensure_token() {
  local from="environment" rc ans
  if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
    from="Keychain"
    CLOUDFLARE_API_TOKEN=$(security find-generic-password -s cloudflare-api-token -w 2>/dev/null) || CLOUDFLARE_API_TOKEN=""
    export CLOUDFLARE_API_TOKEN
  fi
  while :; do
    if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
      rc=0; verify_token || rc=$?
      case $rc in
        0) return 0 ;;
        2) echo "Cloudflare API unreachable — check network and retry." >&2; exit 1 ;;
        *) echo "Cloudflare rejected the API token from the $from." >&2 ;;
      esac
    else
      echo "No Cloudflare API token found (env or Keychain item 'cloudflare-api-token')."
    fi
    if [ ! -t 0 ]; then
      echo "Non-interactive run — cannot prompt for a token. See runbook §0.2." >&2
      exit 1
    fi
    read -rp "Store a new token in the Keychain now? [Y/n]: " ans
    case "${ans:-Y}" in [Yy]*) ;; *) exit 1 ;; esac
    echo "Paste the token at the hidden prompt:"
    security add-generic-password -U -a "$USER" -s cloudflare-api-token -w
    CLOUDFLARE_API_TOKEN=$(security find-generic-password -s cloudflare-api-token -w)
    export CLOUDFLARE_API_TOKEN
    from="Keychain"
  done
}

TFBIN=""  # resolved after check_deps
FAILURES=0
ZIDX=0 ZTOTAL=0 ZNAME=""

api() { curl -sf --retry 3 -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4$1"; }

# cf-terraforming suffixes resource names with a positional counter (_0, _1, ...);
# one inserted/deleted resource would rename every later one — strip it so names
# are keyed by the stable id alone and diffs stay minimal. $1 (optional) prefixes
# names for types whose ids are NOT globally unique: zone-setting names repeat in
# every zone, and cf-terraforming loads this very directory to read the provider
# schema — one cross-zone name collision bricks every later call, for all zones.
stabilize() {
  local prefix="${1:-}"
  sed -E 's/^(resource "cloudflare_[a-z0-9_]+" "terraform_managed_resource_.+)_[0-9]+"/\1"/' \
    | sed -E "s/^(resource \"cloudflare_[a-z0-9_]+\" \"terraform_managed_resource_)/\1$prefix/"
}

progress() { # $1 = outfile, $2 = status text
  local base="${1##*/}"
  printf '[%02d/%02d] %-26s %-9s %s\n' "$ZIDX" "$ZTOTAL" "$ZNAME" "${base%%-*}" "$2"
}

# gen_to <outfile> <name-prefix> <resource-type> [extra args...]
# Retries transient failures with backoff. Only touches <outfile> after a
# SUCCESSFUL generate: non-empty output replaces it, empty output removes it
# (zone genuinely has none). On persistent failure the previous file is kept,
# the failure is logged, and the run continues (non-zero exit at the end).
gen_to() {
  local out="$1" prefix="$2" rt="$3" attempt tmp err n status
  shift 3
  tmp=$(mktemp) err=$(mktemp)
  for attempt in 1 2 3; do
    if cf-terraforming generate --resource-type "$rt" \
         --terraform-install-path terraform --terraform-binary-path "$TFBIN" \
         "$@" 2>"$err" | stabilize "$prefix" > "$tmp"; then
      if [ -s "$tmp" ]; then
        n=$(grep -c '^resource ' "$tmp" || true)
        if [ -f "$out" ] && cmp -s "$tmp" "$out"; then status="unchanged ($n)"
        elif [ -f "$out" ]; then status="UPDATED ($n)"
        else status="NEW ($n)"; fi
        mv "$tmp" "$out"
      else
        if [ -f "$out" ]; then status="REMOVED"; else status="none"; fi
        rm -f "$tmp" "$out"
      fi
      rm -f "$err"
      progress "$out" "$status"
      return 0
    fi
    sleep $((attempt * 2))
  done
  progress "$out" "FAILED after 3 attempts — kept previous file"
  tail -1 "$err" >&2
  rm -f "$tmp" "$err"
  FAILURES=$((FAILURES + 1))
  return 0
}

sync_zones() {
  local page=1 total resp
  : > zones.txt
  while :; do
    resp=$(api "/zones?per_page=50&page=$page")
    jq -r '.result[] | .id + " " + .name' <<<"$resp" >> zones.txt
    total=$(jq -r '.result_info.total_pages' <<<"$resp")
    [ "$page" -ge "$total" ] && break
    page=$((page + 1))
  done
  echo "zones: $(wc -l < zones.txt | tr -d ' ')"
}

check_type() { # validate a type filter ("" = all types)
  case "${1:-}" in
    ""|dns|rulesets|pagerules|settings) ;;
    *) echo "unknown type: $1 (dns | rulesets | pagerules | settings)" >&2; exit 1 ;;
  esac
}

sync_tf() { # $1 (optional) = single zone name; $2 (optional) = single type
  local filter="${1:-}" tsel="${2:-}" ids slug zid zname
  if [ -n "$filter" ]; then ZTOTAL=1; else ZTOTAL=$(wc -l < zones.txt | tr -d ' '); fi
  ZIDX=0
  echo
  echo "Syncing ${filter:-ALL ZONES} (${tsel:-all types}):"
  while read -r zid zname; do
    [ -n "$filter" ] && [ "$zname" != "$filter" ] && continue
    ZIDX=$((ZIDX + 1)) ZNAME="$zname"
    if [ -z "$tsel" ] || [ "$tsel" = dns ]; then
      gen_to "terraform/dns-$zname.tf"       "" cloudflare_dns_record --zone "$zid"
    fi
    if [ -z "$tsel" ] || [ "$tsel" = rulesets ]; then
      gen_to "terraform/rulesets-$zname.tf"  "" cloudflare_ruleset    --zone "$zid"
    fi
    if [ -z "$tsel" ] || [ "$tsel" = pagerules ]; then
      gen_to "terraform/pagerules-$zname.tf" "" cloudflare_page_rule  --zone "$zid"
    fi
    if [ -z "$tsel" ] || [ "$tsel" = settings ]; then
      # zone_setting won't enumerate itself — feed it the zone's setting ids (sorted
      # for deterministic output order); zone-prefix the names (see stabilize)
      slug=$(echo "$zname" | tr '.-' '__')
      ids=$(api "/zones/$zid/settings" | jq -r '.result[].id' | sort | paste -sd, -)
      gen_to "terraform/settings-$zname.tf"  "${slug}_" cloudflare_zone_setting --zone "$zid" \
        --resource-id "cloudflare_zone_setting=$ids"
    fi
  done < zones.txt
  if [ "$FAILURES" -gt 0 ]; then
    echo "sync finished with $FAILURES failed generate(s) — previous files kept" >&2
    return 1
  fi
}

type_menu() { # sets TYPE_SEL ("" = all types); Enter defaults to 0; number or name
  local choice
  echo
  echo "Record types:"
  echo "  1 - dns"
  echo "  2 - rulesets"
  echo "  3 - pagerules"
  echo "  4 - settings"
  echo
  echo "  0 - ALL TYPES"
  echo
  while :; do
    read -rp "Sync which types (number or name)? [0]: " choice
    case "${choice:-0}" in
      0)              TYPE_SEL="" ;;
      1|dns)          TYPE_SEL="dns" ;;
      2|rulesets)     TYPE_SEL="rulesets" ;;
      3|pagerules)    TYPE_SEL="pagerules" ;;
      4|settings)     TYPE_SEL="settings" ;;
      *) echo "invalid selection: $choice — enter 0-4 or a type name" >&2; continue ;;
    esac
    break
  done
}

menu() {
  local i=1 zname choice max zsel
  while read -r _ zname; do
    printf '%3d - %s\n' "$i" "$zname"
    i=$((i + 1))
  done < zones.txt
  max=$((i - 1))
  echo
  echo "  0 - ALL ZONES"
  echo
  while :; do
    read -rp "Sync which zone (number or name)? [0]: " choice
    choice=${choice:-0}
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if [ "$choice" -le "$max" ]; then
        zsel=""
        [ "$choice" -gt 0 ] && zsel=$(awk -v n="$choice" 'NR==n{print $2}' zones.txt)
        break
      fi
    elif awk -v z="$choice" '$2==z{found=1} END{exit !found}' zones.txt; then
      zsel="$choice"
      break
    fi
    echo "invalid selection: $choice — enter 0-$max or an exact zone name" >&2
  done
  if [ -z "$zsel" ]; then
    # ALL ZONES is slow — offer a type filter; a single zone is fast, sync all types
    type_menu
    sync_tf "" "$TYPE_SEL"
  else
    sync_tf "$zsel" ""
  fi
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,18p' "$0"
  exit 0
fi

check_deps
TFBIN=$(command -v terraform)
ensure_token

case "${1:-}" in
  "")     sync_zones
          if [ -t 0 ]; then menu; else sync_tf; fi ;;
  all|tf) check_type "${2:-}"; sync_zones; sync_tf "" "${2:-}" ;;
  zones)  sync_zones ;;
  *)      check_type "${2:-}"; sync_zones
          if awk -v z="$1" '$2==z{found=1} END{exit !found}' zones.txt; then
            sync_tf "$1" "${2:-}"
          else
            echo "unknown zone: $1 — run with no args for the menu" >&2
            exit 1
          fi ;;
esac
