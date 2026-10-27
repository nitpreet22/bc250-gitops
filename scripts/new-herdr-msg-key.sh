#!/usr/bin/env bash
# Gives every Claude Code pod a way to message other agents (hl msg, "Messages between agents" in
# claude-shared's CLAUDE.md): an ssh key that bc250-2 accepts only for `hl relay` (bootstrap/
# 05-herdr.sh puts it in authorized_keys with restrict and a forced command). The relay allows
# "msg ls" and "msg send <project>" and names the sender from the calling pod's IP.
#
# Writes:
#   templates/claude-shared/base/herdr-msg-key.sops.yaml   private key + bc250-2's host key
#   bootstrap/herdr-msg-key.pub                            the public half, for authorized_keys
# The private key is generated in a private temp dir, encrypted, and never printed.
#
#   scripts/new-herdr-msg-key.sh
# Refuses to overwrite an existing key. To rotate: delete both files, run this again, then
# re-run bootstrap/05-herdr.sh on bc250-2 and push (Flux updates the Secret in every pod).
set -euo pipefail

readonly CORE_HOST=192.168.1.106     # bc250-2, as the pods reach it
readonly REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
readonly OUTPUT=$REPO_ROOT/templates/claude-shared/base/herdr-msg-key.sops.yaml
readonly PUBLIC=$REPO_ROOT/bootstrap/herdr-msg-key.pub

if [[ -s $OUTPUT || -s $PUBLIC ]]; then
  echo "$OUTPUT or $PUBLIC already exists; see the header for how to rotate" >&2
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
ssh-keygen -q -t ed25519 -N "" -C "herdr-msg (Claude pods -> hl relay)" -f "$workdir/key"
# Pin bc250-2's host key, so pods never accept a stranger's (StrictHostKeyChecking=yes).
ssh-keyscan -t ed25519 "$CORE_HOST" 2>/dev/null > "$workdir/known_hosts"
[[ -s $workdir/known_hosts ]] || { echo "couldn't read $CORE_HOST's host key" >&2; exit 1; }
{
  echo "apiVersion: v1"
  echo "kind: Secret"
  echo "metadata:"
  echo "  name: herdr-msg-key     # each project's namePrefix makes this <project>-herdr-msg-key"
  echo "type: Opaque"
  echo "stringData:"
  echo "  ssh-privatekey: |"
  sed 's/^/    /' "$workdir/key"
  echo "  known_hosts: |"
  sed 's/^/    /' "$workdir/known_hosts"
} > "$workdir/secret.yaml"
sops --encrypt --filename-override "$OUTPUT" "$workdir/secret.yaml" > "$workdir/encrypted.yaml"
cp "$workdir/key.pub" "$PUBLIC"
mv "$workdir/encrypted.yaml" "$OUTPUT"
echo "Wrote $OUTPUT (private key not shown) and $PUBLIC"
