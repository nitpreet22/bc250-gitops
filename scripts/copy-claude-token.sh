#!/usr/bin/env bash
# Copies the Claude Code token (`claude setup-token`) from one namespace's claude-auth Secret into
# another's, e.g. for a new namespace. The token goes from `sops -d` straight into `sops set` on
# stdin; it is never printed or written to a plain file. Run it yourself on the PC.
#
#   scripts/copy-claude-token.sh <from-namespace> <to-namespace>     e.g. ops games
set -euo pipefail

readonly REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
readonly FROM=$REPO_ROOT/apps/$1/claude-auth.sops.yaml TO=$REPO_ROOT/apps/$2/claude-auth.sops.yaml
[[ -f $FROM && -f $TO ]] || { echo "need both $FROM and $TO" >&2; exit 1; }

# The token stays in this shell variable; $(...) drops the trailing newline and the %$'\r' a
# Windows carriage return. sops set wants the value JSON-encoded; the token is plain ASCII, so
# quoting it is enough.
token=$(sops -d --extract '["stringData"]["token"]' "$FROM")
token=${token%$'\r'}
[[ $token =~ ^[A-Za-z0-9._-]+$ ]] || { echo "the token in $FROM isn't a plain token; not copied" >&2; exit 1; }
printf '"%s"' "$token" | sops set --value-stdin "$TO" '["stringData"]["token"]'
unset token
echo "Copied the token into $TO (not shown)"
