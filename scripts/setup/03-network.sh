#!/bin/bash
# 03-network.sh — USB4 addresses (netplan on Server, nmcli on Desktop), ssh alias node0, GPU groups.
# Cables must be in the REAR USB-C ports, port-to-matching-port. node0=.1, node1=.2.
cd "$(dirname "$0")" && source ./common.sh
info "link interfaces"
for i in 0 1; do
  ip -br link show "thunderbolt$i" 2>/dev/null | grep -q . && ok "thunderbolt$i present" || gap "thunderbolt$i missing — BIOS 3.06 + iommu=pt (phases 01–02), rear ports, cable; fallback: sudo modprobe thunderbolt_net"
done
info "node1 addresses (10.40.0.2 / 10.40.1.2, MTU 1500, IPv6 off)"
A0=$(ip -br addr show thunderbolt0 2>/dev/null | grep -o '10\.40\.0\.2/24')
A1=$(ip -br addr show thunderbolt1 2>/dev/null | grep -o '10\.40\.1\.2/24')
if [ -n "$A0" ] && [ -n "$A1" ]; then ok "node1 USB4 addresses set"
else
  gap "node1 USB4 addresses missing"
  if have nmcli; then
    act "node1 (Desktop/nmcli):"
    act "  sudo nmcli con add type ethernet ifname thunderbolt0 con-name usb4-a ipv4.method manual ipv4.addresses 10.40.0.2/24 ethernet.mtu 1500 ipv6.method disabled"
    act "  sudo nmcli con add type ethernet ifname thunderbolt1 con-name usb4-b ipv4.method manual ipv4.addresses 10.40.1.2/24 ethernet.mtu 1500 ipv6.method disabled"
    act "  sudo nmcli con up usb4-a; sudo nmcli con up usb4-b"
  else
    act "node1 (Server/netplan): write /etc/netplan/10-usb4.yaml (chmod 600), then sudo netplan apply:"
    cat <<'EOF'
network:
  version: 2
  ethernets:
    thunderbolt0: {dhcp4: false, dhcp6: false, accept-ra: false, addresses: [10.40.0.2/24], mtu: 1500}
    thunderbolt1: {dhcp4: false, dhcp6: false, accept-ra: false, addresses: [10.40.1.2/24], mtu: 1500}
EOF
    act "  (netplan 1.2.2 rejects ipv6-method: disabled — dhcp6/accept-ra false is the way)"
  fi
fi
info "node0 addresses + reachability"
if ping -c1 -W2 10.40.0.1 >/dev/null 2>&1 && ping -c1 -W2 10.40.1.1 >/dev/null 2>&1; then
  ok "both cables ping node0"
else
  gap "node0 not reachable on both cables — configure node0 (.1 addresses, same netplan/nmcli pattern), or swap crossed cables (each box's thunderbolt0 must share a cable)"
fi
info "ssh alias node0 (passwordless, from node1)"
if on0 true 2>/dev/null; then ok "ssh $NODE0 works"
else
  gap "ssh $NODE0 not working"
  [ -f "$HOME/.ssh/id_ed25519.pub" ] || act "ssh-keygen -t ed25519"
  act "ssh-copy-id 10.40.0.1   # needs node0's password once — ask the user"
  grep -q '^Host node0' "$HOME/.ssh/config" 2>/dev/null || act "printf 'Host node0\n    HostName 10.40.0.1\n' >> ~/.ssh/config   # add 'User <name>' if node0's user differs"
fi
info "GPU groups"
id -nG | grep -qE '\brender\b' && ok "node1: render group" || act "node1: sudo usermod -aG render,video $USER   # then re-login"
on0 'id -nG' 2>/dev/null | grep -qE '\brender\b' && ok "node0: render group" || act "node0: sudo usermod -aG render,video \$USER   # then re-login"
finish