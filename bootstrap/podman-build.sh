#!/usr/bin/env bash
# Runs on bc250-2 (via bootstrap/build-image.sh): builds an image with podman and pushes it to the
# in-cluster registry. Safe to re-run: podman reuses cached layers and the push is idempotent.
#
#   podman-build.sh <context-dir> <name> <tag> [--target <stage>] [<id>=<dir>]...
#     --target       build only up to that Containerfile stage (multi-stage, one image per stage)
#     <id>=<dir>     extra named build contexts
set -euo pipefail

readonly CONTEXT=$1 NAME=$2 TAG=$3
shift 3
target_args=()
if [[ ${1:-} == --target ]]; then
  target_args=(--target "$2")
  shift 2
fi
readonly REGISTRY=192.168.1.106:30500     # the registry's NodePort (infrastructure/registry)
readonly TARGET=$REGISTRY/$NAME:$TAG
readonly REGISTRY_CONF=/etc/containers/registries.conf.d/50-homelab.conf

[[ -f $CONTEXT/Containerfile ]] || { echo "No Containerfile in $CONTEXT" >&2; exit 1; }

# Images can build FROM other homelab images, so podman may pull from the registry (plain HTTP,
# cluster network only) as well as push to it.
if [[ ! -f $REGISTRY_CONF ]]; then
  printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "$REGISTRY" > "$REGISTRY_CONF"
fi

context_args=()
for entry in "$@"; do
  context_args+=(--build-context "$entry")
done

echo "Building $TARGET from $CONTEXT ${target_args[*]:+(${target_args[*]}) }${*:+(extra contexts: $*)}"
podman build --pull=newer "${target_args[@]}" "${context_args[@]}" --tag "$TARGET" "$CONTEXT"
podman push "$TARGET"
echo "Pushed $TARGET (pull it in manifests as registry.homelab.lan/$NAME:$TAG)"
podman image prune --force --filter "until=168h" >/dev/null
