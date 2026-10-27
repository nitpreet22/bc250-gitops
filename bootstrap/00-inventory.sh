#!/usr/bin/env bash
# Phase 0 read-only inventory of one BC-250 node. Needs no root and changes nothing,
# so it is safe to re-run at any time.
#
#   scp bootstrap/00-inventory.sh bc250-N:/tmp/ && ssh bc250-N bash /tmp/00-inventory.sh
#
# Sections are printed as "=== name" so the output of all three boards can be compared.
set -uo pipefail

section() { printf '\n=== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

section "host"
hostname
. /etc/os-release && echo "$PRETTY_NAME"
uname -r
uptime

section "memory"
free -h
grep -E 'MemTotal|SwapTotal' /proc/meminfo
# The BIOS carve-out shows up as VRAM; model/GPU memory beyond it comes from GTT (shared RAM).
for card in /sys/class/drm/card[0-9]/device; do
  [ -r "$card/mem_info_vram_total" ] || continue
  vram=$(cat "$card/mem_info_vram_total"); gtt=$(cat "$card/mem_info_gtt_total")
  echo "$card: VRAM carve-out $((vram / 1024 / 1024)) MiB, GTT $((gtt / 1024 / 1024)) MiB"
done
tr ' ' '\n' </proc/cmdline | grep -E '^(ttm|amdgpu|usbcore|drm|video)' || echo "(no ttm/amdgpu/usbcore kernel args)"

section "vulkan"
if have vulkaninfo; then vulkaninfo --summary 2>/dev/null | sed -n '/^Devices:/,$p'; else echo "vulkaninfo not installed"; fi

section "disk"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL
df -hT -x tmpfs -x devtmpfs -x efivarfs

section "security and services"
echo "SELinux: $(getenforce 2>/dev/null || echo unknown)"
echo "firewalld: $(systemctl is-active firewalld)"
for unit in sshd chronyd bc250-cpu-limits cyan-skillfish-governor-smu homelab-agent tailscaled k3s k3s-agent podman.socket sddm; do
  printf '  %-30s %s / %s\n' "$unit" "$(systemctl is-enabled "$unit" 2>/dev/null || echo -)" "$(systemctl is-active "$unit" 2>/dev/null)"
done

section "time"
timedatectl show -p Timezone -p NTPSynchronized -p NTP
have chronyc && chronyc -n tracking 2>/dev/null | grep -E 'Reference|System time|Leap'

section "board limits (from 06_bc250_server)"
cat /etc/bc250-cpu-limits.conf 2>/dev/null || echo "no /etc/bc250-cpu-limits.conf"
grep -A3 '^\[frequency-range\]' /etc/cyan-skillfish-governor-smu/config.toml 2>/dev/null || echo "no GPU governor config"

section "temperatures (idle)"
have sensors && sensors 2>/dev/null | grep -E '^[a-z0-9_-]+-[a-z]+-[0-9a-f]+$|Tctl|edge|temp|fan|PPT|power' || echo "sensors not installed"

section "network interfaces"
ip -br link
ip -br addr
ip route show default
for path in /sys/class/net/*; do
  iface=${path##*/}
  [ "$iface" = lo ] && continue
  [ -e "$path/device" ] || continue          # skip virtual interfaces
  driver=$(basename "$(readlink -f "$path/device/driver")")
  bus=$(basename "$(readlink -f "$path/device/subsystem")")
  speed=$(cat "$path/speed" 2>/dev/null || echo "?")
  echo "$iface: bus=$bus driver=$driver mac=$(cat "$path/address") state=$(cat "$path/operstate") speed=${speed}Mb/s"
  if [ "$bus" = usb ]; then
    usbdev=$(readlink -f "$path/device/..")
    echo "  usb: $(cat "$usbdev/idVendor"):$(cat "$usbdev/idProduct") $(cat "$usbdev/manufacturer" 2>/dev/null) $(cat "$usbdev/product" 2>/dev/null)"
    echo "  usb link speed: $(cat "$usbdev/speed")Mb/s  autosuspend control: $(cat "$usbdev/power/control")"
  fi
done
have ethtool && echo "ethtool present" || echo "ethtool not installed"
echo "usbcore.autosuspend: $(cat /sys/module/usbcore/parameters/autosuspend)"

section "NIC kernel messages (errors, resets, link changes)"
journalctl -k -b --no-pager 2>/dev/null | grep -iE 'r815|r8152|cdc_ncm|ax88|link (up|down)|reset|usb disconnect|tx timeout' | tail -n 40 \
  || echo "cannot read the kernel journal without root"

section "name resolution and reachability"
for peer in bc250-1 bc250-2 bc250-3; do
  printf '%-8s %-18s ' "$peer" "$(getent hosts "$peer" | awk '{print $1}' | head -1)"
  ping -c1 -W1 "$peer" >/dev/null 2>&1 && echo reachable || echo "NOT reachable by name"
done

section "installed tools"
for tool in iperf3 stress-ng podman buildah k3s kubectl tailscale herdr sunshine git; do
  printf '  %-10s %s\n' "$tool" "$(command -v "$tool" || echo missing)"
done
rpm -q k3s-selinux container-selinux 2>/dev/null
