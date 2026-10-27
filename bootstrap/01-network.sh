#!/usr/bin/env bash
# Phase 1: make the USB 2.5 GbE adapter the cluster network on this BC-250 node.
#
#   scp bootstrap/01-network.sh bc250-N:/tmp/ && ssh bc250-N sudo bash /tmp/01-network.sh
#   then reboot the node; the rename and the NIC settings take effect at boot.
#
# Safe to re-run: every file is rewritten with the same content.
#
# What it sets up:
#   lan0          stable name for the USB adapter (systemd .link matched on its MAC)
#   cluster-lan   NetworkManager profile for lan0 (DHCP; the router reserves the address).
#                 Boot waits up to 30 s for the USB adapter, so network-online.target
#                 (and k3s after it) never starts before the adapter has an address.
#   autosuspend   kept off for the adapter, so USB power saving can't drop the link
#   RPS           the adapter's receive processing spread over every CPU. Its interrupts all land
#                 on one core; without this that core saturates near 450 Mbit/s of many small
#                 flows (Phase 8: website load from bc250-3 went 50 -> 91 MB/s, page median
#                 730 -> 8 ms)
#   onboard GbE   left unmanaged by NetworkManager, so it stays down
#   /etc/hosts    the three boards, so cluster name lookups don't depend on the router
#
# Safety net: if the cluster-lan profile ever fails, NetworkManager still creates its
# automatic DHCP profile for lan0, so the board stays reachable over SSH.
set -euo pipefail

readonly CLUSTER_IFACE=lan0
readonly NM_PROFILE=cluster-lan
readonly USB_NIC_DRIVER=r8152        # Realtek RTL8156 USB 2.5 GbE
readonly ONBOARD_NIC_DRIVER=r8169    # the board's own gigabit port
readonly BOARD_HOSTS="192.168.1.145 bc250-1
192.168.1.106 bc250-2
192.168.1.172 bc250-3"

step() { printf '\n==> %s\n' "$*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
  fi
}

# Prints the MAC of the single interface bound to a driver; fails if there isn't exactly one.
mac_of_driver() {
  local driver=$1 found=() path
  for path in /sys/class/net/*; do
    [[ -e $path/device/driver ]] || continue
    [[ $(basename "$(readlink -f "$path/device/driver")") == "$driver" ]] && found+=("$path")
  done
  if (( ${#found[@]} != 1 )); then
    echo "Expected exactly one $driver interface, found ${#found[@]}" >&2
    exit 1
  fi
  cat "${found[0]}/address"
}

write_link_file() {
  local usb_mac=$1
  cat > /etc/systemd/network/10-$CLUSTER_IFACE.link <<EOF
# Written by homelab bootstrap/01-network.sh: stable name for the USB 2.5 GbE adapter.
[Match]
MACAddress=$usb_mac

[Link]
Name=$CLUSTER_IFACE
EOF
}

# udev rules here set attributes with ATTR{...}="value", which udev writes on the device itself.
# A RUN+= command that builds /sys/class/net/%k/... fails when the adapter is plugged in: %k is
# still the kernel's name (eth0) while the interface has already been renamed lan0.

write_autosuspend_rule() {
  # Matches the USB device itself (Realtek RTL8156, 0bda:8156; its serial number is the same on
  # every adapter, so it can't single one out). "on" means it is never autosuspended.
  cat > /etc/udev/rules.d/70-$CLUSTER_IFACE-no-autosuspend.rules <<EOF
# Written by homelab bootstrap/01-network.sh: never autosuspend the USB 2.5 GbE adapter.
ACTION=="add|change", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="0bda", ATTR{idProduct}=="8156", ATTR{power/control}="on"
EOF
}

write_rps_rule() {
  local usb_mac=$1
  # Bit mask of every CPU, e.g. fff for 12. The adapter has a single receive queue (rx-0).
  local all_cpus
  all_cpus=$(printf '%x' $(( (1 << $(nproc)) - 1 )))
  cat > /etc/udev/rules.d/71-$CLUSTER_IFACE-rps.rules <<EOF
# Written by homelab bootstrap/01-network.sh: spread the USB 2.5 GbE adapter's receive processing
# over all CPUs (RPS); its interrupts all arrive on one core.
ACTION=="add|change", SUBSYSTEM=="net", ATTR{address}=="$usb_mac", ATTR{queues/rx-0/rps_cpus}="$all_cpus"
EOF
}

write_networkmanager_config() {
  local usb_mac=$1 onboard_mac=$2
  cat > /etc/NetworkManager/conf.d/90-homelab.conf <<EOF
# Written by homelab bootstrap/01-network.sh: the onboard gigabit port is disabled
# (decided 2026-10-27); NetworkManager leaves it down.
[keyfile]
unmanaged-devices=mac:$onboard_mac
EOF

  # Derived from the MAC so a re-run rewrites the same profile instead of adding a new one.
  local uuid hash
  hash=$(printf '%s' "$NM_PROFILE-$usb_mac" | md5sum | cut -c1-32)
  uuid="${hash:0:8}-${hash:8:4}-${hash:12:4}-${hash:16:4}-${hash:20:12}"

  local profile=/etc/NetworkManager/system-connections/$NM_PROFILE.nmconnection
  cat > "$profile" <<EOF
# Written by homelab bootstrap/01-network.sh
[connection]
id=$NM_PROFILE
uuid=$uuid
type=ethernet
autoconnect=true
autoconnect-priority=100
# Hold boot (NetworkManager-wait-online) until the USB adapter shows up.
wait-device-timeout=30000

[ethernet]
mac-address=$usb_mac

[ipv4]
method=auto

[ipv6]
method=auto
addr-gen-mode=default
EOF
  chmod 0600 "$profile"
  nmcli connection reload
}

write_hosts_block() {
  local begin="# BEGIN homelab boards" end="# END homelab boards"
  sed -i "/^$begin\$/,/^$end\$/d" /etc/hosts
  printf '%s\n%s\n%s\n' "$begin" "$BOARD_HOSTS" "$end" >> /etc/hosts
}

require_root
usb_mac=$(mac_of_driver "$USB_NIC_DRIVER")
onboard_mac=$(mac_of_driver "$ONBOARD_NIC_DRIVER")
echo "USB adapter $usb_mac -> $CLUSTER_IFACE; onboard port $onboard_mac -> disabled"

step "Naming the USB adapter $CLUSTER_IFACE"
write_link_file "$usb_mac"

step "Keeping USB autosuspend off for the adapter"
write_autosuspend_rule

step "Spreading the adapter's receive processing over all CPUs (RPS)"
write_rps_rule "$usb_mac"
udevadm control --reload

step "NetworkManager: $NM_PROFILE profile, onboard port unmanaged"
write_networkmanager_config "$usb_mac" "$onboard_mac"

step "Making network-online.target wait for NetworkManager"
systemctl enable NetworkManager-wait-online.service

step "Board names in /etc/hosts"
write_hosts_block

step "Checks before reboot"
udevadm test-builtin net_setup_link "/sys/class/net/$(basename "$(dirname "$(grep -l "$usb_mac" /sys/class/net/*/address)")")" 2>&1 \
  | grep -E 'Config file|ID_NET_NAME=' || true
nmcli -f NAME,TYPE,AUTOCONNECT,AUTOCONNECT-PRIORITY connection show | grep -E "NAME|$NM_PROFILE"
grep -A4 'BEGIN homelab' /etc/hosts

step "Done. Reboot to apply the new name: sudo systemctl reboot"
