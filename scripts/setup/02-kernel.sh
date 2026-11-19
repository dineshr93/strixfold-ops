#!/bin/bash
# 02-kernel.sh — GRUB line for 124 GiB GTT + IOMMU passthrough, on both boxes. Reboot to apply.
# The RUNNING cmdline is authoritative (grub.cfg may have been rebuilt since boot).
cd "$(dirname "$0")" && source ./common.sh
WANT='amdgpu.gttsize=126976 ttm.pages_limit=32505856 amd_iommu=pt'
check_host() { # $1=label $2=cmdline $3=grubline $4=gtt-bytes
  local label=$1 cmd=$2 grub=$3 gtt=$4
  if ! grep -q amd_iommu=pt <<<"$cmd"; then
    gap "$label: running cmdline lacks amd_iommu=pt (the USB4 XDomain link needs it; off will not work)"
    act "$label: set in /etc/default/grub: GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash $WANT\" — then sudo update-grub && sudo reboot (ask the user first)"
  fi
  if [ "${gtt:-0}" -ge 131000000000 ]; then
    ok "$label: GTT $((gtt/1073741824)) GiB + iommu ok"
  else
    gap "$label: GTT ${gtt:-0} — expected ~122–124 GiB"
    act "$label: set in /etc/default/grub (keep any other options the box needs):"
    act "  GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash $WANT\""
    act "  then: sudo update-grub && sudo reboot   # ask the user first"
    act "$label: kho/noretry/lockup_timeout extras are not needed"
  fi
}
info "node1"
GTT=$(cat /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -1)
check_host node1 "$(cat /proc/cmdline)" "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub 2>/dev/null)" "$GTT"
if on0 true 2>/dev/null; then
  info "node0"
  R=$(on0 'cat /proc/cmdline; echo ---; grep "^GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub 2>/dev/null; echo ---; cat /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -1')
  check_host node0 "$(sed -n 1p <<<"$R")" "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT' <<<"$R")" "$(tail -1 <<<"$R")"
else
  gap "node0 unreachable — run its check once ssh works (phase 03)"
fi
info "sleep targets (long input prep must not be interrupted)"
systemctl is-enabled sleep.target 2>/dev/null | grep -q masked && ok "node1 sleep masked" || act "node1: sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target"
finish