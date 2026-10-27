#!/usr/bin/env bash
# Builds an image on bc250-2 and pushes it to the in-cluster registry.
# Runs on the PC; only the small build context crosses the network, never the image.
#
#   bootstrap/build-image.sh <name> <tag>                 context: images/<name>/ in this repo
#   bootstrap/build-image.sh <name> <tag> <project-repo>  context: that repo's committed HEAD
#   ... [--context <id>=<repo>]...                         extra named contexts (COPY --from=<id>)
#   ... [--target <stage>]                                 build that Containerfile stage
#   e.g. bootstrap/build-image.sh agent 2026-10-27.1
#        bootstrap/build-image.sh homelab-hub 2026-10-28.1 ../13_home_server_dashboard
#
# Repos are sent with `git archive HEAD`, so the image matches commits: uncommitted changes are
# not included (the script refuses to build when there are any).
set -euo pipefail

readonly NAME=$1 TAG=$2
shift 2
readonly BUILDER=bc250-2
readonly REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
readonly REMOTE_BASE=/var/lib/homelab-build/$NAME

project_repo=""
extra_contexts=()   # "<id>=<repo path>"
target_args=()      # (--target <stage>) when one stage of a multi-stage Containerfile is wanted
while [[ $# -gt 0 ]]; do
  case $1 in
    --context) extra_contexts+=("$2"); shift 2 ;;
    --target) target_args=(--target "$2"); shift 2 ;;
    *) project_repo=$1; shift ;;
  esac
done

# Sends a directory's tar stream to <remote dir> on the builder, replacing what was there.
send_to() {
  ssh "$BUILDER" "sudo -n rm -rf $1 && sudo -n install -d $1 && sudo -n tar -C $1 -xf -"
}

# git archive of a repo's HEAD, refusing uncommitted changes to tracked files (untracked files
# are never in the archive, so they don't matter).
archive_repo() {
  local repo=$1
  if [[ -n $(git -C "$repo" status --porcelain --untracked-files=no) ]]; then
    echo "$repo has uncommitted changes; commit them first so the image matches a commit" >&2
    exit 1
  fi
  echo "Context from $repo at $(git -C "$repo" rev-parse --short HEAD)" >&2
  git -C "$repo" archive --format=tar HEAD
}

if [[ -n $project_repo ]]; then
  [[ -f $project_repo/Containerfile ]] || { echo "No Containerfile in $project_repo" >&2; exit 1; }
  archive_repo "$project_repo" | send_to "$REMOTE_BASE/main"
else
  readonly CONTEXT=$REPO_ROOT/images/$NAME
  [[ -f $CONTEXT/Containerfile ]] || { echo "No Containerfile in images/$NAME" >&2; exit 1; }
  tar -C "$CONTEXT" -cf - . | send_to "$REMOTE_BASE/main"
fi

build_args=()
for entry in "${extra_contexts[@]}"; do
  id=${entry%%=*}
  archive_repo "${entry#*=}" | send_to "$REMOTE_BASE/$id"
  build_args+=("$id=$REMOTE_BASE/$id")
done

exec "$REPO_ROOT/bootstrap/run-detached.sh" "$BUILDER" "$REPO_ROOT/bootstrap/podman-build.sh" \
  "$REMOTE_BASE/main" "$NAME" "$TAG" "${target_args[@]}" "${build_args[@]}"
