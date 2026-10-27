#!/usr/bin/env bash
# Rebuilds Wolf's config.toml on every start, then hands over to Wolf's own entrypoint.
#
# What's kept from the existing file (on the pod's volume): the host uuid (Moonlight recognises the
# host by it) and [[paired_clients]] (pairings). Everything else comes from this image:
#   - gstreamer pipelines: Wolf's defaults with only the H.264 encoders (ending in x264). Without
#     HEVC/AV1 encoders Wolf can't offer them, so Moonlight never picks the much heavier software
#     x265/aom encoders on a board with no hardware encoder.
#   - one Moonlight profile with a single app, "Desktop": labwc as the user retro (desktop-session),
#     starting DESKTOP_COMMAND inside it.
# Config format: Wolf config_version 7 (checked against the base image in images/desktop/Containerfile).
#
# Environment (templates/desktop and the instance overlay):
#   DESKTOP_NAME      name shown in Moonlight's host list
#   DESKTOP_COMMAND   what starts inside the desktop (default: a terminal, foot)
#   WOLF_*_PORT       this instance's port block
set -euo pipefail

readonly CONFIG=${WOLF_CFG_FILE:-/etc/wolf/cfg/config.toml}
readonly PIPELINES=/etc/homelab/gstreamer-h264-only.toml   # starts with config_version = 7

mkdir -p "$(dirname "$CONFIG")"

uuid=""
paired_clients=""
if [[ -s $CONFIG ]]; then
  uuid=$(sed -n "s/^uuid = ['\"]\(.*\)['\"]$/\1/p" "$CONFIG" | head -1)
  # Everything from the first [[paired_clients]] up to the first [[profiles]].
  paired_clients=$(awk '/^\[\[profiles\]\]/ { exit } /^\[\[paired_clients\]\]/ { keep = 1 } keep' "$CONFIG")
fi
[[ -n $uuid ]] || uuid=$(cat /proc/sys/kernel/random/uuid)

{
  head -n 1 "$PIPELINES"
  echo "hostname = '${DESKTOP_NAME:-homelab-desktop}'"
  echo "uuid = '$uuid'"
  tail -n +2 "$PIPELINES"
  [[ -n $paired_clients ]] && printf '\n%s\n' "$paired_clients"
  cat <<TOML

[[profiles]]
id = 'moonlight-profile-id'

    [[profiles.apps]]
    start_virtual_compositor = true
    title = 'Desktop'

        [profiles.apps.runner]
        run_cmd = '/usr/local/bin/desktop-session ${DESKTOP_COMMAND:-foot}'
        type = 'process'
TOML
} > "$CONFIG.new"
mv "$CONFIG.new" "$CONFIG"
echo "[desktop-entrypoint] wrote $CONFIG ($(grep -c '^\[\[paired_clients\]\]' "$CONFIG") paired client(s))"

exec /entrypoint.sh "$@"
