#!/usr/bin/env bash
# Entry point after a fresh clone. The installer itself is bin/cf-install, which
# this symlinks onto PATH along with the other commands.
exec "$(dirname "$0")/bin/cf-install" "$@"
