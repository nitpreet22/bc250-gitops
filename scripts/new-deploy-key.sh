#!/usr/bin/env bash
# Gives a project's dev pod read-write git access to its Forgejo repo, and nothing else:
#   1. generates an ed25519 key pair in a private temp dir,
#   2. encrypts the private key as a SOPS Secret (<namespace>/<project>-git-deploy-key after the
#      overlay's namePrefix),
#   3. registers the public key on the repo as a read-write deploy key,
#   4. moves the Secret to apps/<namespace>/<project>/git-deploy-key.sops.yaml,
#   5. deletes the temp dir. The private key is never printed.
# If it fails after step 3, remove the key with bootstrap/forgejo-ensure.sh delete-deploy-key.
#
#   scripts/new-deploy-key.sh <namespace> <project> <forgejo-repo>
# Refuses to overwrite an existing key file.
set -euo pipefail

readonly NAMESPACE=$1 PROJECT=$2 REPO=$3
readonly REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
readonly OUTPUT=$REPO_ROOT/apps/$NAMESPACE/$PROJECT/git-deploy-key.sops.yaml

if [[ -s $OUTPUT ]]; then
  echo "$OUTPUT already exists; delete it (and the deploy key in Forgejo) to rotate" >&2
  exit 1
fi
# Check cluster access first: registering the key runs a Job in the cluster, and failing there
# would leave an encrypted key file whose public half is gone.
kubectl --context homelab get namespace forgejo >/dev/null
mkdir -p "$(dirname "$OUTPUT")"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
ssh-keygen -q -t ed25519 -N "" -C "$PROJECT-dev-pod" -f "$workdir/key"
{
  echo "apiVersion: v1"
  echo "kind: Secret"
  echo "metadata:"
  echo "  name: git-deploy-key        # the overlay's namePrefix makes this <project>-git-deploy-key"
  echo "  namespace: $NAMESPACE"
  echo "type: kubernetes.io/ssh-auth"
  echo "stringData:"
  echo "  ssh-privatekey: |"
  sed 's/^/    /' "$workdir/key"
} > "$workdir/secret.yaml"
# Encrypt before registering, so a sops failure can't leave a registered key whose private half
# is gone; move the file into place only once the key is registered.
sops --encrypt --filename-override "$OUTPUT" "$workdir/secret.yaml" > "$workdir/encrypted.yaml"
"$REPO_ROOT/bootstrap/forgejo-ensure.sh" repo "$REPO" "$PROJECT-dev-pod" "$workdir/key.pub" read-write
mv "$workdir/encrypted.yaml" "$OUTPUT"
echo "Wrote $OUTPUT (private key not shown)"
