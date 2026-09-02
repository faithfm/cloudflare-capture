#!/usr/bin/env bash
# Cloudflare security events — read-only daily review from the terminal.
#
# Usage:
#   scripts/cf-events.sh <zone-name> [hours] [limit]
#     hours  = look-back window, default 24 (Security Events on Pro keeps 24 h)
#     limit  = rows per table, default 40
#
# Two tables from the zone's firewall events (GraphQL firewallEventsAdaptiveGroups):
#   1. MITIGATIONS — every action except skip: what the WAF blocked or
#      challenged, by service, rule, host, path and user agent. Legitimate
#      traffic here = a false positive to fix with a per-rule exception.
#   2. LEDGER — the logging Skip "probe" rules: what non-browser / API / login
#      traffic looks like before anything tightens.
# Reads the same read-only token as cf-sync.sh (Keychain or $CLOUDFLARE_API_TOKEN);
# never writes anything. Zone name is resolved through zones.txt.
set -euo pipefail
cd "$(dirname "$0")/.."

zone="${1:-}"; hours="${2:-24}"; limit="${3:-40}"
if [ -z "$zone" ] || [ "$zone" = "-h" ] || [ "$zone" = "--help" ]; then
  sed -n '2,16p' "$0"; exit 0
fi
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[ -f cf-sync.conf ] || { echo "Missing cf-sync.conf — run from a capture repo." >&2; exit 1; }
# shellcheck disable=SC1091
. ./cf-sync.conf
zid=$(awk -v z="$zone" '$2==z{print $1}' zones.txt)
[ -n "$zid" ] || { echo "unknown zone: $zone (not in zones.txt — run scripts/cf-sync.sh zones)" >&2; exit 1; }
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  CLOUDFLARE_API_TOKEN=$(security find-generic-password -s "cloudflare-api-token-$ACCOUNT_ID" -w 2>/dev/null) \
    || { echo "No token in env or Keychain item cloudflare-api-token-$ACCOUNT_ID" >&2; exit 1; }
fi

since=$(date -u -v-"${hours}"H +%Y-%m-%dT%H:%M:%SZ)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# $1 = extra GraphQL filter clause (JSON object fragment), $2 = title
report() {
  local q resp
  q=$(jq -n --arg z "$zid" --arg s "$since" --arg n "$now" --argjson lim "$limit" --argjson extra "$1" '{
    query: "query($z:String!,$s:Time!,$n:Time!,$lim:Int!,$f:ZoneFirewallEventsAdaptiveGroupsFilter_InputObject!){viewer{zones(filter:{zoneTag:$z}){firewallEventsAdaptiveGroups(limit:$lim,orderBy:[count_DESC],filter:$f){count dimensions{action source ruleId description clientRequestHTTPHost clientRequestPath userAgent clientIP clientCountryName}}}}}",
    variables: {z:$z, s:$s, n:$n, lim:$lim, f:({datetime_geq:$s, datetime_leq:$n} + $extra)}}')
  resp=$(curl -sf --max-time 30 -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' \
    https://api.cloudflare.com/client/v4/graphql -d "$q") || { echo "GraphQL request failed" >&2; return 1; }
  if jq -e '.errors' <<<"$resp" >/dev/null 2>&1; then
    echo "GraphQL error: $(jq -c '.errors' <<<"$resp" | cut -c1-300)" >&2; return 1
  fi
  echo
  echo "== $2  ($zone, last ${hours}h, top $limit by count) =="
  {
    printf 'count\taction\tsource\trule\thost\tpath\tcountry\tclient-ip\tuser-agent\n'
    jq -r '.data.viewer.zones[0].firewallEventsAdaptiveGroups[]
      | [.count, .dimensions.action, .dimensions.source,
         (if (.dimensions.description // "") != "" then .dimensions.description else .dimensions.ruleId end | .[0:32]),
         .dimensions.clientRequestHTTPHost, (.dimensions.clientRequestPath | .[0:44]),
         (.dimensions.clientCountryName | .[0:14]), (.dimensions.clientIP | .[0:22]), (.dimensions.userAgent | .[0:40])]
      | @tsv' <<<"$resp"
  } | column -t -s $'\t'
  [ "$(jq '.data.viewer.zones[0].firewallEventsAdaptiveGroups | length' <<<"$resp")" -gt 0 ] || echo "(none)"
}

report '{"action_neq":"skip"}' "MITIGATIONS (blocked / challenged)"
report '{"action":"skip"}'     "LEDGER (logging skip rules)"
