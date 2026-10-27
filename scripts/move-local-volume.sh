#!/usr/bin/env bash
# Moves a local-path volume (k3s's default storage class) to another board. The PVC keeps its
# name, so nothing that mounts it changes. Runs on the PC; the data passes through it over ssh.
#
#   scripts/move-local-volume.sh <namespace> <pvc> <target-board>
#   e.g. scripts/move-local-volume.sh ml my-project-data bc250-2
#
# A local-path volume is a directory on one board, and its PV is pinned to that board for good
# (a PV's node affinity can't be edited). So the PVC is made again on the target board:
#   1. Checks: the PVC is Bound to a local-path PV on another board, no pod references it (not even
#      a finished one, which would hold up the PVC's deletion), and
#      Flux won't recreate it halfway (its Flux Kustomization is suspended, or it isn't Flux's).
#   2. The old PV is set to Retain, so deleting it leaves the old directory where it is.
#   3. The PVC and PV objects are deleted, and the PVC is created again with the same spec and
#      labels, plus the annotation volume.kubernetes.io/selected-node=<target>. That annotation is
#      what the scheduler normally sets when a pod first uses the PVC; set by hand, it makes the
#      provisioner create the new directory on the target right away, before any pod starts.
#   4. The old directory is copied into the new one (tar, numeric owners and modes kept), the
#      SELinux labels are reset to the defaults for k3s storage, and the file count and byte total
#      are compared.
#
# The old directory stays on the old board as a fallback; the script prints the command that
# deletes it, for once the app is checked. If a step fails, the old directory is still intact.
set -euo pipefail

readonly KUBECTL=(kubectl --context homelab)
readonly NAMESPACE=${1:?usage: move-local-volume.sh <namespace> <pvc> <target-board>}
readonly PVC=${2:?usage: move-local-volume.sh <namespace> <pvc> <target-board>}
readonly TARGET=${3:?usage: move-local-volume.sh <namespace> <pvc> <target-board>}

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

pvc_field() { "${KUBECTL[@]}" -n "$NAMESPACE" get pvc "$PVC" -o jsonpath="$1"; }
pv_field() { "${KUBECTL[@]}" get pv "$1" -o jsonpath="$2"; }

# Prints "<file count> <bytes>" for a directory on a board, for comparing the copy with the source.
directory_size() {
  ssh -n "$1" "sudo -n sh -c 'echo \$(find \"$2\" | wc -l) \$(du -sb \"$2\" | cut -f1)'"
}

# Prints "<pod> <phase>" for every pod in the namespace whose volumes name the PVC.
pods_using_pvc() {
  "${KUBECTL[@]}" -n "$NAMESPACE" get pods -o jsonpath="{range .items[*]}{.metadata.name} {.status.phase} {range .spec.volumes[*]}{.persistentVolumeClaim.claimName} {end}{'\n'}{end}" \
    | awk -v pvc="$PVC" '{for (i = 3; i <= NF; i++) if ($i == pvc) print $1, $2}'
}

# Refuses when any pod still references the PVC. A running pod would keep writing to the old
# directory. A finished one (Succeeded or Failed, e.g. a backup Job's pod) writes nothing, but
# PVC protection still counts it as a user, so the PVC's deletion would hang until it's gone.
require_unused() {
  local running finished
  running=$(pods_using_pvc | awk '$2 != "Succeeded" && $2 != "Failed" {print $1 " (" $2 ")"}')
  finished=$(pods_using_pvc | awk '$2 == "Succeeded" || $2 == "Failed" {print $1}')
  [[ $running == "" ]] || die "these pods still mount $PVC; scale them to 0 first:
$running"
  [[ $finished == "" ]] || die "these finished pods still reference $PVC, and would hold up its deletion; delete them first:
  ${KUBECTL[*]} -n $NAMESPACE delete pod $(echo $finished)"
}

# Refuses when Flux could put the PVC back (unpinned) between our delete and create.
require_flux_suspended() {
  local owner owner_namespace suspended
  owner=$(pvc_field '{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')
  owner_namespace=$(pvc_field '{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/namespace}')
  [[ $owner == "" ]] && return 0
  suspended=$("${KUBECTL[@]}" -n "$owner_namespace" get kustomizations.kustomize.toolkit.fluxcd.io "$owner" -o jsonpath='{.spec.suspend}')
  [[ $suspended == true ]] || die "Flux Kustomization $owner_namespace/$owner manages $PVC and isn't suspended:
  ${KUBECTL[*]} -n $owner_namespace patch kustomization $owner --type merge -p '{\"spec\":{\"suspend\":true}}'"
}

step "Checking $NAMESPACE/$PVC"
"${KUBECTL[@]}" -n "$NAMESPACE" get pvc "$PVC" >/dev/null 2>&1 \
  || die "no PVC $PVC in namespace $NAMESPACE (list them: ${KUBECTL[*]} -n $NAMESPACE get pvc)"
[[ $(pvc_field '{.status.phase}') == Bound ]] || die "$PVC is not Bound"
[[ $(pvc_field '{.spec.storageClassName}') == local-path ]] || die "$PVC is not a local-path volume"
old_pv=$(pvc_field '{.spec.volumeName}')
source_board=$(pv_field "$old_pv" '{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')
old_path=$(pv_field "$old_pv" '{.spec.local.path}')
[[ $source_board != "$TARGET" ]] || die "$PVC is already on $TARGET"
[[ -n $source_board && -n $old_path ]] || die "can't read the board or directory of PV $old_pv"
"${KUBECTL[@]}" get node "$TARGET" >/dev/null
require_unused
require_flux_suspended
echo "$old_pv: $source_board:$old_path"
read -r old_files old_bytes < <(directory_size "$source_board" "$old_path")
echo "$old_files files, $old_bytes bytes"

# The spec and labels of the new PVC, read before the old one goes. jsonpath prints maps and lists
# as JSON, so they drop straight into the JSON manifest below.
labels=$(pvc_field '{.metadata.labels}')
access_modes=$(pvc_field '{.spec.accessModes}')
volume_mode=$(pvc_field '{.spec.volumeMode}')
storage=$(pvc_field '{.spec.resources.requests.storage}')
[[ -n $labels ]] || labels='{}'
new_pvc_manifest=$(cat <<EOF
{
  "apiVersion": "v1",
  "kind": "PersistentVolumeClaim",
  "metadata": {
    "name": "$PVC",
    "namespace": "$NAMESPACE",
    "labels": $labels,
    "annotations": {"volume.kubernetes.io/selected-node": "$TARGET"}
  },
  "spec": {
    "accessModes": $access_modes,
    "storageClassName": "local-path",
    "volumeMode": "$volume_mode",
    "resources": {"requests": {"storage": "$storage"}}
  }
}
EOF
)

step "Keeping the old directory: $old_pv reclaim policy Retain"
"${KUBECTL[@]}" patch pv "$old_pv" --type merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null

step "Recreating $PVC on $TARGET"
"${KUBECTL[@]}" -n "$NAMESPACE" delete pvc "$PVC" --wait=true
"${KUBECTL[@]}" delete pv "$old_pv" --wait=true
printf '%s\n' "$new_pvc_manifest" | "${KUBECTL[@]}" create -f -
"${KUBECTL[@]}" -n "$NAMESPACE" wait pvc "$PVC" --for=jsonpath='{.status.phase}'=Bound --timeout=120s
new_pv=$(pvc_field '{.spec.volumeName}')
new_path=$(pv_field "$new_pv" '{.spec.local.path}')
[[ $(pv_field "$new_pv" '{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}') == "$TARGET" ]] ||
  die "the new PV $new_pv is not on $TARGET"
echo "$new_pv: $TARGET:$new_path"

step "Copying $source_board:$old_path -> $TARGET:$new_path"
ssh -n "$source_board" "sudo -n tar --numeric-owner -C '$old_path' -cpf - ." |
  ssh "$TARGET" "sudo -n tar --numeric-owner -C '$new_path' -xpf - && sudo -n restorecon -R '$new_path'"

step "Comparing"
read -r new_files new_bytes < <(directory_size "$TARGET" "$new_path")
echo "source $old_files files, $old_bytes bytes; copy $new_files files, $new_bytes bytes"
[[ $new_files == "$old_files" ]] || die "file counts differ; the old directory is untouched on $source_board"
# The new directory's own entry can differ in size from the old one's; allow 64 KiB.
(( new_bytes - old_bytes < 65536 && old_bytes - new_bytes < 65536 )) ||
  die "byte totals differ; the old directory is untouched on $source_board"

echo
echo "Done. $NAMESPACE/$PVC is on $TARGET. Once the app is checked, delete the old copy:"
echo "  ssh $source_board sudo rm -rf '$old_path'"
