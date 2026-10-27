#!/usr/bin/env bash
# Smoke test from the PC: one pod pinned to each Ready node, then pod-to-pod traffic across nodes,
# cluster DNS, and flannel's chosen interface. Cleans up after itself. Safe to re-run.
#
#   bootstrap/check-cluster.sh
#
# Uses the "homelab" kubectl context and a throwaway namespace, homelab-smoke.
set -euo pipefail

readonly KUBECTL=(kubectl --context homelab)
readonly NAMESPACE=homelab-smoke
readonly IMAGE=busybox:1.37.0

cleanup() { "${KUBECTL[@]}" delete namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null; }
trap cleanup EXIT

# The boards that are up: bc250-1 and bc250-3 are powered off when nothing needs them (README,
# "Node power"), so a board that isn't Ready is reported and skipped rather than waited for.
mapfile -t NODES < <("${KUBECTL[@]}" get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
  awk '$2 == "True" {print $1}')
"${KUBECTL[@]}" get nodes --no-headers | awk '$2 !~ /^Ready/ {print "Skipping " $1 " (" $2 ")"}'
(( ${#NODES[@]} > 0 )) || { echo "No Ready nodes" >&2; exit 1; }

"${KUBECTL[@]}" create namespace "$NAMESPACE" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null

for node in "${NODES[@]}"; do
  "${KUBECTL[@]}" apply -n "$NAMESPACE" -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: smoke-$node
  labels: {app: smoke}
spec:
  nodeSelector: {kubernetes.io/hostname: $node}
  containers:
    - name: smoke
      image: $IMAGE
      command: [sh, -c, "httpd -f -p 8080 -h /etc"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 32Mi}
EOF
done
"${KUBECTL[@]}" wait -n "$NAMESPACE" --for=condition=Ready pod -l app=smoke --timeout=120s >/dev/null

echo "Pods (one per node):"
"${KUBECTL[@]}" get pods -n "$NAMESPACE" -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP

echo
echo "Pod-to-pod HTTP across nodes:"
failures=0
for from in "${NODES[@]}"; do
  for to in "${NODES[@]}"; do
    [[ $from == "$to" ]] && continue
    to_ip=$("${KUBECTL[@]}" get pod -n "$NAMESPACE" "smoke-$to" -o jsonpath='{.status.podIP}')
    if "${KUBECTL[@]}" exec -n "$NAMESPACE" "smoke-$from" -- wget -q -T 5 -O /dev/null "http://$to_ip:8080/hostname"; then
      echo "  $from -> $to ok"
    else
      echo "  $from -> $to FAILED"; failures=$((failures + 1))
    fi
  done
done

echo
echo "Cluster DNS from each node:"
for node in "${NODES[@]}"; do
  if "${KUBECTL[@]}" exec -n "$NAMESPACE" "smoke-$node" -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
    echo "  $node ok"
  else
    echo "  $node FAILED"; failures=$((failures + 1))
  fi
done

echo
echo "Flannel public IP per node (must be the lan0 address):"
"${KUBECTL[@]}" get nodes -o custom-columns='NODE:.metadata.name,FLANNEL_IP:.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip,INTERNAL_IP:.status.addresses[0].address'

echo
if (( failures > 0 )); then
  echo "FAILED: $failures check(s)"; exit 1
fi
echo "All checks passed"
