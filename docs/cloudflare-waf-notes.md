# Cloudflare WAF notes: facts, recipe, gotchas

Distilled from a real rollout of the Cloudflare **Pro** WAF across a mixed estate of WordPress,
Laravel and wiki hosts. Facts marked **[verified]** were read on developers.cloudflare.com on
2026-09-02 and survived an independent re-read (two corrections were re-checked on 2026-09-08);
**[verify]** marks anything contested, undocumented, or only observed once. Everything else is
observation from that rollout. Plans, limits and default rule sets change: re-check a number
before relying on it.

Every step ends with a capture, so each dashboard change lands as a reviewable diff:
`cf-sync <zone> <type>`, `git diff`, commit with the change in the message. Security Events on
Pro keeps only 24 hours **[verified]**, so the capture repo's git log is the durable history.

## 1. Plan facts that shape everything

- The WAF is **per zone** and sees only **proxied (orange-cloud)** hostnames; grey-cloud traffic
  never reaches it. Account-wide WAF rulesets are Enterprise-only.
- Pro is USD 20/month per zone billed annually, 25 monthly; downgrades take effect at the end of
  the billing period **[verified]**.

| Feature (all rows [verified]) | Free | Pro | Business |
|---|---|---|---|
| Free Managed Ruleset (automatic) | yes | yes | yes |
| Cloudflare Managed Ruleset, OWASP Core Ruleset | no | yes | yes |
| WAF custom rules | 5 | 20 | 100 |
| Custom-rule **Log** action | no | no | no (Enterprise only) |
| Regex (`matches`) in expressions | no | no | yes |
| Rate limiting rules | 1 | 2 | 5 |
| Rate-limit period / mitigation timeout | 10 s / 10 s | up to 1 min / up to 1 h | up to 10 min / up to 1 day |
| Bots | Bot Fight Mode (zone-wide, cannot be skipped) | Super Bot Fight Mode, skippable per rule | + likely automated |
| Leaked-credential detection | `password_leaked` | + `username_and_password_leaked`; **enable manually** | same |
| Zone Lockdown / User Agent Blocking rules | 0 / 10 | 3 / 50 | 10 / 250 |
| Custom lists | 1 | 10 | 10 |
| Security Events retention | 24 h, sampled | 24 h | 3 days |
| Security Analytics window (all traffic) | 24 h | 7 days | 31 days |
| Security Events Alert notification | no | no | yes |
| Max upload / proxy read timeout | 100 MB / 125 s | 100 MB / 125 s | 200 MB / 125 s |

Managed ruleset ids are Cloudflare-global, the same in every account: Cloudflare Managed Ruleset
`efb7b8c949ac4650a09736fc376e9aee`, OWASP Core Ruleset `4814384a9e5d4991b9815dcfc25d2f1f`.

Three consequences:

- **No Log action below Enterprise.** Observe instead with Security → Analytics (every request,
  acted on or not) and with custom rules whose action is **Skip** with **Log matching requests**
  on (default on, no plan restriction **[verified]**). A Skip of something inert writes each match
  to Security Events: a free ledger.
- **Challenges break non-browser clients.** Managed Challenge and Super Bot Fight Mode cannot be
  passed by curl, cron, webhooks, mobile apps or `fetch()`, and a challenge on a POST silently
  discards the body. The managed ruleset's default actions block and never challenge, which makes
  it the safe first layer.
- **Rate limits count per data centre.** Dashboard-created rules carry `cf.colo.id` as an implicit
  counting characteristic **[verify]**: a threshold is per colo, not global. Fine against one
  noisy source, weaker against a distributed one.

## 2. The recipe, for a WordPress host

Instruments first, then protection that only blocks, then a week of reading, then enforcement,
then challenges.

### Step 0: prerequisites

- The origin presents a certificate Cloudflare trusts (Cloudflare Origin CA, or a public one) so
  the zone can run SSL mode **Full (strict)**, which rejects a self-signed origin certificate with
  a 526 **[verified]**. Never Flexible.
- The origin restores the visitor IP: nginx `set_real_ip_from <each Cloudflare range>;
  real_ip_header CF-Connecting-IP;` **[verified]**, ranges from https://www.cloudflare.com/ips-v4
  and /ips-v6. If another WAF or CDN used to sit in front, remove trust of its client-IP header,
  or a spoofed header will override the real address.
- The host is proxied. Capture `cf-sync <zone> dns` and `cf-sync <zone> settings`.

### Step 1: passive instruments (nothing blocks)

1. **Leaked-credential detection on** (Security → Settings → Detection tools). It only populates
   `cf.waf.credential_check.*` for rules written later; the WordPress login form is scanned by
   default **[verified]**. The docs say Free has it on by default, but a live Free zone showed it
   off: trust the capture, not the doc.
2. **Bot Fight Mode off, Super Bot Fight Mode at Allow.** These are what break integrations;
   they come last.
3. **Probe rules**: custom rules, action **Skip**, product **Zone Lockdown** ticked (with no
   lockdowns defined, the skip is a no-op), **Log matching requests** on, placed at the top.
   Zone-wide on purpose: they act on nothing, and the ledger should see every host.

   | Probe | Expression |
   |---|---|
   | xmlrpc | `(http.request.uri.path eq "/xmlrpc.php")` |
   | REST API | `(http.request.uri.path starts_with "/wp-json/")` |
   | wp-login | `(http.request.uri.path eq "/wp-login.php")` |
   | store callbacks | `(http.request.uri.path starts_with "/wc-api/" or http.request.uri.query contains "wc-api=")` |
   | non-browser | `(not http.user_agent contains "Mozilla" and not cf.client.bot and not http.request.uri.path eq "/xmlrpc.php" and not http.request.uri.path starts_with "/wp-json/")` |

   The store-callbacks probe covers the `/?wc-api=<gateway>` form payment gateways use, where the
   path is just `/`.
4. Capture `cf-sync <zone> rulesets` (a new `http_request_firewall_custom` entry point whose rules
   carry `action = "skip"` and logging) and `cf-sync <zone> waf`.

### Step 2: Cloudflare Managed Ruleset, default actions, explicit hosts

1. Security → Settings → Web application exploits → **Cloudflare managed ruleset** → **Edit
   scope** → an explicit `(http.host in {...})` list. This creates one Execute rule in phase
   `http_request_firewall_managed`; a managed ruleset is deployed once per zone and its scope
   lives on that rule **[verified]**.
2. **Scope is always an explicit host list, never the whole zone.** A zone-wide deployment
   silently covers each record the day it is proxied, before anyone has read its traffic. Every
   later custom rule, rate limit and exception carries an `http.host` condition too. Pre-listing
   a host that is not proxied yet is inert (its traffic never reaches the WAF), and it stops that
   host being silently unprotected when someone orange-clouds it later.
3. **Leave the managed rules at Cloudflare's defaults; never bulk-enable by tag.** Of 47
   `wordpress`-tagged rules (ruleset version 386), 41 are on by default. The six that are off
   false-positive on normal WordPress use: two XML-RPC DoS rules, the load-scripts DoS rule
   (CVE-2018-6389, tripped by wp-admin's own long `load-scripts.php` requests), two REST "Invalid
   Post ID" rules and the WPScan signature, plus one plugin-specific RCE rule. Enable per rule, on
   evidence.
4. **New CVE rules need nothing from you.** A deployment at `version = "latest"` (what the capture
   shows) receives each new rule at its default action; in practice, rules for CVEs published after
   deployment were blocking within the week. Avoid a tag override with "Include new rules": it
   would also auto-enable future rules that are off by default because they false-positive. Skim
   https://developers.cloudflare.com/waf/change-log/ monthly instead.
5. **Hold off on the OWASP Core Ruleset.** Cloudflare's own wording: prone to false positives,
   marginal benefit on top of the managed ruleset **[verified]**. If added later: paranoia level
   1, score threshold Medium, same host scope.
6. Smoke test as an editor, staging first: save a post with raw HTML, upload an image and a PDF,
   update a plugin, submit a contact form logged out, open Site Health (loopback), load the front
   page on mobile data.
7. Capture `rulesets`. With defaults untouched the Execute rule has **no** `overrides` block; that
   is correct, not a capture failure. The first per-rule change adds
   `overrides = { rules = [{ id, enabled }] }`.

To read override rule ids back to descriptions, dump the catalogue once
(`GET /zones/<zone-id>/rulesets/efb7b8c949ac4650a09736fc376e9aee` with the read token) into a
scratch file. It is Cloudflare's config, not yours: keep it out of the capture.

### Step 3: read the ledger for a week

`cf-events <zone>` daily (mitigations, plus the probe ledger), and Security → Analytics per host
(7 days on Pro), grouped by user agent, path, IP and ASN. Per host, answer: who calls
`xmlrpc.php`; which REST callers are legitimate; what store callbacks and integrations look like;
wp-login volume per IP; which non-browser agents are integrations and which are noise. Expect the
origin's own public IP in the ledger: WP-Cron, Site Health and REST self-calls loop back through
Cloudflare.

Traffic classes that **must** get skip rules before any challenge or SBFM work: origin self-calls
(cron, integrations between your own sites), your own uptime or health monitors, mobile apps
calling REST endpoints, and feed consumers such as podcast directories. Many of those are not
verified bots, and a challenge makes a feed stop updating without any error.

### Step 4: enforcement that is safe on evidence

Custom rules evaluate top to bottom; Skip does not terminate, Block and challenges do. Place these
**after** the probes so the probes keep logging.

1. **Block `/xmlrpc.php`**: `(http.request.uri.path eq "/xmlrpc.php")` → Block, logging on. The
   typical attack is `system.multicall` brute force with spoofed "Jetpack by WordPress.com" agents
   from residential ISPs. Zone-wide is right here: a block on a path nothing uses is safer when it
   extends automatically to future sites (add an exception if Jetpack is ever adopted).
   Cloudflare's normalization folds `//xmlrpc.php` to `/xmlrpc.php` before rules run, so `eq`
   catches the scanners' double-slash form. Delete the xmlrpc probe afterwards; the block logs its
   own matches.
2. **Act on leaked credentials**: `(cf.waf.credential_check.username_and_password_leaked and
   http.request.uri.path eq "/wp-login.php")` → **Managed Challenge**. It fires only when the
   submitted pair is already in a breach corpus, which is exactly what credential stuffing uses,
   and a real user with a leaked password can still get in and change it. Detection that no rule
   reads protects nothing.
3. **Rate-limit wp-login POSTs**: `(http.request.uri.path eq "/wp-login.php" and
   http.request.method eq "POST")`, per IP, 5 per minute, Managed Challenge. `http.request.method`
   *is* usable in a rate-limit matching expression **[verified]**, and matching POSTs only keeps
   page loads out of the count. Cloudflare's own login recipe is 4 per minute per IP with Managed
   Challenge **[verified]**. With a challenge action, Free/Pro/Business cannot choose a mitigation
   duration (automatic throttling applies); a duration needs Block **[verified]**. This takes one
   of Pro's two rate-limit rules.
4. Capture `rulesets` after each group.

### Step 5: skips, then challenges, then bots

- **Skips first**, from the ledger. `skip-integrations`: `or`-joined `(http.host eq "<host>" and
  http.request.uri.path starts_with "<path>" and ip.src in {<provider IPs>})` clauses, never by
  path alone. `skip-origin-loopback`: `(ip.src in {<origin IPs>})`. Action Skip → Rate limiting
  rules, Super Bot Fight Mode and Managed rules, plus product Browser Integrity Check; logging on.
  Optimize for WordPress exempts loopbacks from SBFM only **[verified]**; the managed ruleset and
  BIC still see them.
- **Optional blocks**: PHP under uploads, `http.request.uri.path wildcard
  "/wp-content/uploads/*.php*"`; scanner agents (`sqlmap`, `nikto`, `Nikto`, `masscan`). Pro has
  no regex, and `eq`/`contains` are case-sensitive while `wildcard` is not **[verified]**.
- **Challenge wp-admin**: `(http.host in {...} and (http.request.uri.path eq "/wp-login.php" or
  http.request.uri.path wildcard "/wp-admin/*") and not http.request.uri.path eq
  "/wp-admin/admin-ajax.php" and not http.request.uri.path eq "/wp-admin/admin-post.php")` →
  Managed Challenge. `admin-ajax.php` and `admin-post.php` are public endpoints behind front-end
  forms; a challenge there silently drops submissions.
- **Super Bot Fight Mode last**: Definitely automated → Managed Challenge; Verified bots → Allow;
  JavaScript detections on; Optimize for WordPress on; Static resource protection off until tested
  against non-browser asset fetches **[verify]**. Bot Fight Mode stays off: it cannot be skipped.
- Capture `rulesets` and `waf` (SBFM appears as `sbfm_*`, `optimize_wordpress` and `enable_js`
  attributes), and `cf-sync account waf` if you created a list.

Before each widening: the front page loads unchallenged on a phone; wp-login shows a challenge,
then the form; a logged-in media upload works; Site Health loopback is green; a logged-out
`fetch("/wp-json/wp/v2/posts")` from the browser console returns JSON (block-based checkout calls
`/wp-json/wc/store/*` the same way, and a challenge there fails silently); a real test order; one
integration call; a webhook test from the payment provider's dashboard.

### Step 6: origin lockdown (closes the bypass)

Until the origin accepts only Cloudflare, the WAF is optional for anyone who knows the origin IP,
and origin IPs leak through DNS history.

1. Origin firewall: 80 and 443 only from the Cloudflare ranges.
2. Verify from outside: `curl -sI https://<origin-ip>/ -H 'Host: <site>' -k` must time out or be
   refused, while the site name returns 200.
3. The access log shows visitor IPs, not Cloudflare's.
4. Full (strict) everywhere, Always Use HTTPS on, minimum TLS 1.2. Capture `settings`.
5. Optionally, Authenticated Origin Pulls, so the origin accepts only Cloudflare's client
   certificate.

## 3. Tuning and rollback

- Review Security → Analytics → Events daily, weekends included for the first two weeks: filter
  Service = managed / custom / rate limiting and Action ≠ Skip; group by rule, host, path, agent.
- **Managed-rule false positive**: prefer a WAF exception (Managed rules exception on host + path,
  skipping the specific rule ids) placed **above** the Execute rule, so the rule stays on
  everywhere else **[verified]**.
- **Custom-rule false positive**: narrow the expression or add the source to `skip-integrations`;
  never widen a Skip to a whole host.
- Every tuning change is a capture and a commit naming the rule id and the reason.
- Rollback ladder, cheapest first: one managed rule off → exception → custom rule "Save as draft"
  (undeploys without deleting) → rate limit off → SBFM back to Allow → managed ruleset off →
  leaked-credential detection off → proxy off for one host → Pause Cloudflare on Site.

## 4. Gotchas

- **A host that goes silent after proxying was not blocked by the WAF.** If Cloudflare records no
  firewall events *and no HTTP requests at all* for a newly proxied host while its client reports
  failures, the client never completed TCP/TLS with the edge: no SNI, an unsupported port, or no
  Host header. Fix the client, not the WAF. A logged block means a false positive (write an
  exception); nothing logged means a pre-HTTP failure.
- **Attribution is free.** Security Events records the host and rule id of every block, so there
  is no need to stagger scope additions to see which one broke; staggering only helps when the
  failure is invisible in the logs, as above.
- **Verified bots are not exempt from the managed ruleset**, which inspects content. Payment
  webhooks (Stripe is a verified bot) are also invisible to a non-browser probe that excludes
  `cf.client.bot`: give them their own probe, and consider Skip → Managed rules on the signed
  webhook path, keyed on the provider's published IPs where possible.
- **Plan changes reset settings.** Upgrading a zone to Pro reset HTTP/3, ECH and Automatic HTTPS
  Rewrites to off. Capture `settings` straight after any plan change; the diff is how you notice.
- **Pro limits that bite**: 100 MB upload cap, 125 s proxy read timeout (long exports return 524),
  WebSockets only on Cloudflare's supported ports. Pro inspects only part of a large request body
  (the limit is unpublished and below Enterprise's 128 KB), so big uploads are partly unseen
  rather than blocked.
- **Laravel, APIs and SPAs**: restore the real IP first (nginx as above, or Laravel
  `trustProxies(at: [<Cloudflare ranges>])` **[verified]**), and never `at: '*'` while the origin
  still accepts direct connections, or anyone can forge `X-Forwarded-For`. Leave these managed
  rules off (they are off by default): Unusual HTTP Method (SPAs send real PUT/PATCH/DELETE),
  missing or empty User-Agent, missing Content-Type, large body, PHP Object/Wrapper Injection.
  Ignition RCE (CVE-2021-3129) is on by default; enable Laravel Pulse RCE (CVE-2024-55661) only if
  Pulse is installed. Zone-wide **Email Obfuscation** rewrites addresses inside the JSON that
  Inertia and Livewire embed in pages, which breaks them: exempt those hosts with a Configuration
  Rule rather than turning it off zone-wide.
- **Leaked-credential fields on non-WordPress logins**: Pro gets Cloudflare's generic
  authentication patterns only; custom detection locations are Enterprise-only **[verified]**.
  Test with a known-leaked credential before writing a rule for a bespoke login form.
- **Wikis are the highest false-positive risk**: an edit documenting SQL, shell or HTML looks
  exactly like an attack payload. After scoping, save a test page containing a quoted SQL
  statement and a `<script>` fragment on the staging copy; if it blocks, write an exception for
  the edit path.
- **The WAF is not remediation.** It blocks commodity exploitation, not traffic to an
  already-planted webshell; it protects nothing until the host is proxied and the origin locked
  down; and it does not replace denying dotfiles (`.env`, `.git`) at the origin.
- **AI-bot settings are migrating**: the legacy `ai_bots_protection` toggle is being replaced by AI
  bot policies (around 2026-09-15 **[verify]**); expect `waf-*.tf` to churn when Cloudflare
  migrates the field.

## 5. Where WAF config lands in a capture repo

| File | Contents |
|---|---|
| `terraform/rulesets-<zone>.tf` | Your entry-point rulesets, one per phase: `http_request_firewall_custom` (custom rules, probes, skips), `http_request_firewall_managed` (the Execute rule, its scope and `overrides`), `http_ratelimit`. Rule `id` is `null`; `ref`, `last_updated` and `version` move only when a rule changes. |
| `terraform/waf-<zone>.tf` | Always present: Bot Fight Mode / SBFM (`sbfm_*`, `optimize_wordpress`, `enable_js`) and leaked-credential detection (plus its custom detection rules); IP Access Rules, Zone Lockdowns and User Agent Blocking rules when any exist. Account-scoped access rules are filtered out. |
| `terraform/settings-<zone>.tf` | The classic toggles: security level, Browser Integrity Check, challenge passage, SSL mode, minimum TLS, Always Use HTTPS, Email Obfuscation. |
| `terraform/account-waf-*.tf` | Lists (what `ip.src in $name` references), their items, account-level IP Access Rules. |
| `notifications.jsonl` | Alert policies, as JSON lines rather than HCL: the provider's alert-type enum lags Cloudflare. |

Cloudflare's own managed rulesets (Free, Managed, OWASP, DDoS L7, normalization) are Cloudflare's
config and are not captured; only your deployment of them is. The read-only "Read All Resources"
token reads every one of these object types. Keep any write token for WAF work separate, narrowly
scoped (Zone WAF:Edit, Zone Settings:Edit) and expiring.
