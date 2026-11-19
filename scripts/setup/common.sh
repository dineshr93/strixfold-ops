# common.sh — shared helpers for the setup scripts (source, don't execute)
NODE0=${NODE0:-node0}
TFP="$HOME/tfp"
SRC="$TFP/src/TensorFold"
DEPLOY="$TFP/deploy/current"
BUNDLE="$HOME/models/tf-port/inputs-tp2-c178a012"
GAPS=0; ACTIONS=0
ok()   { printf '  [ok]   %s\n' "$*"; }
gap()  { printf '  [GAP]  %s\n' "$*"; GAPS=$((GAPS+1)); }
act()  { printf '  [DO]   %s\n' "$*"; ACTIONS=$((ACTIONS+1)); }
info() { printf '== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
on0()  { ssh -o BatchMode=yes -o ConnectTimeout=5 "$NODE0" "$@"; }
sudo_ok() { sudo -n true 2>/dev/null; }
# priv CMD...: run with sudo when passwordless sudo works; otherwise print it for the user/agent
priv() {
  if sudo_ok; then sudo "$@"
  else act "run: sudo $*"; return 0; fi
}
# finish: exit 0 when nothing remains, 2 when actions/gaps were printed
finish() {
  if [ "$GAPS" -gt 0 ] || [ "$ACTIONS" -gt 0 ]; then
    printf '%d gap(s), %d action(s) remain — see above\n' "$GAPS" "$ACTIONS"; exit 2
  fi
  echo "all checks pass — nothing to do"; exit 0
}