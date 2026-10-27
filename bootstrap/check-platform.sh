#!/usr/bin/env bash
# Phase 3 platform checks from the PC: the GPU device plugin and queue, and the network policies.
# Creates throwaway pods with a "platform-check" label and removes them at the end. Safe to re-run.
#
#   bootstrap/check-platform.sh
set -uo pipefail

readonly KUBECTL=(kubectl --context homelab)
readonly CHECK_LABEL=homelab.lan/check=platform
failures=0

pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; failures=$((failures + 1)); }

cleanup() {
  local ns
  for ns in games ml ops; do
    "${KUBECTL[@]}" -n "$ns" delete pod -l "$CHECK_LABEL" --ignore-not-found --wait=false >/dev/null 2>&1
  done
}
trap cleanup EXIT

# run_pod <namespace> <name> <tier> <image> <command> [extra spec yaml, indented 2] [extra limits]
# Limits are small (500m CPU, POD_MEMORY_LIMIT or 128Mi) so a probe fits in the fullest quota (ops).
run_pod() {
  local ns=$1 name=$2 tier=$3 image=$4 command=$5 extra=${6:-} extra_limits=${7:-}
  "${KUBECTL[@]}" -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels: {homelab.lan/check: platform, homelab.lan/tier: $tier}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
$extra
  containers:
    - name: main
      image: $image
      command: [sh, -c, "$command"]
      resources:
        requests: {cpu: 50m, memory: 64Mi}
        limits: {cpu: 500m, memory: ${POD_MEMORY_LIMIT:-128Mi}${extra_limits}}
EOF
}

readonly GPU_SPEC="  priorityClassName: batch
  nodeSelector: {kubernetes.io/hostname: bc250-2}"   # both pods on one board, the always-on one
readonly GPU_LIMIT=", devic.es/gpu: 1"   # appended to the container's limits

echo "GPU device plugin and queue (bc250-2)"
# Holder: installs Vulkan tools, prints the device, then keeps the GPU for a while.
POD_MEMORY_LIMIT=768Mi run_pod games gpu-holder dev fedora:44 \
  "dnf -q -y install vulkan-tools mesa-vulkan-drivers >/dev/null 2>&1; vulkaninfo --summary 2>/dev/null | grep -m1 deviceName; ls /dev/dri; sleep 120" \
  "$GPU_SPEC" "$GPU_LIMIT"
"${KUBECTL[@]}" -n games wait --for=condition=Ready pod/gpu-holder --timeout=180s >/dev/null || fail "gpu-holder never started"
# Waiter in another namespace asks for the same single GPU: it must stay Pending.
run_pod ml gpu-waiter dev busybox:1.37.0 "ls /dev/dri" "$GPU_SPEC" "$GPU_LIMIT"
sleep 10
waiter_phase=$("${KUBECTL[@]}" -n ml get pod gpu-waiter -o jsonpath='{.status.phase}')
[[ $waiter_phase == Pending ]] && pass "second GPU pod waits (Pending) while the first holds the GPU" \
  || fail "second GPU pod is $waiter_phase, expected Pending"

for _ in $(seq 1 36); do
  "${KUBECTL[@]}" -n games logs gpu-holder 2>/dev/null | grep -q deviceName && break
  sleep 5
done
device=$("${KUBECTL[@]}" -n games logs gpu-holder 2>/dev/null | grep -m1 deviceName)
[[ $device == *BC-250* ]] && pass "GPU pod sees the GPU through Vulkan: ${device//[[:space:]]/ }" \
  || fail "GPU pod didn't report the BC-250 (got: ${device:-nothing}; logs: $("${KUBECTL[@]}" -n games logs gpu-holder 2>&1 | tail -2))"

"${KUBECTL[@]}" -n games delete pod gpu-holder --wait=true >/dev/null
"${KUBECTL[@]}" -n ml wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-waiter --timeout=120s >/dev/null \
  && pass "queued GPU pod ran once the GPU was released" || fail "queued GPU pod didn't run after release"

echo
echo "Network policies"
run_pod ops service-pod service busybox:1.37.0 "httpd -f -p 8080 -h /etc"
run_pod ml dev-pod dev curlimages/curl:8.11.1 "sleep 300"
for target in "ops pod/service-pod" "ml pod/dev-pod"; do
  "${KUBECTL[@]}" -n ${target% *} wait --for=condition=Ready ${target#* } --timeout=120s >/dev/null
done
service_ip=$("${KUBECTL[@]}" -n ops get pod service-pod -o jsonpath='{.status.podIP}')

# reach <namespace> <pod> <url>: exit 0 if an HTTP response came back within 5 s
reach() { "${KUBECTL[@]}" -n "$1" exec "$2" -- curl -s -o /dev/null -m 5 "$3"; }

reach ml dev-pod https://www.cloudflare.com && pass "dev pod reaches the internet" \
  || fail "dev pod can't reach the internet"
reach ml dev-pod http://forgejo-http.forgejo.svc:3000/ && pass "dev pod reaches Forgejo" \
  || fail "dev pod can't reach Forgejo"
reach ml dev-pod "http://$service_ip:8080/hostname" && fail "dev pod REACHED a service in another namespace" \
  || pass "dev pod is blocked from other services in the cluster"
reach ml dev-pod http://192.168.1.1/ && fail "dev pod REACHED the router (LAN)" \
  || pass "dev pod is blocked from the LAN"

echo
if (( failures > 0 )); then echo "FAILED: $failures check(s)"; exit 1; fi
echo "All platform checks passed"
