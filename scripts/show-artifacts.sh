#!/bin/bash
# show-artifacts.sh — the StrixFold TP2 serving artifacts on THIS box (same
# layout on node0 and node1). Run by `make show` locally and over ssh.
H() { printf '\n--- %s ---\n' "$1"; }
sz() { [ -e "$1" ] && du -sh "$1" 2>/dev/null | cut -f1 || echo MISSING; }

echo "host: $(hostname)   $(date -u +%FT%TZ)"

H "deploy (engine + kits)"
D=$HOME/tfp/deploy/current
echo "current -> $(readlink "$D" 2>/dev/null || echo '?')"
for f in native-hip/bin/tensorfold-native native-hip/bin/tf-dsv41-lanes; do
  printf '  %-42s %s\n' "$D/$f" "$(sz "$D/$f")"
done
echo "  hip kit:  $D/native-hip/share/tensorfold/hip/gfx1151/dsv41 ($(sz "$D/native-hip/share/tensorfold/hip/gfx1151/dsv41"))"
echo "  ds-kit:   $D/ds-kit ($(sz "$D/ds-kit"))"
[ -f "$D/ds-kit/rope.json" ] && python3 -c "import json; d=json.load(open('$D/ds-kit/rope.json')); print('  rope rows:', d['rows'], '(max CONTEXT = rows - 49)')" 2>/dev/null

H "model bundle (weights live in the rank caches)"
B=$HOME/models/tf-port/inputs-tp2-c178a012
if [ -f "$HOME/tfp/run/conf/my.conf" ]; then
  CB=$(sed -n "s/^BUNDLE='\(.*\)'.*/\1/p" "$HOME/tfp/run/conf/my.conf")
  [ -n "$CB" ] && B=$(eval echo "$CB")
fi
echo "  bundle:      $B"
echo "  model dir:   $B/model ($(sz "$B/model")) — config.json, tokenizer.json, chat_template.jinja"
for r in 0 1; do
  printf '  rank%d cache: %s (%s)\n' "$r" "$B/rank$r/rank-cache" "$(sz "$B/rank$r/rank-cache")"
done
echo "  token map:   $B/dsv41_token_map.json ($(sz "$B/dsv41_token_map.json"))"
echo "  manifest:    $B/inputs_manifest.json ($(sz "$B/inputs_manifest.json"))"
echo "  engram:      $HOME/models/tf-port/ds1017-1bae0e10 ($(sz "$HOME/models/tf-port/ds1017-1bae0e10"))"

H "serving config + runs"
echo "  conf:   $HOME/tfp/run/conf/my.conf"
grep -E '^(CONTEXT|SERVE_HOST|SERVE_PORT|SERVE_NAME|MODALITIES|PEAK_GIB)=' "$HOME/tfp/run/conf/my.conf" 2>/dev/null | sed 's/#.*//;s/^/    /'
L=$HOME/tfp/run/serve/latest
echo "  latest run: $L -> $(readlink "$L" 2>/dev/null || echo none)"
for r in 0 1; do
  p=$(cat "$L/rank$r.pid" 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "    rank$r: RUNNING (pid $p)"; else echo "    rank$r: not running"; fi
done

H "gpu + memory"
echo "  GTT total: $(cat /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -1 | awk '{printf "%.1f GiB", $1/1073741824}')"
grep MemAvailable /proc/meminfo | sed 's/^/  /'
ls /dev/kfd /dev/dri/renderD128 >/dev/null 2>&1 && echo "  /dev/kfd + /dev/dri: present" || echo "  gpu devices: MISSING"

H "listeners / containers"
ss -tln 2>/dev/null | grep -E ':(18080|8888)\b' | sed 's/^/  /' || echo "  nothing on 18080/8888"
command -v podman >/dev/null && podman ps --format '  {{.Names}}: {{.Status}} ({{.Ports}})' 2>/dev/null
exit 0