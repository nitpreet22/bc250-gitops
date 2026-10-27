#!/usr/bin/env bash
# Writes a SOPS-encrypted Kubernetes Secret holding a freshly generated random value.
# Use it for credentials the cluster generates for itself (backup passwords, internal tokens);
# credentials you bring (API keys, OAuth clients) use a placeholder template instead.
#
#   scripts/new-random-secret.sh <output.sops.yaml> <secret-name> <namespace> <key> [bytes=32]
#
# The value is never printed. sops on Windows can't read stdin, so the plaintext exists for a
# moment in a private temp file, which is removed whether or not encryption succeeds.
# Refuses to overwrite an existing file, so re-running never rotates a secret by accident.
set -euo pipefail

readonly OUTPUT=$1 NAME=$2 NAMESPACE=$3 KEY=$4 BYTES=${5:-32}

if [[ -s $OUTPUT ]]; then
  echo "$OUTPUT already exists; delete it first to rotate the secret" >&2
  exit 1
fi

plaintext=$(mktemp)
trap 'rm -f "$plaintext"' EXIT
chmod 600 "$plaintext"
cat > "$plaintext" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $NAME
  namespace: $NAMESPACE
type: Opaque
stringData:
  $KEY: $(openssl rand -hex "$BYTES")
EOF
# --filename-override makes sops pick the creation rule (age key, encrypted fields) for OUTPUT.
sops --encrypt --filename-override "$OUTPUT" "$plaintext" > "$OUTPUT.tmp"
mv "$OUTPUT.tmp" "$OUTPUT"
echo "Wrote $OUTPUT ($NAMESPACE/$NAME, key $KEY; value not shown)"
