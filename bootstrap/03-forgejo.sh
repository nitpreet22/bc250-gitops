#!/usr/bin/env bash
# Phase 2: installs Forgejo (the cluster's git server) on the k3s server, bc250-2.
#
#   scp bootstrap/k3s-manifests/forgejo.yaml bc250-2:/tmp/forgejo.yaml
#   bootstrap/run-detached.sh bc250-2 bootstrap/03-forgejo.sh /tmp/forgejo.yaml
#
# Safe to re-run: the admin secret is created only once, the manifest is replaced, and the
# firewall ports are checked before being added.
#
# The admin password is random, generated here, and goes straight into a Kubernetes Secret.
# It is never printed. To read it yourself:
#   kubectl -n forgejo get secret forgejo-admin -o jsonpath='{.data.password}' | base64 -d
set -euo pipefail

readonly MANIFEST_SOURCE=$1
readonly MANIFEST_TARGET=/var/lib/rancher/k3s/server/manifests/homelab-forgejo.yaml
readonly ADMIN_USER=nitpreet22
readonly NODE_PORTS=(30300/tcp 30022/tcp)   # Forgejo web and SSH, LAN only (the router forwards nothing)
readonly KUBECTL="k3s kubectl"

step() { printf '\n==> %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
[[ -s $MANIFEST_SOURCE ]] || { echo "Missing manifest $MANIFEST_SOURCE" >&2; exit 1; }

step "Namespace and admin secret"
$KUBECTL create namespace forgejo --dry-run=client -o yaml | $KUBECTL apply -f -
if $KUBECTL -n forgejo get secret forgejo-admin >/dev/null 2>&1; then
  echo "forgejo-admin already exists; keeping it"
else
  password=$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-32)
  $KUBECTL -n forgejo create secret generic forgejo-admin \
    --from-literal=username="$ADMIN_USER" --from-literal=password="$password" >/dev/null
  unset password
  echo "Created forgejo-admin for user $ADMIN_USER (password not shown)"
fi

step "Opening Forgejo's NodePorts to the LAN"
default_zone=$(firewall-cmd --get-default-zone)
for port in "${NODE_PORTS[@]}"; do
  firewall-cmd --permanent --zone="$default_zone" --query-port="$port" >/dev/null ||
    firewall-cmd --permanent --zone="$default_zone" --add-port="$port" >/dev/null
done
firewall-cmd --reload >/dev/null
firewall-cmd --zone="$default_zone" --list-ports

step "Installing the HelmChart manifest (k3s applies it)"
install -m 0600 "$MANIFEST_SOURCE" "$MANIFEST_TARGET"

step "Waiting for Forgejo to be ready (first start pulls images)"
for _ in $(seq 1 60); do
  $KUBECTL -n forgejo get deploy forgejo >/dev/null 2>&1 && break
  sleep 5
done
$KUBECTL -n forgejo rollout status deploy/forgejo --timeout=600s
$KUBECTL -n forgejo get pods,svc,pvc -o wide
