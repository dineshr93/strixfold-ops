#!/bin/bash
# 06-build.sh — Triton AOT kit, zig build + test build, GPU tests (node1). Long: run in background.
cd "$(dirname "$0")" && source ./common.sh
[ -d "$SRC" ] || { echo "source missing — phase 05 first"; exit 1; }
cd "$SRC" || exit 1
COMMIT=$(git rev-parse HEAD)
info "Triton AOT kit"
KIT="$HOME/tfp/tri/kit/gfx1151"
if [ -f "$KIT/aot.json" ] && [ -d "$KIT/hsaco" ]; then ok "kit: $(find "$KIT/hsaco" -type f | wc -l) hsaco files"
elif [ -x "$HOME/venvs/triton/bin/python" ]; then
  echo "building the kit (30–60 min)…"
  (cd tools/dsv41-hip/tri && systemd-run --user --scope -p CPUQuota=800% -p MemoryHigh=12G -p MemoryMax=16G \
    taskset -c 8-15,24-31 nice -n 10 "$HOME/venvs/triton/bin/python" aot_build.py \
    ../../../zig/src/families/dsv41/fixtures/launches.json "$KIT" \
    --extra ../../../zig/src/families/dsv41/fixtures/derived_launches.json --jobs 8) \
    && ok "kit built" || gap "kit build failed — see output"
else gap "triton venv missing — phase 05"; fi
info "zig build"
if [ -x zig-out/native-hip/bin/tensorfold-native ]; then ok "zig-out/native-hip built"
else
  tools/dsv41-hip/zig_build.sh install && ok "zig_build.sh install" || gap "zig build failed"
fi
info "test build + GPU tests"
MARK="$TFP/run/gpu-tests-pass.$COMMIT"
SERVING=0
pgrep -x tf-dsv41-lanes >/dev/null 2>&1 && SERVING=1
on0 'pgrep -x tensorfold-native >/dev/null' 2>/dev/null && SERVING=1
if [ -f "$MARK" ]; then ok "GPU tests passed for $COMMIT"
elif [ "$SERVING" = 1 ]; then
  act "GPU tests not marked for $COMMIT, but the pair is serving — stop serving first (make stop), then re-run this phase"
else
  if [ -d "$KIT" ]; then
    tools/dsv41-hip/zig_build.sh test test-dsv41-hip-host native-hip dsv41-hip-gpu-test -Dhip-triton-kit="$KIT" || gap "test build failed"
    # no EXTRA_KIT: the raw tri kit is not a loader-format kit (the check would refuse it)
    if tools/dsv41-hip/run_gpu_tests.sh; then mkdir -p "$TFP/run"; touch "$MARK"; ok "GPU tests green (smoke, ABI, glue)"; else gap "GPU tests failed — see output"; fi
  else gap "kit missing — cannot run GPU tests"; fi
fi
finish