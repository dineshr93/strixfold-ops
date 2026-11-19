#!/bin/bash
# 05-toolchain.sh — python3.13, zig 0.17.0 (sha256-checked), source clone, inputs + triton venvs.
# node1 builds; node0 needs only the inputs venv. Privileged bits (deadsnakes) are printed, not run.
cd "$(dirname "$0")" && source ./common.sh
info "python3.13"
if have python3.13; then ok "python3.13: $(python3.13 --version 2>&1)"
elif have uv; then act "uv python install 3.13   # then use that interpreter for the venvs below"
else
  gap "python3.13 missing (the pinned Triton wheel is cp313; Ubuntu 26.10 ships 3.14/3.15)"
  act "preferred: install uv, then: uv python install 3.13"
  act "or deadsnakes (26.04 pocket on 26.10):"
  act "  sudo add-apt-repository -y ppa:deadsnakes/ppa"
  act "  sudo sed -i 's/^Suites: stonking/Suites: resolute/' /etc/apt/sources.list.d/deadsnakes-ubuntu-ppa-*.sources"
  act "  sudo apt update && sudo apt install -y python3.13 python3.13-venv"
fi
PY=python3.13; have python3.13 || PY=""
info "basic packages + zig (node1)"
have git && have rsync && ok "git + rsync" || act "sudo apt install git rsync python3-venv"
if [ -x "$HOME/opt/zig/zig" ] && [ "$($HOME/opt/zig/zig version)" = 0.17.0 ]; then ok "zig 0.17.0 at ~/opt/zig"
else
  gap "zig 0.17.0 missing"
  act "cd /tmp && wget https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz"
  act 'echo "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026  zig-x86_64-linux-0.17.0.tar.xz" | sha256sum -c'
  act "mkdir -p ~/opt && tar -xf zig-x86_64-linux-0.17.0.tar.xz -C ~/opt && ln -sfn zig-x86_64-linux-0.17.0 ~/opt/zig"
fi
info "source checkout (node1)"
if [ -d "$SRC/.git" ]; then ok "$SRC ($(git -C "$SRC" rev-parse --short HEAD))"
else act "mkdir -p ~/tfp/src && git clone https://github.com/Shoestring-dev/StrixFold.git $SRC"; fi
info "inputs venv (both boxes)"
if [ -x "$HOME/venvs/tfp-inputs/bin/python" ]; then ok "node1 venv tfp-inputs"
elif [ -n "$PY" ] && [ -d "$SRC" ]; then
  "$PY" -m venv "$HOME/venvs/tfp-inputs"
  "$HOME/venvs/tfp-inputs/bin/pip" install --no-deps --require-hashes -r "$SRC/tools/dsv41-hip/requirements-inputs.lock.txt" --extra-index-url https://download.pytorch.org/whl/cpu && ok "node1 venv tfp-inputs installed" || gap "inputs venv install failed — see pip output"
else gap "node1 inputs venv missing (needs python3.13 + source first)"; fi
if on0 true 2>/dev/null; then
  if on0 '[ -x $HOME/venvs/tfp-inputs/bin/python ]'; then ok "node0 venv tfp-inputs"
  elif [ -d "$SRC" ]; then
    scp -q "$SRC/tools/dsv41-hip/requirements-inputs.lock.txt" "$NODE0:/tmp/"
    on0 'P=python3.13; command -v python3.13 >/dev/null || P=""; [ -n "$P" ] && $P -m venv ~/venvs/tfp-inputs && ~/venvs/tfp-inputs/bin/pip install --no-deps --require-hashes -r /tmp/requirements-inputs.lock.txt --extra-index-url https://download.pytorch.org/whl/cpu' && ok "node0 venv tfp-inputs installed" || gap "node0 needs python3.13 first (same options as node1), then re-run"
  else gap "node0 inputs venv missing (source needed first)"; fi
else gap "node0 unreachable — its venv comes later"; fi
info "triton venv (node1)"
if [ -x "$HOME/venvs/triton/bin/python" ]; then ok "venv triton"
elif [ -n "$PY" ]; then
  W=triton-3.8.0+git675c5987.rocm10.1.0a20260822-cp313-cp313-linux_x86_64.whl
  mkdir -p "$TFP/tri/wheels"
  if [ ! -f "$TFP/tri/wheels/$W" ]; then
    wget -O "$TFP/tri/wheels/$W" "https://rocm.nightlies.amd.com/whl-multi-arch/${W/+/%2B}" || gap "triton wheel download failed"
  fi
  if echo "1bab2eeb8f4beccad389a497a45b3018fa6291ab93c577f04b1376cf12422499  $TFP/tri/wheels/$W" | sha256sum -c -; then
    "$PY" -m venv "$HOME/venvs/triton" && "$HOME/venvs/triton/bin/pip" install --no-deps "$TFP/tri/wheels/$W" && ok "venv triton installed" || gap "triton venv install failed"
  else gap "triton wheel sha256 mismatch — delete and re-download"; fi
else gap "triton venv missing (needs python3.13)"; fi
finish