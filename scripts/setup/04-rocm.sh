#!/bin/bash
# 04-rocm.sh — ROCm 10.1 gfx1151-only from AMD's ubuntu2604 stable repo + ldconfig registration, both boxes.
cd "$(dirname "$0")" && source ./common.sh
install_cmds() { # $1 = label
  local L=$1
  act "$L: sudo install -d /etc/apt/keyrings"
  act "$L: curl -fsSL https://stable.repo.amd.com/rocm/gpg/packages.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/amdrocm.gpg"
  act "$L: write /etc/apt/sources.list.d/amdrocm-stable.sources:"
  cat <<'EOF'
Types: deb
URIs: https://stable.repo.amd.com/rocm/core/packages/ubuntu2604/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/amdrocm.gpg
Enabled: yes
EOF
  act "$L: sudo apt update && sudo apt install amdrocm10.1-gfx1151 amdrocm-core-sdk10.1-gfx1151"
  act "$L:   (NOT the plain amdrocm10.1 meta — it pulls every GPU arch, several GB for nothing)"
  act "$L: echo /opt/rocm/lib | sudo tee /etc/ld.so.conf.d/amdrocm.conf && sudo ldconfig"
  act "$L:   (without this: every StrixFold program fails DriverUnavailable at 0.0s while rocminfo works)"
}
check_host() { # $1=label $2=probe-output
  local L=$1 out=$2
  grep -q gfx1151 <<<"$out" && ok "$L: rocminfo sees gfx1151" || { gap "$L: ROCm/gfx1151 missing"; install_cmds "$L"; }
  grep -q libamdhip64 <<<"$out" && ok "$L: libamdhip64 in loader cache" || { gap "$L: /opt/rocm/lib not registered"; act "$L: echo /opt/rocm/lib | sudo tee /etc/ld.so.conf.d/amdrocm.conf && sudo ldconfig"; }
}
info "node1"
check_host node1 "$(rocminfo 2>/dev/null | grep -m1 gfx1151; ldconfig -p 2>/dev/null | grep -m1 libamdhip64.so.7)"
if on0 true 2>/dev/null; then
  info "node0"
  check_host node0 "$(on0 'rocminfo 2>/dev/null | grep -m1 gfx1151; ldconfig -p 2>/dev/null | grep -m1 libamdhip64.so.7')"
else
  gap "node0 unreachable — run its ROCm check once ssh works"
fi
finish