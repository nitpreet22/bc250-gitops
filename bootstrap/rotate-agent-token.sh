#!/usr/bin/env bash
# Gives the dashboard's homelab-agents (13_home_server_dashboard) a new shared token and hands it
# to the hub in the cluster. Runs on the PC. The token passes root to root through pipes only:
# it is never printed, logged or written to disk on the PC.
#
#   bootstrap/rotate-agent-token.sh
#
# 1. bc250-2 generates the new token into /etc/homelab/agent.token (root, 0600).
# 2. bc250-1 and bc250-3 get a copy; every board's agent restarts with it.
# 3. The cluster gets it as Secret ops/homelab-agent-token, created on bc250-2 from that file.
#    The Secret is deliberately not in Git (no SOPS copy of the value to manage); re-run this
#    script to recreate it after a cluster rebuild.
# 4. The Pi's sudo needs a password, so the token is left in the Pi user's home (0600) and the
#    script prints the one command to run there yourself.
#
# Until the Pi step is done the hub shows the Pi as unreachable; the Pi's own hub loses the
# boards as soon as step 2 runs (it is replaced by the cluster hub).
set -euo pipefail

readonly SOURCE=bc250-2
readonly OTHER_BOARDS=(bc250-1 bc250-3)
readonly PI=pi
readonly TOKEN_FILE=/etc/homelab/agent.token
readonly PI_STAGING='~/.homelab-agent.token'

copy_token_to() {
  ssh -n "$SOURCE" "sudo -n cat $TOKEN_FILE" | ssh "$1" "$2"
}

echo "Generating a new token on $SOURCE"
ssh -n "$SOURCE" "sudo -n sh -c 'umask 077; head -c 48 /dev/urandom | base64 -w0 > $TOKEN_FILE.new \
  && mv $TOKEN_FILE.new $TOKEN_FILE && restorecon $TOKEN_FILE && systemctl restart homelab-agent'"

for board in "${OTHER_BOARDS[@]}"; do
  copy_token_to "$board" "sudo -n install -m 0600 -o root -g root /dev/stdin $TOKEN_FILE \
    && sudo -n restorecon $TOKEN_FILE && sudo -n systemctl restart homelab-agent"
  echo "Installed on $board"
done

ssh -n "$SOURCE" "sudo -n sh -c 'k3s kubectl -n ops create secret generic homelab-agent-token \
  --from-file=agent-token=$TOKEN_FILE --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null'"
echo "Secret ops/homelab-agent-token updated"

copy_token_to "$PI" "umask 077; cat > $PI_STAGING"
# Check the file really landed before telling anyone to install it (it once went missing).
if ! ssh -n "$PI" "test -s $PI_STAGING"; then
  echo "Staging on the Pi failed: $PI_STAGING is missing or empty. Re-run this script." >&2
  exit 1
fi
cat <<EOF
Staged on the Pi as $PI_STAGING. Finish there (sudo asks for your password):

  ssh -t pi 'sudo install -m 0600 ~/.homelab-agent.token /etc/homelab/agent.token && rm ~/.homelab-agent.token && sudo sed -i "s|\"listen\": \"127.0.0.1:9877\"|\"listen\": \"192.168.1.66:9877\"|" /etc/homelab/agent.json && sudo systemctl restart homelab-agent'

That installs the token and makes the Pi's agent listen on the LAN so the cluster hub can reach it.
EOF
