#!/bin/bash
# 01-firmware.sh — BIOS >= 3.06 on both boxes (fwupd/LVFS). REBOOTS: confirm with the user first.
cd "$(dirname "$0")" && source ./common.sh
info "BIOS check (both boxes)"
for host in local "$NODE0"; do
  if [ "$host" = local ]; then B=$(cat /sys/class/dmi/id/bios_version 2>/dev/null); where=node1
  else B=$(on0 'cat /sys/class/dmi/id/bios_version' 2>/dev/null); where=node0; fi
  B=${B#0}
  case "$B" in
    3.06|3.0[7-9]|3.[1-9]*) ok "$where BIOS $B";;
    *) gap "$where BIOS ${B:-unknown} — update to >= 3.06"
       act "$where: sudo fwupdmgr refresh --force && sudo fwupdmgr update   # then REBOOT (ask the user first)"
       act "$where: after reboot verify: cat /sys/class/dmi/id/bios_version";;
  esac
done
echo "Note: BIOS 3.06 alone is not enough — phase 02's amd_iommu=pt is also required for the USB4 link."
finish