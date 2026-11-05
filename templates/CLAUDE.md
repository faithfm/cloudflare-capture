# Working in this repo

A **capture repo**: the Cloudflare dashboard is the source of truth, and this repo is the
change log. Data only — the tooling lives in
[cloudflare-capture](https://github.com/faithfm/cloudflare-capture) (`cf-sync`,
`cf-audit-archive`, `cf-events`; see `cf-sync --help`). Read `README.md` first.

## Attribute every capture commit from the audit log

A diff here says *what* changed. `audit-log.jsonl` is the only record of *who* changed it and
*when*, and it expires — Cloudflare keeps 18 months and caps any single query at 3000 entries,
so an unattributed change can become unattributable for good. Before committing a capture diff:

1. **Check the archive reaches the diff.** `tail -1 audit-log.jsonl | jq .when`. If it stops
   short of the change, run `cf-audit-archive 30` (or further back) and commit that top-up as
   its own commit first — it is the evidence for the commits that follow.
2. **Find the actor.** Events for a window, oldest first:

   ```bash
   jq -r 'select(.when >= "2026-01-01T00:00:00Z") | select((.actor.email // "") != "")
          | [.when, .actor.email, .resource.type, .action.type,
             ((.metadata // {}) | tostring)] | @tsv' audit-log.jsonl | sort
   ```

   `metadata.zone_name` ties a DNS event to a zone; `zone` / `change_setting` carries
   `old_value` and `value`; `rulesets_update` carries the ruleset id and phase. An actor that
   is not an email (`Bot Management API`, `Field Extraction`) is one of Cloudflare's own
   services acting on the account.
3. **Write the commit message around the actor.** Name who made the change, the UTC timestamp
   from the log, and what it did — e.g. *"example.com: Sam's tunnel migration, 22–28 Oct
   (webhosting-4 retired)"*. Group commits by zone or work stream rather than by file, and keep
   them few and meaningful.
4. **Say so when there is no actor.** A diff with no matching audit event is Cloudflare moving
   under you — a new API field, a changed default — not a person. State that in the message
   ("API shape, not a change"); never let a commit imply someone made a change they didn't.

Attribution is reconstruction *about* a capture, so it belongs in the commit message. It must
never reach the captured files themselves — see the next rule.

## Rules that are not negotiable

- **Never mix inferred or reconstructed data into a captured file.** The repo's whole value is
  that a diff means "the dashboard changed". Anything derived that is indistinguishable from
  captured output destroys that guarantee. If you reconstruct history, keep it in commits that
  say plainly they are not captures, and out of files `cf-sync` maintains.
- **Capture only.** There is no Terraform state here and nothing ever runs `terraform apply`.
  HCL is just the storage format, chosen for its coverage of Cloudflare's config.
- **No tokens in repo files, ever.** The token lives in the macOS Keychain item
  `cloudflare-api-token-<ACCOUNT_ID>`, or in `$CLOUDFLARE_API_TOKEN`. Never print it.
- **No scripts here.** Tooling changes go to cloudflare-capture, so capture repos cannot drift
  out of date. `.cf-capture-version` records which tool version made the last run.
- **Treat this repo as shared and private.** Others may hold a clone — flag history rewrites
  before force-pushing. It maps the infrastructure and names people: private remotes only.
