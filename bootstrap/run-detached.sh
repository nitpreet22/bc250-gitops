#!/usr/bin/env bash
# Runs a bootstrap script on a board as root, detached from the SSH session, and follows its log.
# Runs on the PC (Git Bash). If SSH drops or the PC sleeps, the script keeps running on the board;
# re-run this command to follow it again (it won't start a second copy while one is running).
#
#   bootstrap/run-detached.sh <board> <script> [args...]
#   e.g. bootstrap/run-detached.sh bc250-2 bootstrap/02-k3s.sh server
#
# On the board: the script is copied to /var/lib/homelab-bootstrap/, runs as the transient unit
# homelab-<script name>, and logs to /var/log/homelab-<script name>.log.
# Exit status: the script's own exit status.
set -euo pipefail

readonly BOARD=$1
readonly SCRIPT=$2
shift 2
readonly NAME=$(basename "$SCRIPT" .sh)
readonly UNIT=homelab-$NAME
readonly REMOTE_DIR=/var/lib/homelab-bootstrap
readonly LOG=/var/log/homelab-$NAME.log

# "running" while the script executes; "exited" or "failed" once it has finished.
unit_substate() { ssh -n "$BOARD" "systemctl show -p SubState --value $UNIT.service" 2>/dev/null; }

if [[ $(unit_substate) == running ]]; then
  echo "$UNIT is already running on $BOARD; following its log."
else
  scp -q "$SCRIPT" "$BOARD:/tmp/$NAME.sh"
  # Clear the finished unit from a previous run, then start a new one.
  # printf %q keeps each argument intact through the remote shell.
  ssh -n "$BOARD" "sudo -n install -D -m 0700 /tmp/$NAME.sh $REMOTE_DIR/$NAME.sh && rm /tmp/$NAME.sh \
    && { sudo -n systemctl stop $UNIT.service 2>/dev/null; sudo -n systemctl reset-failed $UNIT.service 2>/dev/null; true; } \
    && sudo -n systemd-run --quiet --unit=$UNIT -p RemainAfterExit=yes \
      -p StandardOutput=truncate:$LOG -p StandardError=inherit \
      bash $REMOTE_DIR/$NAME.sh $(printf '%q ' "$@")"
  echo "Started $UNIT on $BOARD (log: $LOG)"
fi

# Follow the log until the script finishes, printing only new lines each poll.
printed=0
while :; do
  substate=$(unit_substate)
  lines=$(ssh -n "$BOARD" "sudo -n tail -n +$((printed + 1)) $LOG" 2>/dev/null || true)
  if [[ -n $lines ]]; then
    printf '%s\n' "$lines"
    printed=$((printed + $(printf '%s\n' "$lines" | wc -l)))
  fi
  [[ $substate == running || $substate == start ]] || break
  sleep 5
done

result=$(ssh -n "$BOARD" "systemctl show -p ExecMainStatus --value $UNIT.service")
echo "== $UNIT on $BOARD finished with exit status $result"
exit "$result"
