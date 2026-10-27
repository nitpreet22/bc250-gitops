#!/usr/bin/env bash
# Gives every Claude Code pod access to nitpreet22/claude-shared (templates/claude-shared): the
# claude-sync sidecar pulls main with it, and claude-share pushes proposal branches. It is a
# read-write deploy key, but protect-main keeps it off main. Same steps as new-deploy-key.sh:
# generate in a private temp dir, encrypt, register the public half, then move the Secret into
# place; the private key is never printed.
#
#   scripts/new-claude-shared-key.sh
# Refuses to overwrite an existing key file. To rotate: bootstrap/forgejo-ensure.sh
# delete-deploy-key claude-shared claude-pods, delete the file, run this again.
set -euo pipefail

readonly REPO=claude-shared TITLE=claude-pods
readonly REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
readonly OUTPUT=$REPO_ROOT/templates/claude-shared/base/claude-shared-key.sops.yaml

if [[ -s $OUTPUT ]]; then
  echo "$OUTPUT already exists; see the header for how to rotate it" >&2
  exit 1
fi
kubectl --context homelab get namespace forgejo >/dev/null

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
ssh-keygen -q -t ed25519 -N "" -C "claude-pods" -f "$workdir/key"
{
  echo "apiVersion: v1"
  echo "kind: Secret"
  echo "metadata:"
  echo "  name: claude-shared-key     # each project's namePrefix makes this <project>-claude-shared-key"
  echo "type: kubernetes.io/ssh-auth"
  echo "stringData:"
  echo "  ssh-privatekey: |"
  sed 's/^/    /' "$workdir/key"
} > "$workdir/secret.yaml"
sops --encrypt --filename-override "$OUTPUT" "$workdir/secret.yaml" > "$workdir/encrypted.yaml"
"$REPO_ROOT/bootstrap/forgejo-ensure.sh" repo "$REPO" "$TITLE" "$workdir/key.pub" read-write
mv "$workdir/encrypted.yaml" "$OUTPUT"
echo "Wrote $OUTPUT (private key not shown)"
