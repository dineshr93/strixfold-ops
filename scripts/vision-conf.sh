#!/bin/bash
# vision-conf.sh — install the vision variant of the serving config (make startv) and check the
# inputs a text_image start needs. It installs and checks; it never starts anything (that is
# start-serve.sh's job).
#
# my-vision.conf is a thin overlay: it sources my.conf, then turns the image keys on, so every
# shared setting (network, deploy, bundle, engine, server) stays in ONE file and this one can
# never drift from it. The ranks source a single config (serve_lib.sh) and first_light.sh names
# it under node0's $HOME, so the same bytes must sit at the same path on both boxes: write here,
# install on node0, verify identical.
#
# The checks mirror serve_lib.sh's own gates for MODALITIES=text_image (serve_check): the bias
# file and its pinned sha256 on BOTH ranks, the sidecar's SHA256SUMS on rank 0. Doing them here
# fails in 2 s instead of after a 15-minute weight load.
#
# PEAK_GIB is inherited from my.conf unchanged: the tower costs rank 0 ~1.3 GiB (926 MiB weights
# + 324 MiB workspace + 10 MiB span, ADAPTER.md 8.1) and rank 1 ~40 MiB, inside the +8 GiB the
# gate already demands. MAX_IMAGES stays unset (the server's 32).
set -euo pipefail
cd "$(dirname "$0")" && source ./setup/common.sh

CONF="$TFP/run/conf/my.conf"
CONFV="$TFP/run/conf/my-vision.conf"
BIAS_REL=tfp/deploy/current/ds-kit/vision/gate_bias_vl.safetensors
SIDE_REL=models/tf-port/vision-sidecar
KIT_REL=tfp/deploy/current/native-hip/share/tensorfold/hip/gfx1151/dsv41/manifest.json
BIAS_SHA=4745da4b5f24c67170ee24e2c95652e45ba13c0ca0abc2be3cc7a2a3545792d0

[ -f "$CONF" ] || { echo "no $CONF — run phase 09 (make setup-09-serve) first" >&2; exit 1; }

info "the inputs a text_image start needs"
S=$(sha256sum "$HOME/$BIAS_REL" 2>/dev/null | cut -d' ' -f1 || true)
[ "${S:-}" = "$BIAS_SHA" ] && ok "rank 1 (this box): gate bias $BIAS_REL matches its pin" \
  || gap "rank 1 (this box): $HOME/$BIAS_REL is '${S:-missing}', the pin is $BIAS_SHA"
S=$(on0 "sha256sum $BIAS_REL" 2>/dev/null | cut -d' ' -f1 || true)
[ "${S:-}" = "$BIAS_SHA" ] && ok "rank 0 (node0): gate bias $BIAS_REL matches its pin" \
  || gap "rank 0 (node0): $BIAS_REL is '${S:-missing}', the pin is $BIAS_SHA"
on0 "cd $SIDE_REL && sha256sum --quiet -c SHA256SUMS" >/dev/null 2>&1 \
  && ok "rank 0 (node0): tower sidecar $SIDE_REL verifies against its SHA256SUMS" \
  || gap "rank 0 (node0): $SIDE_REL missing or fails its SHA256SUMS (kit/make_vision_sidecar.py)"
on0 "grep -q vision $KIT_REL" >/dev/null 2>&1 \
  && ok "rank 0 (node0): the kit carries the vision object (hip_load.vision)" \
  || gap "rank 0 (node0): no vision object in the deployed kit — text_image would refuse at Kit.open"
[ "$GAPS" -eq 0 ] || finish

info "my-vision.conf (my.conf + the image keys)"
cat > "$CONFV.tmp" <<'EOF'
# my-vision.conf — the vision variant of my.conf: 'make startv' brings the pair up with the
# model's own vision tower on (ADAPTER.md 8.1). It adds nothing but the image keys, so every
# shared setting stays in my.conf and this file never drifts from it. Edit my.conf, not this
# file, then re-run 'make startv' (it rewrites and re-syncs this one).
#
#   MODALITIES=text_image  the HIP tower opens on rank 0 (D13); rank 1 only takes the routed
#                          spans, but BOTH ranks need the routing biases (serve_check).
#   VISION_DIR             rank 0's tower weights, the one-shard sidecar (926 MiB BF16). The
#                          single quotes keep $HOME for each box — serve_lib.sh evals it.
#   VISION_BIAS_SHA256     pins DS_KIT/vision/gate_bias_vl.safetensors on both ranks.
#   PEAK_GIB               inherited from my.conf: the tower's ~1.3 GiB fits the gate's +8 GiB.
#   MAX_IMAGES             unset on purpose: the server's 32.

source "$HOME/tfp/run/conf/my.conf"

MODALITIES=text_image
VISION_DIR='$HOME/models/tf-port/vision-sidecar'
VISION_BIAS_SHA256=4745da4b5f24c67170ee24e2c95652e45ba13c0ca0abc2be3cc7a2a3545792d0
EOF
if [ -f "$CONFV" ] && cmp -s "$CONFV.tmp" "$CONFV"; then
  rm -f "$CONFV.tmp"; ok "my-vision.conf already current here"
else
  mv "$CONFV.tmp" "$CONFV"; chmod 644 "$CONFV"; ok "my-vision.conf written here"
fi
if on0 "cmp -s tfp/run/conf/my-vision.conf /dev/stdin" < "$CONFV" 2>/dev/null; then
  ok "my-vision.conf identical on node0 (both ranks hash the same bytes into the handshake)"
else
  scp -q "$CONFV" "$NODE0:tfp/run/conf/my-vision.conf" \
    && ok "my-vision.conf installed on node0" || gap "could not install my-vision.conf on node0"
fi
finish
