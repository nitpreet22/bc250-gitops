#!/usr/bin/env bash
# Phase 4: the always-on herdr-core on bc250-2 that hosts the 24/7 agent terminals.
# Runs as the normal user (server), not root:
#
#   scp bootstrap/05-herdr.sh bootstrap/herdr-msg-key.pub scripts/hl scripts/agent-notify bc250-2:/tmp/ && ssh bc250-2 bash /tmp/05-herdr.sh
#
# Why a runtime on the board: a `kubectl exec` session dies when the machine running it sleeps,
# and that ends the attach to Claude Code in the pod. Terminals held here keep running; you look
# at them with the Herdr app (PC, Mac) or the Herdr phone app, which reach herdr-core over SSH.
# `hl` keeps a terminal (a Herdr space) per running project.
#
# Until 2026-11-10 this ran the herdr TUI server (`herdr --remote bc250-2`); the last step retires
# it where it still runs.
#
# Safe to re-run: the binary is replaced only when the version differs, and files are rewritten
# with the same content.
set -euo pipefail

# herdr-core (`hc`), pinned to the version the Herdr apps run (the PC's: `hc --version`); upgrade
# them together. Digest from releases.herdr.dev/core/<version>/manifest.json.
readonly HC_VERSION=0.1.19
readonly HC_SHA256=4adcfb423d52f24c5cc4a1e2cd2fcad1f62d28bb77876ac472c29082a3eaa424
readonly HC_URL=https://releases.herdr.dev/core/$HC_VERSION/herdr-core-linux-x86_64.tar.gz
readonly BIN_DIR=$HOME/.local/bin
readonly UNIT_DIR=$HOME/.config/systemd/user
readonly HL_SOURCE=$(dirname "$0")/hl
readonly NOTIFY_SOURCE=$(dirname "$0")/agent-notify
# The Claude pods' key for `hl relay` (scripts/new-herdr-msg-key.sh): messages between agents.
readonly MSG_KEY_SOURCE=$(dirname "$0")/herdr-msg-key.pub
# ntfy server and topic for agent-notify; not in Git (anyone with the topic can read the pushes).
readonly NOTIFY_CONFIG=$HOME/.config/agent-notify/env

step() { printf '\n==> %s\n' "$*"; }

[[ $EUID -ne 0 ]] || { echo "Run as the normal user, not root" >&2; exit 1; }
[[ -f $HL_SOURCE ]] || { echo "Copy scripts/hl next to this script" >&2; exit 1; }
[[ -f $NOTIFY_SOURCE ]] || { echo "Copy scripts/agent-notify next to this script" >&2; exit 1; }
[[ -f $MSG_KEY_SOURCE ]] || { echo "Copy bootstrap/herdr-msg-key.pub next to this script" >&2; exit 1; }
mkdir -p "$BIN_DIR" "$UNIT_DIR" "$HOME/.kube" "$HOME/.bashrc.d"
# The k3s kubectl reads the root-only /etc/rancher/k3s/k3s.yaml unless KUBECONFIG says otherwise.
export KUBECONFIG=$HOME/.kube/config

step "lingering: user services and the core run without a login and after a reboot"
sudo -n loginctl enable-linger "$(whoami)"

step "herdr-core $HC_VERSION (hc)"
if [[ -x $BIN_DIR/herdr-core ]] && "$BIN_DIR/herdr-core" --version 2>/dev/null | grep -qxF "hc $HC_VERSION"; then
  echo "already installed"
else
  tmp=$(mktemp -d)
  curl -fsSL --retry 3 "$HC_URL" -o "$tmp/hc.tar.gz"
  echo "$HC_SHA256  $tmp/hc.tar.gz" | sha256sum --check --quiet
  tar -xzf "$tmp/hc.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/herdr-core" "$BIN_DIR/herdr-core"
  rm -rf "$tmp"
  # An already running core keeps the old binary until restarted; its terminals keep running.
  "$BIN_DIR/herdr-core" server status >/dev/null 2>&1 && "$BIN_DIR/herdr-core" server restart >/dev/null
fi
ln -sfn herdr-core "$BIN_DIR/hc"
# No unit of our own: the core starts itself as a transient systemd user service (hc-serve-*),
# which lingering keeps alive without a login; after a reboot hl-sync (below) starts it again.
"$BIN_DIR/herdr-core" server start >/dev/null
"$BIN_DIR/hc" --version

step "kubectl context 'homelab' for $(whoami) (cluster admin, this board only)"
sudo -n cat /etc/rancher/k3s/k3s.yaml | sed \
  -e 's/^\(\s*\)name: default$/\1name: homelab/' \
  -e 's/^\(\s*\)cluster: default$/\1cluster: homelab/' \
  -e 's/^\(\s*\)user: default$/\1user: homelab/' \
  -e 's/^- name: default$/- name: homelab/' \
  -e 's/^current-context: default$/current-context: homelab/' > "$HOME/.kube/config.new"
chmod 600 "$HOME/.kube/config.new"
mv "$HOME/.kube/config.new" "$HOME/.kube/config"
# Fedora's ~/.bashrc sources ~/.bashrc.d/*, so shells (and core terminals) get it too.
printf '%s\n' "# Written by homelab bootstrap/05-herdr.sh" "export KUBECONFIG=$KUBECONFIG" \
  > "$HOME/.bashrc.d/homelab-kubeconfig.sh"
kubectl --context homelab get nodes --no-headers | awk '{print "  " $1, $2}'

step "hl"
install -m 0755 "$HL_SOURCE" "$BIN_DIR/hl"
"$BIN_DIR/hl" ls

step "herdr-core: the hl launcher plus a terminal (a Herdr space) per running project"
PATH=$BIN_DIR:$PATH "$BIN_DIR/hl" sync

step "hl sync at boot (herdr-core gives lost terminals a plain shell; this puts hl back)"
unit=$UNIT_DIR/hl-sync.service
new_unit=$(cat <<EOF
# Written by homelab bootstrap/05-herdr.sh
[Unit]
Description=hl sync: the dev pods' terminals in herdr-core
After=network-online.target

[Service]
Type=oneshot
Environment=PATH=$BIN_DIR:/usr/local/bin:/usr/bin:/bin
Environment=KUBECONFIG=$KUBECONFIG
ExecStartPre=$BIN_DIR/hc server start
ExecStart=$BIN_DIR/hl sync
# k3s may not answer yet right after boot.
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
EOF
)
if [[ ! -f $unit || $(cat "$unit") != "$new_unit" ]]; then
  printf '%s\n' "$new_unit" > "$unit"
  systemctl --user daemon-reload
  systemctl --user enable hl-sync.service
fi
systemctl --user is-enabled hl-sync.service

step "agent-notify: ntfy pushes when an agent needs you or finishes"
install -m 0755 "$NOTIFY_SOURCE" "$BIN_DIR/agent-notify"
unit=$UNIT_DIR/agent-notify.service
new_unit=$(cat <<EOF
# Written by homelab bootstrap/05-herdr.sh
[Unit]
Description=agent-notify: push herdr-core agents' needs-you / finished to ntfy
After=network-online.target hl-sync.service

[Service]
Environment=PATH=$BIN_DIR:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/python3 $BIN_DIR/agent-notify
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
)
if [[ ! -f $NOTIFY_CONFIG ]] || ! grep -q '^NTFY_TOPIC=.' "$NOTIFY_CONFIG"; then
  echo "skipped: no NTFY_TOPIC in $NOTIFY_CONFIG (write NTFY_URL= and NTFY_TOPIC= there, mode 600)"
else
  if [[ ! -f $unit || $(cat "$unit") != "$new_unit" ]]; then
    printf '%s\n' "$new_unit" > "$unit"
    systemctl --user daemon-reload
    systemctl --user enable agent-notify.service
  fi
  # Restart picks up a new script or config; it sends nothing for the opening snapshot.
  systemctl --user restart agent-notify.service
  systemctl --user is-active agent-notify.service
fi

step "the herdr TUI server: retired (the agents are in herdr-core)"
if [[ -f $UNIT_DIR/herdr-server.service ]]; then
  systemctl --user disable --now herdr-server.service
  rm -f "$UNIT_DIR/herdr-server.service"
  systemctl --user daemon-reload
  echo "stopped and removed herdr-server.service"
else
  echo "not installed"
fi

step "hl relay: Claude pods message each other (hl msg), only through this forced command"
# restrict: no shell, pty or forwarding; the key can run `hl relay` and nothing else. The relay
# allows "msg ls" and "msg send <project>" and names the sender from the calling pod's IP.
msg_key_line="restrict,command=\"env KUBECONFIG=$HOME/.kube/config PATH=$BIN_DIR:/usr/local/bin:/usr/bin:/bin $BIN_DIR/hl relay\" $(cat "$MSG_KEY_SOURCE")"
authorized=$HOME/.ssh/authorized_keys
install -d -m 0700 "$HOME/.ssh"
touch "$authorized" && chmod 600 "$authorized"
# One line per key: drop an older line for this key comment, then add the current one.
grep -v 'herdr-msg (Claude pods -> hl relay)' "$authorized" > "$authorized.new" || true
printf '%s\n' "$msg_key_line" >> "$authorized.new"
mv "$authorized.new" "$authorized"
grep -c 'hl relay' "$authorized"
