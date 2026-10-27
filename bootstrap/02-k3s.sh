#!/usr/bin/env bash
# Phase 1: installs k3s on this BC-250 node, pinned to the lan0 (USB 2.5 GbE) interface.
#
#   bootstrap/run-detached.sh bc250-2 bootstrap/02-k3s.sh      # server first
#   bootstrap/install-k3s-token.sh bc250-1                      # copies the token, never printed
#   bootstrap/run-detached.sh bc250-1 bootstrap/02-k3s.sh      # then each agent
#
# The node's role (server or agent), label and taint come from its hostname (table below).
# Safe to re-run: config and firewall rules are rewritten or checked, and the installer is
# skipped when the pinned version is already running.
#
# Decisions behind the settings:
#   - bc250-2 is the server and the always-on board (role=brain: what must stay up is pinned to
#     it). bc250-1 and bc250-3 have no role and carry the on-demand taint below; they are powered
#     on only when pods need them (since 2026-11; before that bc250-1 was role=gpu-lab, tainted,
#     and bc250-3 role=public).
#   - k3s applies node-label and node-taint only when a node first registers, so changing them
#     here doesn't change an existing node: use kubectl label / kubectl taint as well.
#   - node-ip + flannel-iface keep all cluster traffic on lan0.
#   - streaming-connection-idle-timeout=0 keeps long kubectl exec sessions (herdr panes) open.
#   - Eviction thresholds (Phase 8): with k3s's default (evict below 100 MiB free) a fast-growing
#     pod met the kernel's OOM killer first, which picks by memory use, not priority. The kubelet
#     polls memory every ~10 s (memcg notifications are off on cgroup v2), so it gets a 1 GiB hard
#     and 1.5 GiB soft (30 s) margin to act first, lowest priority first. Setting eviction-hard
#     replaces the kubelet's whole default map, so the disk thresholds are listed too.
#   - Disk thresholds are absolute (20 GiB free), not the kubelet's default 10 %/15 %: on bc250-3
#     a large data volume shared the root filesystem, so 15 % free (71 GiB) tripped imagefs
#     pressure on 2026-10-31 and evicted every pod there. k3s's own defaults add a 10 % minimum
#     reclaim, which kept the pressure on until 25 % was free, so those services stayed down for
#     two days at 16 % free. The reclaim is 5 GiB here.
#   - singleProcessOOMKill (kubelet drop-in): on cgroup v2 the kernel otherwise kills every
#     process in a container that hits its memory limit, so one big script took Claude Code's
#     session down with it (2026-10-31). With it, only the process the OOM killer picks dies.
set -euo pipefail

readonly K3S_VERSION=v1.36.5+k3s1
readonly INSTALLER_URL="https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION/+/%2B}/install.sh"
readonly SERVER_IP=192.168.1.106
readonly CLUSTER_IFACE=lan0
readonly TOKEN_FILE=/etc/rancher/k3s/cluster-token
readonly CONFIG_FILE=/etc/rancher/k3s/config.yaml
readonly REGISTRIES_FILE=/etc/rancher/k3s/registries.yaml
readonly KUBELET_DROPIN=/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-homelab.conf
readonly INOTIFY_SYSCTL=/etc/sysctl.d/90-homelab-inotify.conf
readonly BOARD_IPS=(192.168.1.145 192.168.1.106 192.168.1.172)
readonly POD_CIDR=10.42.0.0/16        # k3s default cluster-cidr
readonly SERVICE_CIDR=10.43.0.0/16    # k3s default service-cidr
readonly NODES_ZONE=homelab-nodes
# The boards that are powered on only when needed (README, "Node power"). PreferNoSchedule: the
# scheduler uses them only when bc250-2 is full or a pod's volume is on them.
readonly ON_DEMAND_TAINT=homelab.lan/on-demand=true:PreferNoSchedule

step() { printf '\n==> %s\n' "$*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
  fi
}

# Sets ROLE, NODE_LABEL and NODE_TAINT for this host.
read_node_role() {
  case $(hostname) in
    bc250-1) ROLE=agent;  NODE_LABEL=;      NODE_TAINT=$ON_DEMAND_TAINT ;;
    bc250-2) ROLE=server; NODE_LABEL=brain; NODE_TAINT= ;;
    bc250-3) ROLE=agent;  NODE_LABEL=;      NODE_TAINT=$ON_DEMAND_TAINT ;;
    *) echo "Unknown host $(hostname)" >&2; exit 1 ;;
  esac
}

lan0_ipv4() {
  ip -4 -o addr show "$CLUSTER_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1
}

ensure_token() {
  if [[ $ROLE == server && ! -s $TOKEN_FILE ]]; then
    install -d -m 0700 "$(dirname "$TOKEN_FILE")"
    (umask 077; openssl rand -hex 32 > "$TOKEN_FILE")
    echo "Generated a new cluster token in $TOKEN_FILE"
  fi
  if [[ ! -s $TOKEN_FILE ]]; then
    echo "Missing $TOKEN_FILE: run bootstrap/install-k3s-token.sh $(hostname) from the PC first" >&2
    exit 1
  fi
  chmod 0600 "$TOKEN_FILE"
}

write_config() {
  local node_ip=$1
  install -d -m 0755 "$(dirname "$CONFIG_FILE")"
  {
    echo "# Written by homelab bootstrap/02-k3s.sh"
    if [[ $ROLE == server ]]; then
      echo "tls-san:"
      echo "  - $SERVER_IP"
      echo "  - bc250-2"
      echo "  - bc250-2.nbn"
      echo "write-kubeconfig-mode: \"0600\""
      echo "secrets-encryption: true"
    else
      echo "server: https://$SERVER_IP:6443"
    fi
    echo "token-file: $TOKEN_FILE"
    echo "node-ip: $node_ip"
    echo "flannel-iface: $CLUSTER_IFACE"
    echo "kubelet-arg:"
    echo "  - streaming-connection-idle-timeout=0"
    echo "  - eviction-hard=memory.available<1Gi,nodefs.available<20Gi,imagefs.available<20Gi,nodefs.inodesFree<5%,imagefs.inodesFree<5%"
    echo "  - eviction-minimum-reclaim=nodefs.available=5Gi,imagefs.available=5Gi"
    echo "  - eviction-soft=memory.available<1536Mi"
    echo "  - eviction-soft-grace-period=memory.available=30s"
    if [[ -n $NODE_LABEL ]]; then
      echo "node-label:"
      echo "  - role=$NODE_LABEL"
    fi
    if [[ -n $NODE_TAINT ]]; then
      echo "node-taint:"
      echo "  - $NODE_TAINT"
    fi
  } > "$CONFIG_FILE"
  chmod 0644 "$CONFIG_FILE"     # holds the token file's path, not the token; k3s kubectl reads it
  cat "$CONFIG_FILE"
}

# containerd pulls images named registry.homelab.lan/... from the in-cluster registry
# (infrastructure/registry) over plain HTTP on the cluster network. k3s reads this file only at
# start, so a change here also triggers a restart.
write_registries() {
  cat > "$REGISTRIES_FILE" <<EOF
# Written by homelab bootstrap/02-k3s.sh
mirrors:
  registry.homelab.lan:
    endpoint:
      - http://$SERVER_IP:30500
EOF
  chmod 0644 "$REGISTRIES_FILE"
}

# Kubelet settings that have no command-line flag go in a drop-in, which k3s's kubelet merges
# over its own defaults (00-k3s-defaults.conf in the same folder). Read only at start.
write_kubelet_dropin() {
  install -d -m 0700 "$(dirname "$KUBELET_DROPIN")"
  cat > "$KUBELET_DROPIN" <<EOF
# Written by homelab bootstrap/02-k3s.sh
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
singleProcessOOMKill: true
EOF
  chmod 0600 "$KUBELET_DROPIN"
}

# Opens only what the cluster needs (k3s docs: Installation > Requirements > Networking, and the
# firewalld notes): flannel VXLAN, kubelet and node-exporter between the boards, pod/service
# ranges trusted, and the API server on the server node. Traffic from a pod to another board's
# address leaves with its own board's IP, so it lands in the homelab-nodes zone.
configure_firewalld() {
  if ! firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -qx "$NODES_ZONE"; then
    firewall-cmd --permanent --new-zone="$NODES_ZONE" >/dev/null
  fi
  local ip
  for ip in "${BOARD_IPS[@]}"; do
    firewall-cmd --permanent --zone="$NODES_ZONE" --query-source="$ip" >/dev/null ||
      firewall-cmd --permanent --zone="$NODES_ZONE" --add-source="$ip" >/dev/null
  done
  local port
  # 8472 flannel VXLAN, 10250 kubelet, 6443 API server, 9100 node-exporter (scraped by
  # VictoriaMetrics), 30500 the in-cluster image registry (containerd pulls via bc250-2's NodePort),
  # 9877 homelab-agent (13_home_server_dashboard), polled by the hub pod on bc250-2; the agent
  # still requires its bearer token
  for port in 8472/udp 10250/tcp 6443/tcp 9100/tcp 30500/tcp 9877/tcp; do
    firewall-cmd --permanent --zone="$NODES_ZONE" --query-port="$port" >/dev/null ||
      firewall-cmd --permanent --zone="$NODES_ZONE" --add-port="$port" >/dev/null
  done
  # SSH must keep working from the other boards too, since a source match takes the packet
  # out of the default zone.
  firewall-cmd --permanent --zone="$NODES_ZONE" --query-service=ssh >/dev/null ||
    firewall-cmd --permanent --zone="$NODES_ZONE" --add-service=ssh >/dev/null

  local cidr
  for cidr in "$POD_CIDR" "$SERVICE_CIDR"; do
    firewall-cmd --permanent --zone=trusted --query-source="$cidr" >/dev/null ||
      firewall-cmd --permanent --zone=trusted --add-source="$cidr" >/dev/null
  done

  local default_zone
  default_zone=$(firewall-cmd --get-default-zone)
  # Moonlight desktops (templates/desktop): each instance uses a block of 10 ports from 47300 as
  # hostPorts. LAN only: the router forwards nothing here.
  local proto
  for proto in tcp udp; do
    firewall-cmd --permanent --zone="$default_zone" --query-port="47300-47399/$proto" >/dev/null ||
      firewall-cmd --permanent --zone="$default_zone" --add-port="47300-47399/$proto" >/dev/null
  done

  if [[ $ROLE == server ]]; then
    # kubectl from the PC (LAN). Every request still needs a client certificate.
    firewall-cmd --permanent --zone="$default_zone" --query-port=6443/tcp >/dev/null ||
      firewall-cmd --permanent --zone="$default_zone" --add-port=6443/tcp >/dev/null
  fi
  firewall-cmd --reload >/dev/null
  firewall-cmd --zone="$NODES_ZONE" --list-all
}

# Raises the per-user inotify limits. Every container's shim, k3s itself and each Tailscale proxy
# (all running as root) take an inotify instance, and Fedora's default is 128 per user. After
# the 2026-11-20 consolidation put everything always-on on bc250-2, root there held all 128,
# so following pod logs failed with "failed to create fsnotify watcher: too many open files".
write_inotify_sysctl() {
  cat >"$INOTIFY_SYSCTL" <<'EOF'
# bootstrap/02-k3s.sh: room for many containers per board (Fedora's default is 128 instances)
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF
  sysctl -q -p "$INOTIFY_SYSCTL"
  sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
}

installed_version_matches() {
  command -v k3s >/dev/null && k3s --version | grep -qF "$K3S_VERSION" &&
    systemctl is-active --quiet "$(service_name)"
}

service_name() { [[ $ROLE == server ]] && echo k3s || echo k3s-agent; }

run_installer() {
  local installer
  installer=$(mktemp)
  curl -fsSL "$INSTALLER_URL" -o "$installer"
  # The installer also adds Rancher's rpm repo and installs k3s-selinux (SELinux stays enforcing).
  INSTALL_K3S_VERSION=$K3S_VERSION INSTALL_K3S_EXEC=$ROLE sh "$installer"
  rm -f "$installer"
}

require_root
read_node_role
node_ip=$(lan0_ipv4)
[[ -n $node_ip ]] || { echo "$CLUSTER_IFACE has no IPv4 address" >&2; exit 1; }
echo "$(hostname): $ROLE, role=${NODE_LABEL:-none}, taint=${NODE_TAINT:-none}, node-ip $node_ip, k3s $K3S_VERSION"

step "Cluster token"
ensure_token

step "k3s config ($CONFIG_FILE)"
previous_config=$(cat "$CONFIG_FILE" "$REGISTRIES_FILE" "$KUBELET_DROPIN" 2>/dev/null || true)
write_config "$node_ip"
write_registries
write_kubelet_dropin
config_changed=false
[[ $(cat "$CONFIG_FILE" "$REGISTRIES_FILE" "$KUBELET_DROPIN") == "$previous_config" ]] || config_changed=true

step "inotify limits ($INOTIFY_SYSCTL)"
write_inotify_sysctl

step "firewalld"
configure_firewalld

step "Installing k3s $K3S_VERSION"
if installed_version_matches; then
  if [[ $config_changed == true ]]; then
    echo "Already installed; config changed, restarting $(service_name)."
    systemctl restart "$(service_name)"
  else
    echo "Already installed and running with this config; nothing to do."
  fi
else
  run_installer
fi

step "Checks"
rpm -q k3s-selinux container-selinux
getenforce
systemctl is-active "$(service_name)"
ps -eZ | grep -E ' (k3s-server|k3s-agent|containerd)$' | awk '{print $1, $NF}' | sort -u
