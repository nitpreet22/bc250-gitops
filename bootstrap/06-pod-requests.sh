#!/usr/bin/env bash
# The pod-requests timer on bc250-2: every 5 minutes, scripts/pod-requests.py applies the safe part
# of dev pods' requests for changes to their own pod (README "Pod requests"). Runs as the normal
# user (server), like 05-herdr.sh, after it:
#
#   scp bootstrap/06-pod-requests.sh bc250-2:/tmp/ && ssh bc250-2 bash /tmp/06-pod-requests.sh
#
# What it sets up:
#   - a Forgejo API token for the admin user (repository read/write), in ~/.config/pod-requests/token
#     (mode 600, never printed). The admin password is read from the forgejo-admin Secret and passed
#     to curl on stdin, so it never appears in a command line;
#   - the program's own clone of homelab (~/.local/share/pod-requests/homelab). The service runs
#     the script from that clone and resets it to origin/main every run, so a pushed change to the
#     script is live from the next run;
#   - systemd user units pod-requests.service (oneshot) and pod-requests.timer.
# Image builds run podman as root through sudo -n, which this user already has (05-herdr.sh).
#
# Safe to re-run: an existing token and clone are kept; units are rewritten.
# Logs: journalctl --user -u pod-requests.   One run by hand: systemctl --user start pod-requests
set -euo pipefail

readonly CONFIG_DIR=$HOME/.config/pod-requests
readonly TOKEN_FILE=$CONFIG_DIR/token
readonly CLONE=$HOME/.local/share/pod-requests/homelab
readonly UNIT_DIR=$HOME/.config/systemd/user
readonly FORGEJO=http://127.0.0.1:30300
readonly TOKEN_NAME=pod-requests
export KUBECONFIG=$HOME/.kube/config

step() { printf '\n==> %s\n' "$*"; }

[[ $EUID -ne 0 ]] || { echo "Run as the normal user, not root" >&2; exit 1; }
for tool in python3 git curl jq kubectl hc podman; do
  command -v "$tool" >/dev/null || [[ -x $HOME/.local/bin/$tool ]] || { echo "missing: $tool" >&2; exit 1; }
done
python3 -c 'import yaml' || { echo "missing: python3-pyyaml" >&2; exit 1; }
sudo -n true || { echo "needs passwordless sudo (image builds run podman as root)" >&2; exit 1; }

secret_field() {
  kubectl --context homelab -n forgejo get secret forgejo-admin -o "jsonpath={.data.$1}" | base64 -d
}

step "Forgejo token '$TOKEN_NAME'"
if [[ -s $TOKEN_FILE ]]; then
  echo "kept (delete $TOKEN_FILE and re-run to replace it)"
else
  install -d -m 700 "$CONFIG_DIR"
  user=$(secret_field username)
  password=$(secret_field password)
  # curl's config syntax: backslashes and double quotes inside "..." are escaped.
  password=${password//\\/\\\\}
  password=${password//\"/\\\"}
  # curl -K - reads its options from stdin; printf is a shell builtin, so no process sees them.
  api() {
    printf 'user = "%s:%s"\n' "$user" "$password" |
      curl -sS -K - -H 'Content-Type: application/json' "$@"
  }
  # A token of that name from an earlier install can't be read back; replace it.
  api -o /dev/null -X DELETE "$FORGEJO/api/v1/users/$user/tokens/$TOKEN_NAME" || true
  (
    umask 077
    api -X POST "$FORGEJO/api/v1/users/$user/tokens" \
      -d "{\"name\": \"$TOKEN_NAME\", \"scopes\": [\"write:repository\", \"read:user\"]}" |
      jq -er '.sha1' > "$TOKEN_FILE"
  )
  unset password
  echo "created ($(wc -c < "$TOKEN_FILE") bytes, mode $(stat -c %a "$TOKEN_FILE"))"
fi

step "homelab clone for pod-requests"
if [[ -d $CLONE/.git ]]; then
  echo "kept: $CLONE"
else
  mkdir -p "$(dirname "$CLONE")"
  # The token goes through git's environment config, never the command line.
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
    GIT_CONFIG_VALUE_0="Authorization: token $(cat "$TOKEN_FILE")" \
    git clone -q "$FORGEJO/nitpreet22/homelab.git" "$CLONE"
  git -C "$CLONE" config user.name pod-requests
  git -C "$CLONE" config user.email pod-requests@bc250-2.homelab.lan
  echo "cloned: $CLONE at $(git -C "$CLONE" rev-parse --short HEAD)"
fi

step "systemd user units"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/pod-requests.service" <<EOF
# Written by homelab bootstrap/06-pod-requests.sh
[Unit]
Description=Apply dev pods' safe requests for their own pod (homelab scripts/pod-requests.py)
After=network-online.target

[Service]
Type=oneshot
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=KUBECONFIG=$KUBECONFIG
ExecStart=/usr/bin/python3 $CLONE/scripts/pod-requests.py
# Image builds and waiting for a rollout can take a while.
TimeoutStartSec=45min
EOF
cat > "$UNIT_DIR/pod-requests.timer" <<EOF
# Written by homelab bootstrap/06-pod-requests.sh
[Unit]
Description=Run pod-requests every 5 minutes

[Timer]
OnBootSec=3min
OnUnitInactiveSec=5min

[Install]
WantedBy=timers.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now pod-requests.timer
systemctl --user list-timers pod-requests.timer --no-pager | head -3

step "one dry run"
python3 "$CLONE/scripts/pod-requests.py" --dry-run
