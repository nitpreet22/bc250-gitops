#!/usr/bin/env bash
# Generates the secrets of the ml S3 store (apps/ml/dvc-store, Garage) and writes them as SOPS
# Secrets; nothing is printed:
#   apps/ml/dvc-store/garage.sops.yaml    rpc_secret, admin_token      (the Garage node itself)
#   apps/ml/dvc-store/s3-dvc.sops.yaml  access_key_id, secret_access_key (the DVC remote's key,
#                                         imported into Garage at start; read by ML dev pods)
# Garage's formats: RPC secret 32 random bytes as hex; access key id "GK" + 12 bytes as hex;
# secret key 32 bytes as hex.
#
#   scripts/new-dvc-store-secrets.sh
# Refuses to overwrite existing files.
set -euo pipefail

readonly REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
readonly OUT_DIR=$REPO_ROOT/apps/ml/dvc-store
readonly GARAGE_FILE=$OUT_DIR/garage.sops.yaml
readonly KEY_FILE=$OUT_DIR/s3-dvc.sops.yaml

for file in "$GARAGE_FILE" "$KEY_FILE"; do
  if [[ -e $file ]]; then
    echo "$file already exists; delete it first to rotate (and restart the store)" >&2
    exit 1
  fi
done
mkdir -p "$OUT_DIR"

# Plaintext only ever exists in this private temp dir, which is removed on exit.
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
chmod 700 "$workdir"

random_hex() { openssl rand -hex "$1"; }

cat > "$workdir/garage.sops.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
    name: garage # the overlay's namePrefix makes this dvc-store-garage
    namespace: ml
type: Opaque
stringData:
    rpc_secret: $(random_hex 32)
    admin_token: $(random_hex 32)
EOF

cat > "$workdir/s3-dvc.sops.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
    name: s3-dvc # the overlay's namePrefix makes this dvc-store-s3-dvc
    namespace: ml
type: Opaque
stringData:
    access_key_id: GK$(random_hex 12)
    secret_access_key: $(random_hex 32)
EOF

# sops picks the creation rule by file name, so encrypt in the repo's config context.
(cd "$REPO_ROOT" && sops --encrypt --filename-override "$GARAGE_FILE" "$workdir/garage.sops.yaml" > "$workdir/garage.enc")
(cd "$REPO_ROOT" && sops --encrypt --filename-override "$KEY_FILE" "$workdir/s3-dvc.sops.yaml" > "$workdir/s3-dvc.enc")
mv "$workdir/garage.enc" "$GARAGE_FILE"
mv "$workdir/s3-dvc.enc" "$KEY_FILE"
echo "Wrote $GARAGE_FILE and $KEY_FILE (values not shown)"
