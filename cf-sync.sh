#!/usr/bin/env bash
# Cloudflare config sync — read-only capture of live config into this repo.
#
# Usage:
#   scripts/cf-sync.sh                     interactive menus: zone/account, then type
#                                          (Enter = default = ALL for both)
#   scripts/cf-sync.sh all [type]          sync everything (non-interactive; alias: tf)
#   scripts/cf-sync.sh <zone-name> [type]  sync one zone, e.g. example.com
#   scripts/cf-sync.sh account [type]      account-level artifacts only
#   scripts/cf-sync.sh zones               refresh the zone indexes only
# type (zone):    dns | rulesets | pagerules | settings | waf   (omitted = all types)
# type (account): workers | d1 | r2 | kv | queues | registrar | waf | notifications
# With no argument and no terminal (cron/automation), behaves like "all".
# Dependencies (jq, terraform, cf-terraforming) are checked on start; if missing,
# the script prints the install commands and offers to run them via Homebrew.
#
# Progress: one line per artifact —  [NN/NN] <zone> <type> <status (count)>
# where status is NEW / UPDATED / unchanged / REMOVED / none / skipped / FAILED.
#
# Config: cf-sync.conf at the repo root (committed, mandatory) declares the ONE
# per-repo setting — ACCOUNT_ID, the Cloudflare account this repo captures.
# Everything account-specific derives from it, including the Keychain item name
# 'cloudflare-api-token-<ACCOUNT_ID>', so this script is byte-identical across
# per-account repos and features port by plain file copy.
#
# Token: uses $CLOUDFLARE_API_TOKEN if already set, otherwise loads it from that
# macOS Keychain item (runbook §0.2). Never writes it to disk. The token is
# verified to actually see $ACCOUNT_ID before any capture, so a wrong token in
# the right slot can never capture the wrong account's config into this repo.
#
# Layout it maintains (all committed):
#   zones.txt                      fleet index: <zone-id> <zone-name>
#   zones-meta.tsv                 per-zone metadata: name, plan, status, type,
#                                  paused, assigned nameservers (tab-separated)
#   workers.txt                    Worker inventory: <script-name> <created-date>
#   registrar.txt                  Cloudflare-registered domains: <name> <registered> <expires>
#   terraform/dns-<zone>.tf        DNS records
#   terraform/settings-<zone>.tf   zone settings (incl. SSL/TLS)
#   terraform/rulesets-<zone>.tf   rulesets: redirect/transform/WAF/... phases
#   terraform/pagerules-<zone>.tf  legacy Page Rules
#   terraform/waf-<zone>.tf        WAF-family zone config held OUTSIDE the rulesets
#                                  API: Bot Fight Mode / Super Bot Fight Mode,
#                                  leaked-credential detection (+ its custom
#                                  detection rules while enabled), IP Access Rules,
#                                  Zone Lockdowns, User Agent Blocking rules. The
#                                  WAF rules themselves (custom rules, managed-
#                                  ruleset deployments and overrides, rate limits,
#                                  DDoS overrides) are zone rulesets -> rulesets-*.tf
#   terraform/account-*.tf         account-scoped config: Workers custom domains &
#                                  cron triggers, D1 databases, R2 buckets & custom
#                                  domains, KV namespaces, Queues & consumers,
#                                  Registrar settings (auto-renew/lock/privacy),
#                                  WAF lists + list items + account IP Access Rules,
#                                  notification policies
# An empty result (e.g. zone has no page rules) produces no file, and removes a
# stale one — absence of the file means "zone has none of these".
# Deliberately NOT captured — wiring, not code/data: Worker script code + bindings
# (each app's own repo + wrangler are the source of truth), D1 schema/data, R2
# object contents, KV values, queue messages, secret values (write-only at the
# API), WHOIS contact PII, and registration state for domains registered outside
# this account (out of scope: this repo captures the account's own config).
# Worker routes and R2 CORS/lifecycle rules are unsupported by
# cf-terraforming v0.28 — add jq-to-HCL fallbacks if ever used. R2 artifacts
# report "skipped" until R2 is enabled on the account (dashboard toggle).
# Notification webhook destinations are not captured either: their URLs are
# bearer secrets (policies reference them by id only). Legacy rate limits and
# firewall rules have no API any more (410 Gone / migrated to rulesets).
# List ITEMS are rendered by this script, not cf-terraforming: their endpoint
# is cursor-paginated and 0.28.0 only follows page/total_pages (it would emit
# the first page only, exit 0) and it writes each item's own id into list_id.
# Account-level Bulk Redirects are NOT captured — verify none exist in this account.
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
    CLOUDFLARE_API_TOKEN=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null) || CLOUDFLARE_API_TOKEN=""
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
      echo "No Cloudflare API token found (env or Keychain item '$KEYCHAIN_SERVICE')."
    fi
    if [ ! -t 0 ]; then
      echo "Non-interactive run — cannot prompt for a token. See runbook §0.2." >&2
      exit 1
    fi
    read -rp "Store a new token in the Keychain now? [Y/n]: " ans
    case "${ans:-Y}" in [Yy]*) ;; *) exit 1 ;; esac
    echo "Paste the token at the hidden prompt:"
    security add-generic-password -U -a "$USER" -s "$KEYCHAIN_SERVICE" -w
    CLOUDFLARE_API_TOKEN=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w)
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

# stabilize's counter-strip assumes cf-terraforming keyed the name by a unique
# payload id — but most ACCOUNT-level list payloads carry no top-level "id"
# (D1 has uuid, R2 the bucket name, queues queue_id, ...), so cf-terraforming
# falls back to the ACCOUNT id and stripped names would all collide into one
# duplicate address (invalid HCL that would then brick every later generate,
# which loads this directory for the provider schema). rekey renames each block
# from a type-specific attribute that IS stable and unique instead.
rekey() { # $1 = key attribute inside the block, $2 = resource-name prefix
  awk -v attr="$1" -v prefix="$2" '
    /^resource "/ { inblock=1; n=0; split("", buf); key="" }
    inblock {
      buf[++n]=$0
      if ($1 == attr && $2 == "=" && key == "") { key=$3; gsub(/"/, "", key) }
      if ($0 == "}") {
        if (key != "") {
          gsub(/[^a-zA-Z0-9]/, "_", key)
          sub(/"terraform_managed_resource_[^"]*"/, "\"terraform_managed_resource_" prefix key "\"", buf[1])
        }
        for (i=1; i<=n; i++) print buf[i]
        inblock=0
      }
      next
    }
    { print }
  '
}

progress() { # $1 = outfile, $2 = status text
  local base="${1##*/}" label
  base="${base%.tf}"
  case "$base" in
    account-*) label="${base#account-}" ;;   # account-workers-crons -> workers-crons
    *)         label="${base%%-*}" ;;        # dns-example.com -> dns
  esac
  printf '[%02d/%02d] %-26s %-16s %s\n' "$ZIDX" "$ZTOTAL" "$ZNAME" "$label" "$2"
}

# run_gen <outtmp> <name-spec> <resource-type> [extra args...]
# One cf-terraforming generate into <outtmp> (truncated per attempt), resource
# names made diff-stable. <name-spec> is "<prefix>" (stabilize: payload-id keyed)
# or "<prefix>@<attr>" (rekey: for account types without payload ids).
# Retries transient failures with backoff. 0 = success, 1 = persistent failure
# (last error line echoed to stderr).
run_gen() {
  local tmp="$1" spec="$2" rt="$3" attempt err prefix attr=""
  shift 3
  prefix="${spec%%@*}"
  [ "$spec" = "$prefix" ] || attr="${spec#*@}"
  err=$(mktemp)
  for attempt in 1 2 3; do
    if cf-terraforming generate --resource-type "$rt" \
         --terraform-install-path terraform --terraform-binary-path "$TFBIN" \
         "$@" 2>"$err" \
       | { if [ -n "$attr" ]; then rekey "$attr" "$prefix"; else stabilize "$prefix"; fi; } > "$tmp"; then
      rm -f "$err"
      return 0
    fi
    sleep $((attempt * 2))
  done
  tail -1 "$err" >&2
  rm -f "$err"
  return 1
}

# commit_out <outfile> <tmpfile> — install a SUCCESSFULLY generated result:
# non-empty output replaces <outfile>, empty output removes it (zone/account
# genuinely has none). Consumes <tmpfile>.
commit_out() {
  local out="$1" tmp="$2" n status
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
  progress "$out" "$status"
}

gen_failed() { # $1 = outfile, $2 = failure detail
  progress "$1" "FAILED $2 — kept previous file"
  FAILURES=$((FAILURES + 1))
}

# gen_to <outfile> <name-spec> <resource-type> [extra args...]
# Single-generate artifact. Only touches <outfile> after a SUCCESSFUL generate;
# on persistent failure the previous file is kept, the failure is logged, and
# the run continues (non-zero exit at the end).
gen_to() {
  local out="$1" prefix="$2" tmp
  shift 2
  tmp=$(mktemp)
  if run_gen "$tmp" "$prefix" "$@"; then
    commit_out "$out" "$tmp"
  else
    gen_failed "$out" "after 3 attempts"
    rm -f "$tmp"
  fi
  return 0
}

# gen_multi <outfile> <name-spec> <resource-type> <parent-lister-fn>
# For types cf-terraforming can only generate per parent (--resource-id): one
# generate per id printed by <parent-lister-fn>, concatenated into a single
# artifact. All-or-nothing: any listing/generate failure keeps the previous
# file, so a transient API error can never masquerade as "parent deleted".
gen_multi() {
  local out="$1" prefix="$2" rt="$3" lister="$4" ids id tmp part
  if ! ids=$("$lister"); then
    gen_failed "$out" "to list parent resources"
    return 0
  fi
  tmp=$(mktemp) part=$(mktemp)
  : > "$tmp"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if run_gen "$part" "$prefix" "$rt" --account "$ACCOUNT_ID" \
         --resource-id "$rt=$id" </dev/null; then
      cat "$part" >> "$tmp"
    else
      gen_failed "$out" "after 3 attempts ($rt=$id)"
      rm -f "$tmp" "$part"
      return 0
    fi
  done <<<"$ids"
  commit_out "$out" "$tmp"
  rm -f "$part"
  return 0
}

# Fleet indexes, refreshed together: zones.txt (id + name — drives the sync
# loop) and zones-meta.tsv (per-zone account-side metadata the HCL artifacts
# don't include: plan tier, status, type, paused flag, assigned nameservers —
# the delegation baseline to verify against each domain's registrar). Both are
# built in temp files and installed only after every page pulls successfully.
sync_zones() {
  local page=1 total resp ztmp mtmp
  ztmp=$(mktemp) mtmp=$(mktemp)
  while :; do
    resp=$(api "/zones?per_page=50&page=$page")
    if ! jq -e '.success == true and (.result | type) == "array"' <<<"$resp" >/dev/null 2>&1; then
      rm -f "$ztmp" "$mtmp"
      echo "unexpected zone-list response (page $page) — kept previous zone indexes" >&2
      return 1
    fi
    jq -r '.result[] | .id + " " + .name' <<<"$resp" >> "$ztmp"
    jq -r '.result[] | [.name, (.plan.name // "?"), (.status // "?"), (.type // "?"),
      (.paused | tostring), ((.name_servers // []) | join(","))] | @tsv' <<<"$resp" >> "$mtmp"
    total=$(jq -r '.result_info.total_pages' <<<"$resp")
    [ "$page" -ge "$total" ] && break
    page=$((page + 1))
  done
  mv "$ztmp" zones.txt
  mv "$mtmp" zones-meta.tsv
  echo "zones: $(wc -l < zones.txt | tr -d ' ')"
}

# Verify the token can actually see the configured account. Guards every sync
# (zones included): a token for the WRONG account would otherwise capture that
# account's config straight over this repo's files. The Keychain slot name is
# derived from $ACCOUNT_ID so mix-ups are unlikely, but the $CLOUDFLARE_API_TOKEN
# env override bypasses that naming — this check closes the gap.
ensure_account() {
  api "/accounts/$ACCOUNT_ID" >/dev/null 2>&1 && return 0
  echo "token cannot access account $ACCOUNT_ID — check cf-sync.conf and Keychain item '$KEYCHAIN_SERVICE'." >&2
  exit 1
}

# R2 endpoints error until the product is enabled on the account (dashboard
# toggle, has a billing dimension). Probe and distinguish outcomes so a network
# blip or missing token scope reports FAILED, never a definitive "skipped":
# 0 = enabled, 1 = R2 not enabled (Cloudflare error 10042), 2 = probe failed.
r2_status() {
  local resp
  resp=$(curl -s --retry 3 --max-time 15 -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/r2/buckets") || return 2
  jq -e '.success == true' <<<"$resp" >/dev/null 2>&1 && return 0
  jq -e '.errors[]? | select(.code == 10042)' <<<"$resp" >/dev/null 2>&1 && return 1
  return 2
}

# Parent listers for gen_multi (one id per line). Each asserts the response
# envelope: a 200 whose shape drifted (or a success:false body) must fail the
# lister — gen_multi then keeps the previous file — rather than read as "no
# parents", which would masquerade as every parent having been deleted. They
# also fail loudly if the result is paginated beyond what was fetched.
worker_script_names() { awk '{print $1}' workers.txt; }
r2_bucket_names() {
  api "/accounts/$ACCOUNT_ID/r2/buckets" | jq -r '
    if .success == true and (.result.buckets | type) == "array"
       and ((.result_info.cursor // "") == "")
    then .result.buckets[] | (.name // error("bucket without name"))
    else error("unexpected R2 bucket-list response") end'
}
queue_ids() {
  api "/accounts/$ACCOUNT_ID/queues" | jq -r '
    if .success == true and (.result | type) == "array"
       and ((.result_info.total_pages // 1) <= 1)
    then .result[] | (.queue_id // .id // error("queue without id"))
    else error("unexpected queue-list response") end'
}

# render_list_items <account-id> <list-id> <list-kind>: JSON array of list
# items on stdin -> cloudflare_list_item HCL on stdout, sorted by item id,
# named litem_<list-id>_<item-id> so diffs group by list. Only the attributes
# the provider schema declares settable are written (ip | asn | hostname{} |
# redirect{} per list kind, plus comment); timestamps are left out. Strings
# are JSON-quoted (valid HCL) with ${ and %{ escaped so nothing interpolates.
render_list_items() {
  jq -r --arg acct "$1" --arg list "$2" --arg kind "$3" '
    def h: tojson | gsub("\\$\\{"; "$${") | gsub("%\\{"; "%%{");
    def v: if type == "string" then h elif type == "boolean" or type == "number" then tostring
           else error("unsupported list-item value") end;
    def obj($name): "  \($name) = {\n" + (to_entries | sort_by(.key) | map("    \(.key) = \(.value | v)\n") | join("")) + "  }\n";
    sort_by(.id) | .[]
    | "resource \"cloudflare_list_item\" \"terraform_managed_resource_litem_\($list)_\(.id // error("item without id"))\" {\n"
      + "  account_id = \($acct | h)\n  list_id = \($list | h)\n"
      + (if .comment != null then "  comment = \(.comment | h)\n" else "" end)
      + (if   $kind == "ip"       then "  ip = \(.ip // error("ip item without ip") | h)\n"
         elif $kind == "asn"      then "  asn = \(.asn // error("asn item without asn"))\n"
         elif $kind == "hostname" then (.hostname // error("hostname item without hostname") | obj("hostname"))
         elif $kind == "redirect" then (.redirect // error("redirect item without redirect") | obj("redirect"))
         else error("unknown list kind \($kind)") end)
      + "}\n"'   # jq adds the newline that separates blocks
}

# Account lists' items (see the header note on why cf-terraforming is not
# used for this type): every list is walked with per_page=500 until the
# cursor runs dry, then rendered and canonicalised with terraform fmt.
# All-or-nothing: any listing, fetch, envelope or render failure keeps the
# previous file. No lists / no items -> no file, like every other artifact.
sync_list_items() {
  local out="terraform/account-waf-list-items.tf" lists tmp items resp cursor id kind
  if ! lists=$(api "/accounts/$ACCOUNT_ID/rules/lists" | jq -r '
       if .success == true and (.result | type) == "array"
          and ((.result_info.total_pages // 1) <= 1)
       then .result[] | (.id // error("list without id")) + " " + (.kind // error("list without kind"))
       else error("unexpected list-list response") end' | sort); then
    gen_failed "$out" "to list account lists"
    return 0
  fi
  tmp=$(mktemp) items=$(mktemp)
  : > "$tmp"
  while read -r id kind; do
    [ -n "$id" ] || continue
    : > "$items"
    cursor=""
    while :; do
      if ! resp=$(api "/accounts/$ACCOUNT_ID/rules/lists/$id/items?per_page=500${cursor:+&cursor=$cursor}") \
         || ! jq -e '.success == true and (.result | type) == "array"' <<<"$resp" >/dev/null 2>&1; then
        gen_failed "$out" "to fetch items of list $id"
        rm -f "$tmp" "$items"
        return 0
      fi
      jq -c '.result[]' <<<"$resp" >> "$items"
      cursor=$(jq -r '.result_info.cursors.after // ""' <<<"$resp")
      [ -n "$cursor" ] || break
    done
    if ! jq -s '.' "$items" | render_list_items "$ACCOUNT_ID" "$id" "$kind" >> "$tmp"; then
      gen_failed "$out" "to render items of list $id"
      rm -f "$tmp" "$items"
      return 0
    fi
  done <<<"$lists"
  rm -f "$items"
  if [ -s "$tmp" ] && ! "$TFBIN" fmt - < "$tmp" > "$tmp.fmt"; then
    gen_failed "$out" "to format rendered list items"
    rm -f "$tmp" "$tmp.fmt"
    return 0
  fi
  [ -s "$tmp" ] && mv "$tmp.fmt" "$tmp"
  commit_out "$out" "$tmp"
  return 0
}

# filter_blocks <file> <ids>: keep only the resource blocks whose name ends in
# _<id> for an id in <ids> (newline-separated); rewrites <file> in place.
# Empty <ids> keeps nothing.
filter_blocks() {
  local re
  re=$(printf '%s\n' "$2" | awk 'NF' | paste -sd'|' -)   # awk, not grep: an empty set must not fail under set -e
  awk -v re="$re" '
    skipblank && /^$/ { skipblank = 0; next }
    { skipblank = 0 }
    /^resource "/ { drop = (re == "" || $0 !~ ("_(" re ")\" \\{$")) }
    !drop { print }
    drop && /^}$/ { drop = 0; skipblank = 1 }
  ' "$1" > "$1.f" && mv "$1.f" "$1"
}

# Registrar lifecycle index: Cloudflare-registered domains with registration
# and expiry dates. The managed settings (auto-renew/lock/privacy) live in
# terraform/account-registrar.tf; WHOIS contact PII is deliberately never
# captured. Domains registered OUTSIDE this account (e.g. at another registrar)
# are out of scope by design — this repo captures the account's own config.
sync_registrar_txt() { # 0 = registrar.txt refreshed; 1 = FAILED (previous file kept)
  local tmp
  tmp=$(mktemp)
  if api "/accounts/$ACCOUNT_ID/registrar/domains" | jq -r '
       if .success == true and (.result | type) == "array"
          and ((.result_info.total_pages // 1) <= 1)
       then .result[] | (.name // error("domain without name")) + " "
            + ((.registered_at // "?") | split(".")[0]) + " "
            + ((.expires_at // "?") | split(".")[0])
       else error("unexpected registrar-domain response") end' | sort > "$tmp"; then
    mv "$tmp" registrar.txt
    echo "registrar domains: $(wc -l < registrar.txt | tr -d ' ')"
  else
    rm -f "$tmp"
    gen_failed registrar.txt "to list registrar domains"
    return 1
  fi
}

# Worker inventory: stable fields only (name + creation date). Deliberately
# excludes etag/modified_on (churn on every deploy) and code/bindings (each
# app's own repo + wrangler are the source of truth for those). Never-clobber:
# built in a temp file, workers.txt only replaced on a fully successful pull.
sync_workers_txt() { # 0 = workers.txt refreshed; 1 = FAILED (previous file kept)
  local tmp
  tmp=$(mktemp)
  if api "/accounts/$ACCOUNT_ID/workers/scripts" | jq -r '
       if .success == true and (.result | type) == "array"
          and ((.result_info.total_pages // 1) <= 1)
       then .result[] | (.id // error("script without id")) + " "
            + ((.created_on // "") | split(".")[0])
       else error("unexpected script-list response") end' | sort > "$tmp"; then
    mv "$tmp" workers.txt
    echo "workers: $(wc -l < workers.txt | tr -d ' ')"
  else
    rm -f "$tmp"
    gen_failed workers.txt "to list Worker scripts"
    return 1
  fi
}

sync_account() { # $1 (optional) = single account type: workers | d1 | r2 | kv | queues | registrar | waf | notifications
  local tsel="${1:-}" rc
  ZIDX=1 ZTOTAL=1 ZNAME="(account)"
  echo
  echo "Syncing ACCOUNT-LEVEL (${tsel:-all types}):"
  # Name-specs: "<prefix>@<attr>" types rekey from that attribute because their
  # payloads carry no top-level id (see rekey); plain "<prefix>" types have
  # real payload ids and use stabilize.
  if [ -z "$tsel" ] || [ "$tsel" = workers ]; then
    if sync_workers_txt; then
      gen_multi "terraform/account-workers-crons.tf" "wcron_@script_name" cloudflare_workers_cron_trigger worker_script_names
    else
      gen_failed "terraform/account-workers-crons.tf" "(worker inventory unavailable)"
    fi
    gen_to    "terraform/account-workers-domains.tf" "wdom_"  cloudflare_workers_custom_domain --account "$ACCOUNT_ID"
  fi
  if [ -z "$tsel" ] || [ "$tsel" = d1 ]; then
    gen_to    "terraform/account-d1.tf"              "d1_@name" cloudflare_d1_database         --account "$ACCOUNT_ID"
  fi
  if [ -z "$tsel" ] || [ "$tsel" = r2 ]; then
    rc=0; r2_status || rc=$?
    case $rc in
      0)
        # NOTE: r2_custom_domain resource-ids are bucket names; buckets in a
        # non-default jurisdiction may need "<bucket>,<jurisdiction>" — revisit
        # on first real use (untestable until R2 is enabled and populated).
        gen_to    "terraform/account-r2.tf"          "r2_@name" cloudflare_r2_bucket           --account "$ACCOUNT_ID"
        gen_multi "terraform/account-r2-domains.tf"  "r2dom_@domain" cloudflare_r2_custom_domain r2_bucket_names
        ;;
      1)
        progress "terraform/account-r2.tf"         "skipped (R2 not enabled on account)"
        progress "terraform/account-r2-domains.tf" "skipped (R2 not enabled on account)"
        ;;
      *)
        gen_failed "terraform/account-r2.tf"         "to probe R2"
        gen_failed "terraform/account-r2-domains.tf" "to probe R2"
        ;;
    esac
  fi
  if [ -z "$tsel" ] || [ "$tsel" = kv ]; then
    gen_to    "terraform/account-kv.tf"              "kv_"    cloudflare_workers_kv_namespace  --account "$ACCOUNT_ID"
  fi
  if [ -z "$tsel" ] || [ "$tsel" = queues ]; then
    gen_to    "terraform/account-queues.tf"          "queue_@queue_name" cloudflare_queue      --account "$ACCOUNT_ID"
    gen_multi "terraform/account-queue-consumers.tf" "qcons_@queue_id" cloudflare_queue_consumer queue_ids
  fi
  if [ -z "$tsel" ] || [ "$tsel" = registrar ]; then
    sync_registrar_txt || true  # HCL below is an independent pull — attempt it regardless
    gen_to    "terraform/account-registrar.tf"       "reg_@domain_name" cloudflare_registrar_domain --account "$ACCOUNT_ID"
  fi
  if [ -z "$tsel" ] || [ "$tsel" = waf ]; then
    # Lists are what WAF custom rules reference (ip.src in $name); items are
    # generated per list. Account-level IP Access Rules apply to every zone.
    gen_to    "terraform/account-waf-lists.tf"        "list_@name" cloudflare_list        --account "$ACCOUNT_ID"
    sync_list_items
    gen_to    "terraform/account-waf-access-rules.tf" "aar_"       cloudflare_access_rule --account "$ACCOUNT_ID"
  fi
  if [ -z "$tsel" ] || [ "$tsel" = notifications ]; then
    gen_to    "terraform/account-notifications.tf"    "notif_"     cloudflare_notification_policy --account "$ACCOUNT_ID"
  fi
}

is_zone_type()    { case "$1" in dns|rulesets|pagerules|settings|waf) ;; *) return 1 ;; esac; }
is_account_type() { case "$1" in workers|d1|r2|kv|queues|registrar|waf|notifications) ;; *) return 1 ;; esac; }

check_type() { # $1 = type filter ("" = all), $2 = valid scope: zone | account | any
  local t="${1:-}" scope="${2:-any}"
  [ -z "$t" ] && return 0
  case "$scope" in
    zone)    is_zone_type "$t" && return 0
             echo "unknown type: $t (dns | rulesets | pagerules | settings | waf)" >&2 ;;
    account) is_account_type "$t" && return 0
             echo "unknown type: $t (workers | d1 | r2 | kv | queues | registrar | waf | notifications)" >&2 ;;
    *)       is_zone_type "$t" || is_account_type "$t" && return 0
             echo "unknown type: $t (zone: dns | rulesets | pagerules | settings | waf; account: workers | d1 | r2 | kv | queues | registrar | waf | notifications)" >&2 ;;
  esac
  exit 1
}

# WAF-family zone config that lives OUTSIDE the rulesets API, concatenated into
# one terraform/waf-<zone>.tf per zone. One cf-terraforming generate PER TYPE:
# given a comma-separated --resource-type list, 0.28.0 stops at the first type
# that has no resources (exit 0, later types silently missing — verified
# 2026-09-02), so a combined call could masquerade as "rule deleted".
# All-or-nothing like gen_multi: any failure keeps the previous file. Names are
# zone-prefixed like settings (see stabilize). The zone's access-rule listing
# also echoes account-wide rules (the dashboard shows both) and cf-terraforming
# drops the scope attribute that tells them apart, so the generated blocks are
# filtered down to the ids the API reports as zone-scoped — the account
# artifact already holds the rest. bot_management and leaked_credential_check
# are singletons, so the file always exists and a pull that lacks either is
# treated as a failure (token scope or API drift), never as "removed".
sync_waf() { # $1 = zone id, $2 = zone name
  local zid="$1" out="terraform/waf-$2.tf" prefix tmp part rt lcc=0 ids code
  prefix="$(echo "$2" | tr '.-' '__')_"
  tmp=$(mktemp) part=$(mktemp)
  : > "$tmp"
  for rt in cloudflare_bot_management cloudflare_leaked_credential_check \
            cloudflare_zone_lockdown cloudflare_access_rule cloudflare_user_agent_blocking_rule; do
    if ! run_gen "$part" "$prefix" "$rt" --zone "$zid" </dev/null; then
      gen_failed "$out" "after 3 attempts ($rt)"
      rm -f "$tmp" "$part"
      return 0
    fi
    case "$rt" in
      cloudflare_bot_management|cloudflare_leaked_credential_check)
        if ! grep -q "^resource \"$rt\" " "$part"; then
          gen_failed "$out" "($rt block missing — token scope or API change?)"
          rm -f "$tmp" "$part"
          return 0
        fi ;;
      cloudflare_access_rule)
        if [ -s "$part" ]; then
          if ! ids=$(api "/zones/$zid/firewall/access_rules/rules?per_page=1000" | jq -r '
               if .success == true and (.result | type) == "array"
                  and ((.result_info.total_pages // 1) <= 1)
               then .result[] | select(.scope.type == "zone") | .id
               else error("unexpected access-rule list response") end'); then
            gen_failed "$out" "to list zone access rules"
            rm -f "$tmp" "$part"
            return 0
          fi
          filter_blocks "$part" "$ids"
        fi ;;
    esac
    cat "$part" >> "$tmp"
    # Detection rules are only readable while the product is enabled (the
    # API answers 400 "product has not been enabled" otherwise, which
    # cf-terraforming treats as fatal) — gate on the flag just captured.
    [ "$rt" = cloudflare_leaked_credential_check ] \
      && grep -Eq '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true$' "$part" && lcc=1
  done
  # Custom detection locations are an Enterprise feature, so the detections
  # endpoint may keep answering 4xx on a Free/Pro zone even with detection on.
  # Probe it first: a 2xx means generate; any 4xx means "none available here"
  # (never FAILED, which would freeze this zone's file); transport errors and
  # 5xx are real failures.
  if [ "$lcc" = 1 ]; then
    code=$(curl -s -o /dev/null --retry 3 --max-time 15 -w '%{http_code}' \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$zid/leaked-credential-checks/detections") || code=000
    case "$code" in
      2??) if run_gen "$part" "$prefix" cloudflare_leaked_credential_check_rule --zone "$zid" </dev/null; then
             cat "$part" >> "$tmp"
           else
             gen_failed "$out" "after 3 attempts (cloudflare_leaked_credential_check_rule)"
             rm -f "$tmp" "$part"
             return 0
           fi ;;
      4??) ;;  # not entitled / not enabled at the API: no detection rules to capture
      *)   gen_failed "$out" "to probe leaked-credential detections (HTTP $code)"
           rm -f "$tmp" "$part"
           return 0 ;;
    esac
  fi
  commit_out "$out" "$tmp"
  rm -f "$part"
  return 0
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
    if [ -z "$tsel" ] || [ "$tsel" = waf ]; then
      sync_waf "$zid" "$zname"
    fi
  done < zones.txt
}

report_failures() { # exits non-zero if any artifact failed anywhere in the run
  if [ "$FAILURES" -gt 0 ]; then
    echo "sync finished with $FAILURES failed generate(s) — previous files kept" >&2
    exit 1
  fi
}

type_menu() { # sets TYPE_SEL ("" = all types); Enter defaults to 0; number or name
  local choice
  echo
  echo "Record types (zone):"
  echo "  1 - dns"
  echo "  2 - rulesets"
  echo "  3 - pagerules"
  echo "  4 - settings"
  echo "  5 - waf            (zone WAF settings + account WAF lists / access rules)"
  echo "Account-level types:"
  echo "  6 - workers"
  echo "  7 - d1"
  echo "  8 - r2"
  echo "  9 - kv"
  echo " 10 - queues"
  echo " 11 - registrar"
  echo " 12 - notifications"
  echo
  echo "  0 - ALL TYPES"
  echo
  while :; do
    read -rp "Sync which types (number or name)? [0]: " choice
    case "${choice:-0}" in
      0)                TYPE_SEL="" ;;
      1|dns)            TYPE_SEL="dns" ;;
      2|rulesets)       TYPE_SEL="rulesets" ;;
      3|pagerules)      TYPE_SEL="pagerules" ;;
      4|settings)       TYPE_SEL="settings" ;;
      5|waf)            TYPE_SEL="waf" ;;
      6|workers)        TYPE_SEL="workers" ;;
      7|d1)             TYPE_SEL="d1" ;;
      8|r2)             TYPE_SEL="r2" ;;
      9|kv)             TYPE_SEL="kv" ;;
      10|queues)        TYPE_SEL="queues" ;;
      11|registrar)     TYPE_SEL="registrar" ;;
      12|notifications) TYPE_SEL="notifications" ;;
      *) echo "invalid selection: $choice — enter 0-12 or a type name" >&2; continue ;;
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
  echo "  0 - ALL ZONES (+ account-level)"
  echo "  a - ACCOUNT-LEVEL only (workers / d1 / r2 / kv / queues / registrar / waf / notifications)"
  echo
  while :; do
    read -rp "Sync what (number, zone name, or 'a')? [0]: " choice
    choice=${choice:-0}
    if [ "$choice" = a ]; then
      zsel="__account__"
      break
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
      if [ "$choice" -le "$max" ]; then
        zsel=""
        [ "$choice" -gt 0 ] && zsel=$(awk -v n="$choice" 'NR==n{print $2}' zones.txt)
        break
      fi
    elif awk -v z="$choice" '$2==z{found=1} END{exit !found}' zones.txt; then
      zsel="$choice"
      break
    fi
    echo "invalid selection: $choice — enter 0-$max, an exact zone name, or 'a'" >&2
  done
  if [ "$zsel" = "__account__" ]; then
    sync_account ""
  elif [ -z "$zsel" ]; then
    # ALL is slow — offer a type filter; a single zone is fast, sync all types
    type_menu
    if [ -z "$TYPE_SEL" ]; then
      sync_tf
      sync_account ""
    else
      # a type may exist at both scopes (waf): run each scope that has it
      if is_zone_type "$TYPE_SEL";    then sync_tf "" "$TYPE_SEL"; fi
      if is_account_type "$TYPE_SEL"; then sync_account "$TYPE_SEL"; fi
    fi
  else
    sync_tf "$zsel" ""
  fi
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,18p' "$0"
  exit 0
fi

# Mandatory per-repo config — no defaults: refusing to run beats capturing the
# wrong account's config into the wrong repo. See the Config note in the header.
if [ ! -f cf-sync.conf ]; then
  echo "Missing cf-sync.conf — create it at the repo root with:" >&2
  echo "  ACCOUNT_ID=<32-hex account id>   # dashboard -> account home -> copy Account ID" >&2
  exit 1
fi
# shellcheck disable=SC1091
. ./cf-sync.conf
if ! [[ "${ACCOUNT_ID:-}" =~ ^[0-9a-f]{32}$ ]]; then
  echo "cf-sync.conf must set ACCOUNT_ID to the 32-hex Cloudflare account id" >&2
  exit 1
fi
KEYCHAIN_SERVICE="cloudflare-api-token-$ACCOUNT_ID"

check_deps
TFBIN=$(command -v terraform)
ensure_token
ensure_account

case "${1:-}" in
  "")      sync_zones
           if [ -t 0 ]; then menu; else sync_tf; sync_account ""; fi ;;
  all|tf)  check_type "${2:-}" any
           if [ -z "${2:-}" ]; then sync_zones; sync_tf; sync_account ""
           else  # a type may exist at both scopes (waf): run each scope that has it
             if is_zone_type "$2";    then sync_zones; sync_tf "" "$2"; fi
             if is_account_type "$2"; then sync_account "$2"; fi
           fi ;;
  account) check_type "${2:-}" account; sync_account "${2:-}" ;;
  zones)   sync_zones ;;
  *)       check_type "${2:-}" zone; sync_zones
           if awk -v z="$1" '$2==z{found=1} END{exit !found}' zones.txt; then
             sync_tf "$1" "${2:-}"
           else
             echo "unknown zone: $1 — run with no args for the menu" >&2
             exit 1
           fi ;;
esac
report_failures
