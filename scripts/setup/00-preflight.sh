#!/bin/bash
# 00-preflight.sh — read-only audit of BOTH boxes; prints a gap list. Run first, and after each phase.
cd "$(dirname "$0")" && source ./common.sh
info "node1 ($(hostname))"
grep -q 'Ubuntu 26' /etc/os-release && ok "OS: $(. /etc/os-release; echo $PRETTY_NAME)" || gap "OS is not Ubuntu 26.x: $(. /etc/os-release; echo $PRETTY_NAME) (this guide targets 26.10; the rex stack uses GETTING-STARTED instead)"
ok "kernel: $(uname -r)"
BIOS=$(cat /sys/class/dmi/id/bios_version 2>/dev/null); BIOS=${BIOS#0}
case "$BIOS" in 3.06|3.0[7-9]|3.[1-9]*) ok "BIOS $BIOS";; *) gap "BIOS ${BIOS:-unknown} — needs >= 3.06 (phase 01)";; esac
grep -q amd_iommu=pt /proc/cmdline && ok "cmdline: amd_iommu=pt" || gap "cmdline lacks amd_iommu=pt (phase 02)"
GTT=$(cat /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -1)
[ "${GTT:-0}" -ge 131000000000 ] && ok "GTT $((GTT/1073741824)) GiB" || gap "GTT ${GTT:-0} — expected ~122–124 GiB (phase 02 + reboot)"
for i in 0 1; do
  ip -br addr show "thunderbolt$i" 2>/dev/null | grep -q UP && ok "thunderbolt$i: $(ip -br addr show thunderbolt$i | awk '{print $3}')" || gap "thunderbolt$i missing/down (phases 01–03; rear ports only)"
done
ping -c1 -W2 10.40.0.1 >/dev/null 2>&1 && ok "ping 10.40.0.1 (node0 cable A)" || gap "no ping to 10.40.0.1 (phase 03; crossed cables?)"
ping -c1 -W2 10.40.1.1 >/dev/null 2>&1 && ok "ping 10.40.1.1 (node0 cable B)" || gap "no ping to 10.40.1.1 (phase 03)"
on0 true 2>/dev/null && ok "ssh $NODE0 (passwordless)" || gap "ssh alias $NODE0 not working (phase 03)"
have rocminfo && rocminfo 2>/dev/null | grep -q gfx1151 && ok "rocminfo sees gfx1151" || gap "ROCm missing or no gfx1151 (phase 04)"
ldconfig -p 2>/dev/null | grep -q libamdhip64.so.7 && ok "libamdhip64 in loader cache" || gap "libamdhip64 not registered (phase 04: ldconfig)"
id -nG | grep -qE '\brender\b' && ok "user in render group" || gap "user not in render group (phase 03; re-login after)"
have python3.13 && ok "python3.13: $(python3.13 --version 2>&1)" || gap "python3.13 missing (phase 05)"
[ -x "$HOME/opt/zig/zig" ] && ok "zig: $($HOME/opt/zig/zig version)" || gap "zig 0.17.0 missing at ~/opt/zig (phase 05)"
[ -d "$SRC/.git" ] && ok "source: $SRC ($(git -C "$SRC" rev-parse --short HEAD))" || gap "source not cloned (phase 05)"
[ -x "$HOME/venvs/tfp-inputs/bin/python" ] && ok "venv tfp-inputs" || gap "venv tfp-inputs missing (phase 05)"
[ -x "$HOME/venvs/triton/bin/python" ] && ok "venv triton" || gap "venv triton missing (phase 05)"
[ -f "$HOME/tfp/tri/kit/gfx1151/aot.json" ] && ok "Triton kit: $(find "$HOME/tfp/tri/kit/gfx1151/hsaco" -type f 2>/dev/null | wc -l) hsaco files" || gap "Triton kit not built (phase 06)"
[ -x "$DEPLOY/native-hip/bin/tensorfold-native" ] && ok "deploy: $(readlink "$DEPLOY")" || gap "no deployment (phase 08)"
[ -d "$BUNDLE/model" ] && ok "bundle: $BUNDLE" || gap "inputs bundle missing (phase 08)"
ls "$BUNDLE".verify-rank1-*.json >/dev/null 2>&1 && ok "verify report rank1" || gap "rank1 verify report missing (phase 08)"
[ -f "$TFP/run/conf/my.conf" ] && ok "conf: my.conf" || gap "serving conf missing (phase 09)"
AVAIL=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)
ok "MemAvailable: ${AVAIL} GiB"
DISK=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
ok "free disk (\$HOME): ${DISK} GiB"
if curl -fsS -m 3 http://10.40.0.1:18080/health >/dev/null 2>&1 || curl -fsS -m 3 http://10.40.0.1:8888/health >/dev/null 2>&1; then
  ok "serve: /health answers"
else
  gap "serve: not answering (phase 09, or stopped)"
fi
if on0 true 2>/dev/null; then
  info "node0 ($NODE0)"
  on0 '
    BIOS=$(cat /sys/class/dmi/id/bios_version 2>/dev/null); BIOS=${BIOS#0}
    case "$BIOS" in 3.06|3.0[7-9]|3.[1-9]*) echo "  [ok]   BIOS $BIOS";; *) echo "  [GAP]  BIOS $BIOS — needs >= 3.06 (phase 01)";; esac
    grep -q amd_iommu=pt /proc/cmdline && echo "  [ok]   cmdline: amd_iommu=pt" || echo "  [GAP]  cmdline lacks amd_iommu=pt (phase 02)"
    GTT=$(cat /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -1)
    [ "${GTT:-0}" -ge 131000000000 ] && echo "  [ok]   GTT $((GTT/1073741824)) GiB" || echo "  [GAP]  GTT ${GTT:-0} (phase 02 + reboot)"
    for i in 0 1; do ip -br addr show thunderbolt$i 2>/dev/null | grep -q UP && echo "  [ok]   thunderbolt$i up" || echo "  [GAP]  thunderbolt$i missing/down"; done
    command -v rocminfo >/dev/null && rocminfo 2>/dev/null | grep -q gfx1151 && echo "  [ok]   rocminfo gfx1151" || echo "  [GAP]  ROCm/gfx1151 (phase 04)"
    ldconfig -p 2>/dev/null | grep -q libamdhip64.so.7 && echo "  [ok]   libamdhip64 registered" || echo "  [GAP]  ldconfig registration (phase 04)"
    [ -x "$HOME/venvs/tfp-inputs/bin/python" ] && echo "  [ok]   venv tfp-inputs" || echo "  [GAP]  venv tfp-inputs (phase 05)"
    [ -x "$HOME/tfp/deploy/current/native-hip/bin/tensorfold-native" ] && echo "  [ok]   deploy: $(readlink $HOME/tfp/deploy/current)" || echo "  [GAP]  no deployment (phase 08)"
    B=$HOME/models/tf-port/inputs-tp2-c178a012
    if [ -f $HOME/tfp/run/conf/my.conf ]; then CB=$(sed -n "s/^BUNDLE=\x27\(.*\)\x27.*/\1/p" $HOME/tfp/run/conf/my.conf); [ -n "$CB" ] && B=$(eval echo "$CB"); fi
    [ -d "$B/model" ] && echo "  [ok]   bundle: $B" || echo "  [GAP]  bundle missing (phase 08)"
    ls "$B".verify-rank0-*.json >/dev/null 2>&1 && echo "  [ok]   verify report rank0" || echo "  [GAP]  rank0 verify report (phase 08)"
    [ -f "$HOME/tfp/run/conf/my.conf" ] && echo "  [ok]   conf: my.conf" || echo "  [GAP]  serving conf (phase 09)"
    echo "  [ok]   MemAvailable: $(awk "/MemAvailable/{print int(\$2/1048576)}" /proc/meminfo) GiB"
    podman ps --format "{{.Names}}" 2>/dev/null | grep -q halogen-flash-server && echo "  [GAP]  halogen-flash-server running — stop before serving (make halogen-stop)"
    exit 0
  ' || gap "node0 audit failed"
else
  gap "node0 unreachable — its audit runs once ssh works (phase 03)"
fi
echo
[ "$GAPS" -gt 0 ] && { echo "$GAPS gap(s) — work the phases in order (AGENTS.md)"; exit 1; }
echo "preflight clean"