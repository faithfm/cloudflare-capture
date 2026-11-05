# Cloudflare capture — account __ACCOUNT_ID__

Point-in-time capture of this Cloudflare account's configuration, produced by
cloudflare-capture (`cf-sync --help`). The dashboard is the source of truth; this
repo is the change log: sync, review the diff, commit.

`CLAUDE.md` holds the working conventions, above all how to attribute each commit to
whoever made the change in the dashboard, using `audit-log.jsonl`.

**Keep this repo private.** `audit-log.jsonl`, `notifications.json`, `members.json` and
`access-groups.json` contain email addresses: everyone who has touched the account,
alert recipients, every account member, and everyone Cloudflare Access lets in.
