#!/usr/bin/env bash
# Phase 8: does the kubelet evict in the designed order under real memory pressure?
# Fills bc250-1 (an on-demand board: power it on first; normally nothing else runs there) with
# four pods in a throwaway namespace:
#   live-bot   live-critical, Guaranteed (requests = limits)
#   service    service priority, using more than it requested
#   agent      agent priority, using more than it requested
#   batch      batch priority, using more than it requested
# One of them grows by 128 MiB every 2 s until something gives (the "grower"):
#   tests/eviction-order.sh          batch grows. Expected: batch is evicted; the rest untouched.
#   tests/eviction-order.sh agent    agent grows, batch holds 1 GiB. Expected: batch is evicted
#                                    first although agent uses far more (priority beats size),
#                                    then agent; service and live-bot untouched.
# The kubelet should do the evicting ("Evicted"), not the kernel's OOM killer ("OOMKilled").
# Prints what happened to each pod and the node's events, then deletes the namespace.
set -euo pipefail

readonly GROWER=${1:-batch}
[[ $GROWER == batch || $GROWER == agent ]] || { echo "usage: $0 [batch|agent]" >&2; exit 64; }

readonly NS=verify-eviction
readonly IMAGE=registry.homelab.lan/agent:2026-11-24.1   # any image with python3
# hold <initial MiB> <step MiB> <seconds between steps>: allocate and touch memory, then keep it.
readonly HOLD_SCRIPT='
import sys, time
initial, step, interval = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
blocks = [bytearray(b"\x01") * (initial << 20)]
print(f"holding {initial} MiB", flush=True)
while step:
    time.sleep(interval)
    blocks.append(bytearray(b"\x01") * (step << 20))
    print(f"holding {initial + step * (len(blocks) - 1)} MiB", flush=True)
time.sleep(10**9)
'

# pod <name> <priority class> <requests memory> <limits memory or ""> <initial MiB> <step MiB>
pod() {
  local limits="{cpu: 500m}"
  [[ -n $4 ]] && limits="{cpu: 500m, memory: $4}"
  [[ $2 == live-critical ]] && limits="{cpu: 100m, memory: $3}"   # Guaranteed: limits = requests
  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1}
spec:
  restartPolicy: Never
  priorityClassName: $2
  nodeSelector: {kubernetes.io/hostname: bc250-1}
  terminationGracePeriodSeconds: 1
  containers:
    - name: hold
      image: $IMAGE
      command: [python3, /hold/hold.py, "$5", "$6", "2"]
      resources:
        requests: {cpu: 100m, memory: $3}
        limits: $limits
      volumeMounts: [{name: hold, mountPath: /hold}]
  volumes: [{name: hold, configMap: {name: hold}}]
EOF
}

# After a run the node keeps its memory-pressure taint for the kubelet's pressure transition
# period (5 minutes), and new pods wait in Pending until it goes.
echo "Waiting for bc250-1 to be free of memory pressure"
until [[ $(kubectl get node bc250-1 -o jsonpath='{.spec.taints[*].key}') != *memory-pressure* ]]; do
  sleep 10
done
while kubectl get namespace "$NS" >/dev/null 2>&1; do sleep 5; done   # a previous run's, deleting

kubectl create namespace "$NS" >/dev/null
trap 'kubectl delete namespace "$NS" --wait=false >/dev/null' EXIT
kubectl -n "$NS" create configmap hold --from-literal=hold.py="$HOLD_SCRIPT" >/dev/null

pod live-bot live-critical 256Mi "" 200 0
pod service service 256Mi 1Gi 700 0
if [[ $GROWER == batch ]]; then
  pod agent agent 256Mi 3Gi 2048 0
  kubectl -n "$NS" wait --for=condition=Ready pod --all --timeout=180s >/dev/null
  echo "live-bot, service and agent are holding their memory; starting batch, which grows"
  pod batch batch 256Mi "" 1024 128
else
  pod batch batch 256Mi "" 1024 0
  kubectl -n "$NS" wait --for=condition=Ready pod --all --timeout=180s >/dev/null
  echo "live-bot, service and batch are holding their memory; starting agent, which grows"
  pod agent agent 256Mi "" 2048 128
fi

# Wait until the grower stops running (evicted or OOM-killed), at most 10 minutes.
for _ in $(seq 1 120); do
  phase=$(kubectl -n "$NS" get pod "$GROWER" -o jsonpath='{.status.phase}')
  [[ $phase == Failed || $phase == Succeeded ]] && break
  sleep 5
done
sleep 20   # give the kubelet time to act on anything else

echo
kubectl -n "$NS" get pods -o custom-columns='POD:.metadata.name,PRIORITY:.spec.priority,QOS:.status.qosClass,PHASE:.status.phase,REASON:.status.reason,LAST:.status.containerStatuses[0].state.terminated.reason,RESTARTS:.status.containerStatuses[0].restartCount'
echo
kubectl -n "$NS" get events --sort-by=.lastTimestamp -o custom-columns='TIME:.lastTimestamp,REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message' |
  grep -E 'Evicted|OOM|Killing|Pressure' || echo "(no eviction or OOM events in $NS)"
kubectl get events -A --field-selector involvedObject.kind=Node,involvedObject.name=bc250-1 \
  --sort-by=.lastTimestamp -o custom-columns='TIME:.lastTimestamp,REASON:.reason,MESSAGE:.message' | tail -5
