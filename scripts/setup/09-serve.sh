#!/bin/bash
# 09-serve.sh — serving config on both boxes, then the staggered start (health + probe).
# Env: SERVE_NAME (default dsv41), SERVE_HOST (default 127.0.0.1), SERVE_PORT (default 18080),
#      ROWS (default 65536; 1048576 sets CONTEXT=1048576, PEAK_GIB=107 and the 1M bundle).
cd "$(dirname "$0")" && source ./common.sh
ROWS=${ROWS:-65536}
NAME=${SERVE_NAME:-dsv41}; HOST=${SERVE_HOST:-127.0.0.1}; PORT=${SERVE_PORT:-18080}
CONF="$TFP/run/conf/my.conf"
[ -x "$DEPLOY/tools/dsv41-hip/first_light.sh" ] || { echo "no deployment — phase 08 first"; exit 1; }
if [ "$ROWS" = 65536 ]; then B='$HOME/models/tf-port/inputs-tp2-c178a012'; CTX=8192; PEAK=101
else B="\$HOME/models/tf-port/inputs-tp2-${ROWS}"; CTX=$((ROWS - 49)); PEAK=107; fi
info "serving config (both boxes, identical)"
if [ "$ROWS" = 65536 ]; then BM="$HOME/models/tf-port/inputs-tp2-c178a012/inputs_manifest.json"
else BM="$HOME/models/tf-port/inputs-tp2-${ROWS}/inputs_manifest.json"; fi
[ -f "$BM" ] || { echo "bundle manifest missing — phase 08 first"; exit 1; }
H=$(sha256sum "$BM" | cut -d' ' -f1)
if [ -f "$CONF" ] && on0 "cmp -s tfp/run/conf/my.conf /dev/stdin" < "$CONF" 2>/dev/null; then
  ok "my.conf present and identical on both boxes"
else
  mkdir -p "$TFP/run/conf"
  install -m 644 "$DEPLOY/tools/dsv41-hip/serve.conf" "$CONF"
  sed -i "s/^BUNDLE_SHA256=[0-9a-f]*/BUNDLE_SHA256=$H/" "$CONF"
  sed -i "s|^BUNDLE=.*|BUNDLE='$B'|" "$CONF"
  sed -i "s/^CONTEXT=[0-9]*/CONTEXT=$CTX/" "$CONF"
  sed -i "s/^PEAK_GIB=[0-9]*/PEAK_GIB=$PEAK/" "$CONF"
  sed -i "s/^SERVE_HOST=.*/SERVE_HOST=$HOST/" "$CONF"
  sed -i "s/^SERVE_PORT=.*/SERVE_PORT=$PORT/" "$CONF"
  sed -i "s/^SERVE_NAME=.*/SERVE_NAME=$NAME/" "$CONF"
  on0 'mkdir -p tfp/run/conf' && scp -q "$CONF" "$NODE0:tfp/run/conf/my.conf" && ok "my.conf written and synced (H=$H, CONTEXT=$CTX)" || gap "conf sync to node0 failed"
fi
info "start"
# an existing conf is authoritative for the port (it may differ from this script's default)
[ -f "$CONF" ] && PORT=$(sed -n 's/^SERVE_PORT=\([0-9][0-9]*\).*/\1/p' "$CONF")
if curl -fsS -m 3 "http://10.40.0.1:$PORT/health" >/dev/null 2>&1; then
  ok "already serving on port $PORT — nothing to do"
  finish
fi
info "other GPU work / memory gate (start preconditions)"
if on0 'podman ps --format "{{.Names}}" 2>/dev/null' | grep -q '^halogen-flash-server$'; then
  gap "halogen-flash-server runs on node0 — stop it first: make halogen-stop (warn the user: their agent may go silent)"
fi
NEED=$((PEAK + 8))
A1=$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo)
[ "$A1" -ge "$NEED" ] && ok "node1 MemAvailable ${A1} GiB >= ${NEED}" || gap "node1 MemAvailable ${A1} GiB < ${NEED} — stop other GPU work"
A0=$(on0 'awk "/MemAvailable/{print int(\$2/1048576)}" /proc/meminfo' 2>/dev/null)
[ "${A0:-0}" -ge "$NEED" ] && ok "node0 MemAvailable ${A0} GiB >= ${NEED}" || gap "node0 MemAvailable ${A0:-?} GiB < ${NEED} — stop other GPU work"
bash "$(dirname "$0")/../start-serve.sh" || gap "start failed — see the wedge notes in AGENTS.md/README"
finish