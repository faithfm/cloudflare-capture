# cloudflare-capture

Read-only capture of a Cloudflare account's configuration into a git repository, as
Terraform-format HCL. The Cloudflare **dashboard stays the source of truth**; the capture repo is
its change log. Sync, review the diff, commit: any change made in the dashboard shows up as a
clean, per-record `git diff`.

Nothing here runs `terraform apply`, and there is no Terraform state. HCL is simply the storage
format: it covers the full configuration (DNS records including the proxied flag, zone settings,
rulesets, WAF, tunnels, account-level wiring), and `terraform validate` can check the whole tree.

One installed copy of the tool serves any number of accounts. Each account gets its own
**capture repo**, which holds only data: `cf-sync.conf` (one setting, the account id) plus what
the tool captures.

## Install

```bash
git clone https://github.com/faithfm/cloudflare-capture.git ~/.local/share/cloudflare-capture
~/.local/share/cloudflare-capture/install.sh
```

Clone it anywhere permanent: `~/.local/share/cloudflare-capture` is the conventional place for
tools installed this way, and a projects directory is fine if you will also work on it. The
commands are symlinks into the checkout, so if you move it, run `cf-install` again.

`install.sh` symlinks `cf-sync`, `cf-audit-archive`, `cf-events` and `cf-install` into
`~/.local/bin` (override with `INSTALL_DIR=...`) and checks for the dependencies, `jq`,
`terraform` and `cf-terraforming`: it offers to install missing ones via Homebrew, or points at
the official downloads where there is no Homebrew. If `~/.local/bin` is not on your `PATH`, it
asks before adding one line to your shell's startup file; declining prints the line instead. It
needs no sudo.

- **Upgrade**: run `cf-install` again. It tells you when a newer version exists and asks before
  installing it; `cf-install --update` skips the question. A checkout with your own changes in
  it is never touched (developers: `git pull` yourself).
- **Uninstall**: `cf-install --uninstall` removes only the symlinks that point into this
  checkout; a PATH line it added stays, as does `cf-sync`'s list of recent capture repos.
- **Linux**: Debian, Ubuntu and Fedora put `~/.local/bin` on `PATH` at your next login once it
  exists; the prompt just makes it immediate.
- **System-wide**, on a single-user machine where you can sudo:
  `sudo env INSTALL_DIR=/usr/local/bin ~/.local/share/cloudflare-capture/install.sh`. That
  directory is on `PATH` in every shell, so no startup file changes; the symlinks still point
  into your checkout, and later runs of `cf-install` stay there, needing sudo again only when
  a new command has to be linked.

## Create a capture repo

```bash
mkdir my-cloudflare-capture && cd my-cloudflare-capture
cf-sync init
```

`init` asks for the account id (dashboard → account home → copy **Account ID**; or pass it as
`cf-sync init <account-id>`), writes five files (`cf-sync.conf`, `.gitignore`, a `README.md`,
and `terraform/provider.tf` with its lock file) and commits them. It refuses to run inside an
existing capture repo and never overwrites a file.

## First run: the API token

```bash
cf-sync
```

Create a **read-only** token in the Cloudflare dashboard: My Profile → API Tokens → Create Token
→ the **"Read All Resources"** template. Read-only means the worst a leaked token can do is
disclose configuration, never change it.

- **macOS**: on first run `cf-sync` offers to store the token in the Keychain, as item
  `cloudflare-api-token-<ACCOUNT_ID>`, through a hidden prompt, so it never touches disk or shell
  history. The item name derives from the account id, so capture repos for different accounts
  each find their own token.
- **Anywhere else, or to override**: `export CLOUDFLARE_API_TOKEN=...` before running. This is
  the route on Linux and WSL.

Before any capture, the token is verified to actually see the configured account, so a token for
another account can never capture that account's config into your capture repo.

Then pick a zone (or ALL ZONES) and record types from the menus; Enter accepts the defaults.

## Usage

```text
cf-sync                          interactive menus
cf-sync all [type]               everything, optional type filter
cf-sync <zone-name> [type]       one zone, e.g. example.com (~20 s)
cf-sync account [type]           account-level artifacts only
cf-sync zones                    refresh the zone indexes only
cf-sync init [account-id]        scaffold a new capture repo in the current directory

type (zone)    = dns | rulesets | pagerules | settings | waf
type (account) = workers | d1 | r2 | kv | queues | registrar | waf | notifications | tunnels
```

```text
cf-audit-archive                 archive the account audit log (walk back until dry)
cf-audit-archive 30              only look back 30 days (quick top-up)
cf-events <zone> [hours]         read-only WAF review: what was blocked or challenged,
                                 plus the logging "probe" rules' ledger (default 24 h)
cf-install                       install or re-install; on a re-run, offers any available update
cf-install --update              update without asking (never touches a checkout with local work)
cf-install --uninstall           remove the symlinks (a PATH line it added stays)
```

Every command works from anywhere inside a capture repo (it finds `cf-sync.conf` by walking up,
the way git finds `.git`), and `--help` works anywhere.

Run `cf-sync` outside a capture repo, from a terminal, and it lists the capture repos it has run
in recently: pick one by number (Enter takes the most recent) and the run carries on there with
the same arguments, or type `init` to create a new capture repo in the current directory. Your
shell stays where it was, so `cd` into the repo to review the diff. The list is kept in
`~/.local/state/cloudflare-capture/recent-repos` (under `$XDG_STATE_HOME` if set) and holds only
paths. Without a terminal, `cf-sync` outside a capture repo still just fails: automation never
picks a repo.

A sync takes roughly 20 seconds per zone. Progress is reported per artifact as
`NEW / UPDATED / unchanged / REMOVED / none / skipped / FAILED`. A failed pull never overwrites
the previously captured file, and `skipped` appears only for R2 artifacts while R2 is not
enabled on the account.

The workflow:

```bash
cf-sync
git diff        # review what changed in the dashboard
git commit -am "describe the change"
```

## What's captured

| Path | Contents |
| --- | --- |
| `cf-sync.conf` | The one setting, `ACCOUNT_ID` (committed) |
| `.cf-capture-version` | The cloudflare-capture version that made the last run; changes only on upgrade |
| `audit-log.jsonl` | Account change history: who changed what, when (written by `cf-audit-archive`) |
| `zones.txt` | Zone index: zone-id + zone-name |
| `zones-meta.tsv` | Per-zone metadata: plan, status, type, paused, assigned nameservers |
| `workers.txt` | Worker inventory: script name + created date |
| `registrar.txt` | Cloudflare-registered domains: name + registered + expires |
| `notifications.jsonl` | Notification policies, one JSON object per line (destinations by id; webhook URLs never captured) |
| `terraform/dns-<zone>.tf` | DNS records, including the proxied (orange-cloud) flag |
| `terraform/settings-<zone>.tf` | Zone settings, including SSL/TLS |
| `terraform/rulesets-<zone>.tf` | Redirect / transform / WAF rules (absent = zone has none) |
| `terraform/pagerules-<zone>.tf` | Legacy Page Rules (absent = zone has none) |
| `terraform/waf-<zone>.tf` | WAF-family settings held outside the rulesets API: Bot Fight Mode / Super Bot Fight Mode, leaked-credential detection (+ its custom detection rules), IP Access Rules, Zone Lockdowns, User Agent Blocking (always present; the rule kinds appear only when the zone has some) |
| `terraform/account-*.tf` | Account-level config: Workers custom domains & cron triggers, D1 databases, R2 buckets & custom domains, KV namespaces, Queues & consumers, Registrar settings, WAF lists + list items + account-level IP Access Rules (absent = account has none) |
| `terraform/account-tunnel*.tf` | Cloudflare Tunnels: each tunnel's name and whether it is configured in the dashboard or locally (`account-tunnels.tf`); each dashboard-configured tunnel's published applications, its ingress rules with their origin parameters (`account-tunnel-configs.tf`); private-network routes and virtual networks (`account-tunnel-routes.tf`, `account-tunnel-vnets.tf`). Never tunnel secrets or run tokens (absent = account has none) |

An empty result produces no file, and removes a stale one: absence means "none of these".

## Keep your capture repo private

A capture repo is a detailed map of your infrastructure, and it contains personal data.
`audit-log.jsonl` records the email address of everyone who has changed the account, third
parties included, and `notifications.jsonl` holds alert recipients' addresses. The DNS files
expose origin IP addresses, which a site behind a WAF most wants hidden, and tunnel configurations
name the internal service behind each published hostname. Push capture repos only to private
remotes. (`cf-sync init` puts this warning into every new capture repo's README.)

This tool repository, by contrast, contains no account data at all.

## Design notes

- **Capture repos are pure data.** All tooling lives here, so a capture repo has no scripts to
  drift out of date. `.cf-capture-version` records which tool version made each capture, so a
  capture repo's `git log` shows when an upgrade changed the output.
- **The audit log is history, and it expires.** `cf-sync` captures *state*; the audit log is the
  only record of *what changed when, and who changed it*. Cloudflare keeps it for 18 months and
  also caps any single query at 3000 entries over 3 pages, so `cf-audit-archive` walks backwards
  in 15-day windows and merges into whatever is already committed; nothing is ever dropped. Run
  it periodically: the archive then reaches further back than the API still can, and any stretch
  you never archive is gone for good once it expires. One event per line, keys sorted, ordered by
  `(when, id)`, so a re-run is an append-only diff. `actor.ip` is stripped; actor email is kept,
  since attribution is the point.
- **WAF lives in two places.** The rules themselves (custom rules, managed-ruleset deployments
  and their overrides, rate limits, DDoS overrides) are zone rulesets and land in
  `rulesets-<zone>.tf`, one entry-point ruleset per phase. Everything else on the Security →
  Settings page lands in `waf-<zone>.tf` or, for the classic toggles (security level, browser
  integrity check, challenge passage…), in `settings-<zone>.tf`. Cloudflare's own managed
  rulesets are Cloudflare's config and are not captured; only your deployment of them is.
  [docs/cloudflare-waf-notes.md](docs/cloudflare-waf-notes.md) is a WAF rollout recipe that
  uses the capture at every step.
- **Notifications are JSON lines, not HCL**, because the provider's alert-type list lags
  Cloudflare and one unknown value would fail `terraform validate` for the whole tree. Webhook
  destinations appear by id only: their URLs are bearer secrets.
- **Tunnel configs keep cloudflared's key names.** cf-terraforming copies a tunnel's
  configuration verbatim, so the keys inside `config` are the API's camelCase names
  (`originRequest`, `originServerName`, `httpHostHeader`, `caPool`, `noTLSVerify`,
  `warp-routing`), not the provider's snake_case attributes. `terraform validate` ignores unknown
  keys inside a nested attribute, so the tree still validates and every ingress rule and origin
  parameter is recorded faithfully; the file just could not be applied as-is. No tunnel secret or
  run token is ever captured: the listing carries none, the token endpoint needs a write
  permission, and `cf-sync` strips any `tunnel_secret` a generate emits. Deleted tunnels, routes
  and virtual networks, which the API keeps listing, are filtered out.
- **Wiring, not code.** Account-level capture records *which* Workers / D1 / R2 / KV / Queue
  resources exist and how they are wired to zones; never Worker source or bindings (each app's
  own repo and wrangler are the source of truth), D1 schema or data, R2 objects, KV values, or
  secret values (write-only at Cloudflare's API, by design).
- **Failures never clobber.** Each artifact is written only after a fully successful pull;
  transient API errors are retried, and a persistent failure keeps the previous file and makes
  the run exit non-zero.
- **Three commands, not one.** They are independent, proven scripts; each finds the capture repo
  the same way.

## Limitations

- **macOS is the tested platform.** On Linux or WSL, `cf-sync` works with `CLOUDFLARE_API_TOKEN`
  set (Keychain storage is macOS-only), but `cf-audit-archive` and `cf-events` currently use BSD
  `date` options and fail with GNU `date`.
- Managed Transforms (Rules → Settings) are not captured yet.
- Worker routes and R2 CORS/lifecycle rules are unsupported by cf-terraforming 0.28 and not
  captured. R2 artifacts report "skipped" until R2 is enabled on the account (a dashboard toggle
  with a billing dimension).
- Registrar capture covers Cloudflare Registrar only: managed settings (auto-renew / lock / WHOIS
  privacy) as HCL, plus `registrar.txt` dates. WHOIS contact data is never captured, and domains
  registered at another registrar are out of scope.
- Account-level Bulk Redirects are not captured.
- Tunnel capture has been checked against a real account with no tunnels and a simulated account
  with several. Once your first tunnel exists, confirm it: `cf-sync account tunnels` reports
  `tunnels NEW (1)` and, when the tunnel has a published application, `tunnel-configs NEW (1)`;
  `grep -in 'secret\|token' terraform/account-tunnel*.tf` finds nothing; and
  `terraform -chdir=terraform validate` still passes.
- WARP Connector tunnels are not captured (a separate resource type); routes that point at them
  are.

## Tested with

macOS; bash 5.2 (scripts also syntax-checked with macOS's stock bash 3.2); jq; Terraform 1.15.8;
cf-terraforming 0.28.0; Cloudflare Terraform provider 5.22.0 (pinned by the lock file that
`cf-sync init` writes).

## License

MIT — see [LICENSE](LICENSE).
