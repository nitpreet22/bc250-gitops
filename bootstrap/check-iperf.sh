#!/usr/bin/env bash
# Measures TCP throughput between every pair of boards, both directions, with iperf3.
# Runs on the PC (Git Bash); talks to the boards over SSH. Safe to re-run.
#
#   bootstrap/check-iperf.sh [seconds=10]
#
# Each server board opens port 5201 in firewalld for this run only (--timeout), so a
# dropped connection can't leave the port open. iperf3 is installed if missing.
set -euo pipefail

readonly BOARDS=(bc250-1 bc250-2 bc250-3)
readonly SECONDS_PER_TEST=${1:-10}
readonly IPERF_PORT=5201

for board in "${BOARDS[@]}"; do
  ssh -n "$board" 'rpm -q iperf3 >/dev/null 2>&1 || sudo -n dnf install -y -q iperf3 >/dev/null'
done

printf '%-8s -> %-8s %10s %8s\n' from to "Mbit/s" retrans
for server in "${BOARDS[@]}"; do
  # Open the port for 2 minutes, start a one-shot server, then test from each other board.
  # Board-to-board traffic lands in the homelab-nodes zone once 02-k3s.sh has run.
  ssh -n "$server" "zone=\$(sudo -n firewall-cmd --get-zones | tr ' ' '\n' | grep -x homelab-nodes || sudo -n firewall-cmd --get-default-zone); \
    sudo -n firewall-cmd -q --zone=\$zone --add-port=$IPERF_PORT/tcp --timeout=120"
  for client in "${BOARDS[@]}"; do
    [[ $client == "$server" ]] && continue
    ssh -n "$server" "iperf3 -s -1 -p $IPERF_PORT -D"
    sleep 1
    result=$(ssh -n "$client" "iperf3 -c $server -p $IPERF_PORT -t $SECONDS_PER_TEST -J" \
      | grep -oE '"(bits_per_second|retransmits)":[[:space:]]*[0-9.e+]+' | tail -2)
    mbits=$(echo "$result" | sed -n 's/.*bits_per_second":[[:space:]]*//p' | awk '{printf "%.0f", $1/1e6}')
    retrans=$(echo "$result" | sed -n 's/.*retransmits":[[:space:]]*//p')
    printf '%-8s -> %-8s %10s %8s\n' "$client" "$server" "$mbits" "${retrans:-?}"
  done
  ssh -n "$server" "zone=\$(sudo -n firewall-cmd --get-zones | tr ' ' '\n' | grep -x homelab-nodes || sudo -n firewall-cmd --get-default-zone); \
    sudo -n firewall-cmd -q --zone=\$zone --remove-port=$IPERF_PORT/tcp || true"
done
