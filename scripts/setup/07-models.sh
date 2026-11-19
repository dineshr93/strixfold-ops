#!/bin/bash
# 07-models.sh — pinned model downloads (~400 GB) on node1, then rsync to node0. Long: run in background.
# hf download resumes and skips complete files; re-running is safe. For incremental transfer while the
# download runs, an agent may rsync in a loop (exclude .cache/) — see AGENTS.md.
cd "$(dirname "$0")" && source ./common.sh
[ -x "$HOME/venvs/tfp-inputs/bin/hf" ] || { echo "inputs venv missing — phase 05 first"; exit 1; }
HF="$HOME/venvs/tfp-inputs/bin/hf"
CKPT="$HOME/models/tf-port/libertai-2.9bpw"
ENGRAM="$HOME/models/tf-port/ds1017-1bae0e10"
big_enough() { [ -d "$1" ] && [ "$(du -s --block-size=1G "$1" 2>/dev/null | cut -f1)" -ge 100 ]; }
info "checkpoint (LibertAI EXL3 2.9 bpw, ~197 GB)"
if big_enough "$CKPT"; then ok "checkpoint present ($(du -sh "$CKPT" | cut -f1))"
else
  mkdir -p "$CKPT"
  "$HF" download LibertAIDAI/DeepSeek-V4.1-Flash-1017-EXL3-2.9bpw \
    --revision c178a01284fc5c0e859d8668cffaac81ca8f4042 --local-dir "$CKPT" \
    && ok "checkpoint downloaded" || gap "checkpoint download failed/incomplete — re-run"
fi
info "Engram shards (47+48 of DeepSeek-V4.1-Flash-1017, ~203 GB)"
if big_enough "$ENGRAM"; then ok "engram present ($(du -sh "$ENGRAM" | cut -f1))"
else
  mkdir -p "$ENGRAM"
  "$HF" download deepseek-ai/DeepSeek-V4.1-Flash-1017 \
    model-00047-of-00048.safetensors model-00048-of-00048.safetensors \
    --revision 1bae0e1088993b9b82de08f59de5be5a34e42170 --local-dir "$ENGRAM" \
    && ok "engram downloaded" || gap "engram download failed/incomplete — re-run"
fi
info "copy to node0 (over USB4)"
if on0 true 2>/dev/null; then
  on0 'mkdir -p models/tf-port'
  for d in libertai-2.9bpw ds1017-1bae0e10; do
    if on0 "[ -d models/tf-port/$d ] && [ \$(du -s --block-size=1G models/tf-port/$d 2>/dev/null | cut -f1) -ge 100 ]"; then
      ok "node0: $d present"
    else
      rsync -a --partial "$HOME/models/tf-port/$d" "$NODE0:models/tf-port/" && ok "node0: $d synced" || gap "rsync $d failed — re-run"
    fi
  done
else gap "node0 unreachable — sync later"; fi
finish