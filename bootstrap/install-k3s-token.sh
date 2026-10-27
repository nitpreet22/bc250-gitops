#!/usr/bin/env bash
# Copies the k3s cluster token from the server (bc250-2) to an agent board, root to root.
# Runs on the PC. The token passes through this pipe only: it is never printed, logged or
# written to disk on the PC.
#
#   bootstrap/install-k3s-token.sh bc250-1
set -euo pipefail

readonly SERVER=bc250-2
readonly AGENT=$1
readonly TOKEN_FILE=/etc/rancher/k3s/cluster-token

ssh -n "$SERVER" "sudo -n cat $TOKEN_FILE" \
  | ssh "$AGENT" "sudo -n install -D -m 0600 -o root -g root /dev/stdin $TOKEN_FILE"
ssh -n "$AGENT" "sudo -n test -s $TOKEN_FILE" && echo "Token installed on $AGENT"
