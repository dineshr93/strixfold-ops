#!/bin/bash
# 08-inputs.sh — prepare inputs, verify rank 1, deploy both boxes, verify rank 0. Long: run in background.
# ROWS=65536 (default): the shipped bundle. ROWS=1048576: a 1M-token bundle (the documented longer-context
# path — a full second prepare, ~as long as the first). The deployment carries the bundle's RoPE kit.
cd "$(dirname "$0")" && source ./common.sh
ROWS=${ROWS:-65536}
[ -d "$SRC" ] || { echo "source missing — phase 05 first"; exit 1; }
cd "$SRC" || exit 1
CKPT="$HOME/models/tf-port/libertai-2.9bpw"; ENGRAM="$HOME/models/tf-port/ds1017-1bae0e10"
[ -d "$CKPT" ] && [ -d "$ENGRAM" ] || { echo "model files missing — phase 07 first"; exit 1; }
if [ "$ROWS" = 65536 ]; then B="$HOME/models/tf-port/inputs-tp2-c178a012"; else B="$HOME/models/tf-port/inputs-tp2-${ROWS}"; fi
MAXCTX=$((ROWS - 49))
report_pass() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('status')=='pass' else 1)" "$1" 2>/dev/null; }
info "prepare inputs (ROWS=$ROWS, bundle $B)"
if [ -f "$B/inputs_manifest.json" ]; then ok "bundle prepared"
else
  if [ "$ROWS" = 65536 ]; then tools/dsv41-hip/prepare_inputs.sh "$CKPT" "$ENGRAM" "$B" || gap "prepare_inputs failed"
  else tools/dsv41-hip/prepare_inputs.sh "$CKPT" "$ENGRAM" "$B" "$ROWS" || gap "prepare_inputs failed"; fi
fi
[ -f "$B/inputs_manifest.json" ] || { echo "no bundle manifest — stopping"; exit 1; }
H=$(sha256sum "$B/inputs_manifest.json" | cut -d' ' -f1)
ok "bundle identity H=$H"
info "copy bundle to node0 (without rank1's cache)"
if on0 true 2>/dev/null; then
  if on0 "[ -f models/tf-port/$(basename "$B")/inputs_manifest.json ]"; then ok "node0 bundle present"
  else rsync -a --exclude rank1/ "$B" "$NODE0:models/tf-port/" && ok "bundle synced" || gap "bundle rsync failed"; fi
  # non-standard row counts: verify_inputs finds the rope reference beside the bundle — copy it too
  [ -f "$B.rope-reference.json" ] && scp -q "$B.rope-reference.json" "$NODE0:models/tf-port/" 2>/dev/null
else gap "node0 unreachable"; fi
info "verify rank 1 (node1)"
R1=$(ls "$B".verify-rank1-*.json 2>/dev/null | head -1)
if [ -n "$R1" ] && report_pass "$R1"; then ok "rank1 report pass"
else
  if [ "$ROWS" = 65536 ]; then tools/dsv41-hip/verify_inputs.sh "$B" 1 "$CKPT" "$ENGRAM" "$H" || gap "verify rank1 failed"
  else tools/dsv41-hip/verify_inputs.sh "$B" 1 "$CKPT" "$ENGRAM" "$H" "$MAXCTX" || gap "verify rank1 failed"; fi
fi
info "deploy (one commit's bytes on both boxes)"
C=$(git rev-parse HEAD)
SERVING=0
pgrep -x tf-dsv41-lanes >/dev/null 2>&1 && SERVING=1
on0 'pgrep -x tensorfold-native >/dev/null' 2>/dev/null && SERVING=1
if [ -n "$(git status --porcelain)" ]; then gap "checkout is dirty — deploy needs a clean tree (commit or stash)"; fi
if [ -x "$DEPLOY/native-hip/bin/tensorfold-native" ] && [ "$(readlink "$DEPLOY")" = "${C:0:12}" ]; then
  ok "deployed: ${C:0:12}"
elif [ "$SERVING" = 1 ]; then
  act "deploy differs from HEAD but the pair is serving — stop serving first (make stop), then re-run to redeploy"
else
  tools/dsv41-hip/deploy_rank0.sh --native zig-out/native-hip --bin-commit "$C" --ds-kit "$B/kit" || gap "deploy to node0 failed"
  tools/dsv41-hip/deploy_rank0.sh --host local --native zig-out/native-hip --bin-commit "$C" --ds-kit "$B/kit" || gap "local deploy failed"
fi
info "verify rank 0 (node0, needs tf-dsv41-check from the build)"
if on0 true 2>/dev/null; then
  on0 'mkdir -p tfp/bin'
  scp -q zig-out/bin/tf-dsv41-check "$NODE0:tfp/bin/" 2>/dev/null
  R0=$(on0 "ls models/tf-port/$(basename "$B").verify-rank0-*.json 2>/dev/null | head -1")
  if [ -n "$R0" ] && on0 "python3 -c \"import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('status')=='pass' else 1)\" '$R0'"; then
    ok "rank0 report pass"
  else
    if [ "$ROWS" = 65536 ]; then
      on0 "TFP_BIN=\$HOME/tfp/bin ~/tfp/deploy/current/tools/dsv41-hip/verify_inputs.sh ~/models/tf-port/$(basename "$B") 0 ~/models/tf-port/libertai-2.9bpw ~/models/tf-port/ds1017-1bae0e10 $H" || gap "verify rank0 failed"
    else
      on0 "TFP_BIN=\$HOME/tfp/bin ~/tfp/deploy/current/tools/dsv41-hip/verify_inputs.sh ~/models/tf-port/$(basename "$B") 0 ~/models/tf-port/libertai-2.9bpw ~/models/tf-port/ds1017-1bae0e10 $H $MAXCTX" || gap "verify rank0 failed"
    fi
  fi
else gap "node0 unreachable"; fi
echo "H=$H" > "$TFP/run/bundle-H.txt"
ok "bundle identity saved to ~/tfp/run/bundle-H.txt (phase 09 uses it)"
finish