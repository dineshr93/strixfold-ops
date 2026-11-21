#!/bin/bash
# start-serve.sh — staggered TP2 start with stall detection + cooldown retry.
#
# The weight load intermittently wedges ~3 GiB into layer-0 experts (HSA
# BusyWaitSignal spin, GPU idle, kernel svm_range_restore_work livelock on this
# Ubuntu 7.3.0-10 kernel; the repo is tested on Debian rex 7.2.7). After a wedge is
# SIGKILLed, the kernel's SVM-restore work stays livelocked for a while: retries
# within seconds wedge again (9/9), a load started >=150 s later is clean (verified
# 2026-11-19). So: rank 1 loads first (staggered); 30 s of flat io = stalled ->
# kill, COOLDOWN 150 s, retry (up to 4); then rank 0 boots, /health + probe. Locks,
# run dirs and resolved.json stay compatible with first_light.sh down/status.
set -euo pipefail
TOOLS=$HOME/tfp/deploy/current/tools/dsv41-hip
CONF=${CONF:-$HOME/tfp/run/conf/my.conf}   # make startv passes the vision variant
# resolve by sourcing, not grepping literal lines: the conf may be an overlay that
# sources another file (my-vision.conf sources my.conf). A literal-line grep finds
# nothing there, PORT stays empty, and the readiness poll hammers the fallback port
# while the pair serves fine — then the ERR trap takes the healthy run down.
PORT=$(bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${SERVE_PORT:-}"' bash "$CONF")
NAME=$(bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${SERVE_NAME:-}"' bash "$CONF")
API=http://10.40.0.1:${PORT:-18080}
R0=node0
export TF_SERVE_CONF=$CONF
cd "$TOOLS"

# already serving? leave it alone
if curl -fsS -m 3 "$API/health" >/dev/null 2>&1; then
  echo "already serving: $(curl -fsS -m 3 "$API/health")"; exit 0
fi

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
export RUN_ID
RUN=$HOME/tfp/run/serve/$RUN_ID
r0() { ssh "$R0" "RUN_ID=$RUN_ID TF_SERVE_CONF=$CONF $TOOLS/serve-rank0.sh $*"; }

cleanup() {
  echo "start failed — taking the run down" >&2
  r0 stop >/dev/null 2>&1 || true
  ./serve-rank1.sh stop >/dev/null 2>&1 || true
  r0 unlock >/dev/null 2>&1 || true
  ./serve-rank1.sh unlock >/dev/null 2>&1 || true
}
trap cleanup ERR

echo "run $RUN_ID: rank 1 first (staggered), rank 0 on $R0 after rank 1's weights load"
r0 lock
# rank 1 takes node1's GPU lock itself via serve_spawn's flock wrapper (start WITHOUT
# --locked); the engine's own flock releases when it dies.

# rank 1 weights load, with stall detection + retry: the load intermittently wedges
# ~3 GiB in (HSA signal spin, kernel SVM-restore livelock; io flat, no log line).
# A healthy load reads 95 GiB in ~15 s; 30 s without progress = stalled -> kill, retry.
loaded=0
for attempt in 1 2 3 4; do
  ./serve-rank1.sh start
  P=$(cat "$RUN/rank1.pid")
  last=0; flat=0
  for i in $(seq 1 120); do
    grep -q 'read whole' "$RUN/rank1.log" 2>/dev/null && { loaded=1; break; }
    kill -0 "$P" 2>/dev/null || { echo "rank 1 died during load:"; tail -5 "$RUN/rank1.log"; break; }
    now=$(awk '/read_bytes/{print $2}' /proc/$P/io 2>/dev/null || echo 0)
    if [ "$now" = "$last" ]; then flat=$((flat+1)); else flat=0; fi
    last=$now
    [ "$flat" -ge 30 ] && { echo "rank 1 load stalled at $((now/1048576)) MiB (attempt $attempt) — killing, retrying"; kill -9 "$P" 2>/dev/null; sleep 3; break; }
    sleep 1
  done
  [ "$loaded" = 1 ] && break
  grep -q 'read whole' "$RUN/rank1.log" 2>/dev/null && { loaded=1; break; }
  ./serve-rank1.sh stop >/dev/null 2>&1 || true
  [ "$attempt" -lt 4 ] || { echo "rank 1 load failed 4 attempts"; false; }
  echo "cooldown 150s — the kernel's SVM-restore work needs to settle after a wedge-kill"
  sleep 150
done
echo "rank 1 loaded: $(grep -m1 'read whole' "$RUN/rank1.log")"

r0 start --locked

# readiness: rank 0 loads (~15 s), links, answers /health
for i in $(seq 1 1800); do
  curl -fsS -m 3 "$API/health" >/dev/null 2>&1 && break
  sleep 1
done
H=$(curl -fsS -m 5 "$API/health") || { echo "no /health within 1800s"; false; }
echo "$H"

# probe
P=$(curl -fsS -m 120 "$API/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${NAME:-local-model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Answer in one sentence: what is the capital of France?\"}],\"max_tokens\":64,\"temperature\":0}")
echo "$P" | python3 -c 'import json,sys; d=json.load(sys.stdin); t=d["choices"][0]["message"]["content"]; print("probe:", t); assert "paris" in t.lower(), "probe reply lacks Paris"'
trap - ERR
echo "ready: run $RUN_ID ($RUN)"