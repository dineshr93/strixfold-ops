# strixfold-ops

Operational artifacts and the working procedure for the StrixFold TP2 serve on the two Framework Desktops
(Ryzen AI Max+ 395, 128 GB, gfx1151). Isolated from the `tc` repo; everything here runs from **node1**.

## Point your AI at this repo

This repo is built to be handed to an AI coding agent (Claude Code, Hermes, Codex, …) on a fresh pair of
boxes: **read [AGENTS.md](AGENTS.md), run `make preflight`, and work the setup phases in order.** The agent
audits both boxes, automates everything it can unprivileged, and prints the exact remaining commands for the
privileged steps (apt, grub, netplan, BIOS) — it asks before reboots and before stopping your services.

```bash
git clone <this repo> ~/repos/strixfold-ops && cd ~/repos/strixfold-ops
make preflight          # read-only audit of both boxes -> gap list
make setup-01-firmware  # then 02-kernel, 03-network, … 09-serve (see AGENTS.md)
```

Every phase script is check-first and idempotent: on an already-set-up pair each one reports `[ok]` and does
nothing. Long phases (kit build, downloads, input prep) are meant to run in the background. Exit codes:
`0` done, `2` actions remain (read the `[DO]` lines), `1` error. For a 1M-token window from scratch, run
phases 08 and 09 with `ROWS=1048576` (the documented full-prepare path).

Humans: the same phases work run by hand; the runbook below covers day-2 operations.

## Topology

- **node0** (`workshop` on this pair, ssh alias `node0` = 10.40.0.1): rank 0, serves the OpenAI-compatible API.
- **node1** (`workshops` on this pair, the box you run on): rank 1, the build/ops box. Both boxes linked by two USB4 cables
  (10.40.0.x control, 10.40.1.x stripe).
- Model: the TP2 DeepSeek-V4.1-Flash port (LibertAI EXL3 2.9 bpw checkpoint + Engram shards), one commit's
  bytes deployed on both boxes.

Upstream source: `~/tfp/src/TensorFold` (github.com/Shoestring-dev/StrixFold). The from-scratch setup guide
(BIOS → serving, including everything below) is docs/FRAMEWORK-DESKTOP.md in
[PR #50](https://github.com/Shoestring-dev/StrixFold/pull/50).

## Current serving configuration

`~/tfp/run/conf/my.conf` — **the same file must exist at the same path on both boxes** (`make sync-conf`):

| knob | value | meaning |
|---|---|---|
| `CONTEXT` | 1048576 | 1M-token window (RoPE tables extended, see below) |
| `SERVE_HOST` | 0.0.0.0 | reachable on the LAN |
| `SERVE_PORT` | 8888 | API port |
| `SERVE_NAME` | local-model | the model id in `/v1/models` and chat requests |
| `PEAK_GIB` | 107 | memory gate: a rank starts only with MemAvailable ≥ 115 GiB |
| `MODALITIES` | text | vision needs a tower sidecar + gate bias this deploy doesn't ship |
| `BENCH` | 1 | first_light bench cases (the staggered start skips them; run bench manually) |

Endpoint: `http://192.168.178.33:8888/v1` (LAN) or `http://10.40.0.1:8888/v1` (USB4, from node1), model
`local-model`. `/health` reports `context_length: 1048558`.

## Daily operations (make targets)

| target | what it does |
|---|---|
| `make start` | staggered boot: rank 1 loads first, stall detection + 150 s cooldown retry (up to 4), then rank 0, `/health` + probe. Refuses if halogen is running on node0. |
| `make startv` | the same staggered boot with the model's vision tower on (`MODALITIES=text_image`): installs `my-vision.conf`, checks the image inputs, starts with that conf |
| `make stop` | `first_light.sh down`: SIGTERM rank 0, rank 1 follows, both GPU locks released |
| `make restart` | stop, then the staggered start |
| `make status` | both ranks + GPU locks + `/health` |
| `make show` | artifacts on BOTH boxes: engines, kits, weight caches, configs, GPU/memory |
| `make health` / `make models` / `make probe` | `/health`, `/v1/models`, one chat completion (port/name read from the conf) |
| `make logs` / `make logs0` | follow rank 1's / rank 0's log (`~/tfp/run/serve/latest/`) |
| `make conf` / `make sync-conf` | show the serving knobs / copy my.conf to node0 |
| `make bench` | the last first_light bench numbers |
| `make halogen-stop` / `make halogen-up` | stop/restore the old podman LLM backend on node0 (see Memory below) |

### Change the port, the model alias, or the context

1. `make stop`
2. edit `~/tfp/run/conf/my.conf` (`SERVE_PORT`, `SERVE_NAME`, `CONTEXT`, …)
3. `make sync-conf` (both ranks must read the same file)
4. `make start`, then `make health` / `make models`

The Makefile and start script read `SERVE_PORT`/`SERVE_NAME` from the conf — no hardcoded values to update.

### Turn the vision tower on (images)

`make startv` instead of `make start`. It runs `scripts/vision-conf.sh`, which checks the three inputs a
`text_image` start needs, writes `~/tfp/run/conf/my-vision.conf` — my.conf plus `MODALITIES=text_image`,
`VISION_DIR` (the tower sidecar) and `VISION_BIAS_SHA256` — installs the identical bytes on node0 (both
ranks hash the conf into their handshake), and then runs the usual staggered start. Nothing about the
shared settings changes, so `make start` and `make startv` differ only by the tower.

The assets are already staged on both boxes: the 926 MiB tower sidecar in `~/models/tf-port/vision-sidecar`
(rank 0's is what gets read) and `ds-kit/vision/gate_bias_vl.safetensors` in the deploy (both ranks). The
target checks them before the weight load, so a missing sidecar fails in seconds, not after 15 minutes.
`PEAK_GIB` is inherited as-is: the tower adds ~1.3 GiB on rank 0, inside the gate's +8 GiB headroom.

Switching a running pair between the two needs `make stop` first (`startv` on a pair that already answers
`/health` just reports "already serving"). Upstream's limits then apply: at most 32 images per request
(`MAX_IMAGES` in the overlay changes it), 134,217,728 decoded pixels, 4,096 image tokens (ADAPTER.md 8.1).

## The load wedge (this kernel) and recovery

On the stock Ubuntu kernel 7.3.0-10-generic the weight load intermittently wedges ~3 GiB into layer-0
experts: rank 1's main thread spins in libhsa `BusyWaitSignal::WaitRelaxed` (100% CPU), the GPU is idle, the
kernel log shows `svm_range_restore_work` / `restore_userptr_worker` hogging CPU; rank 0 dies
`PeerNeverLinked`, rank 1's log stays empty.

Established behavior: after a wedged rank is SIGKILLed, the kernel's SVM-restore work stays livelocked for a
while — **instant retries re-wedge; a load started ≥150 s after the kill is clean.** `make start` implements
exactly that (30 s of flat `/proc/<pid>/io` read_bytes = wedged → kill → 150 s cooldown → retry). A **deep
cluster** can survive all four cooldown retries and even a 240 s no-load settle (the kernel restore warnings
go quiet but the load still wedges ~3 GiB in): **reboot the wedged box** to clear the kernel SVM-restore
state, then retry. Don't blame a recent power/config change for a cluster until a reboot-and-retry isolates it.

Manual recovery if a start ever exhausts its attempts:

```bash
make stop                                   # clears locks and any leftover rank
sleep 150                                   # let the kernel settle (or reboot node1)
make start
```

Diagnosis commands (the sandbox blocks perf; run with sudo in a user terminal):
`perf record -e cpu-clock -g -p <rank1 pid> -- sleep 5 && perf report --stdio --no-children`,
`cat /sys/class/drm/card*/device/gpu_busy_percent` (idle while wedged),
`journalctl -k | grep -E 'svm_range|restore_userptr'`.

## Memory gate and other GPU work

A rank starts only with `MemAvailable >= PEAK_GIB + 8` (115 GiB at PEAK_GIB=107) and no other engine on its
box. The weights are ~99 GiB a rank; the pool adds ~0.9 KB per position per rank. Before serving, stop other
GPU consumers on node0 — notably the old agent backend:

```bash
make halogen-stop     # podman stop halogen-flash-server (frees ~71 GB)
make start
# to restore the old backend afterwards (conflicts with SERVE_PORT=8888 — change one of them):
make halogen-up
```

## The 1M-token window (how it was set up)

The shipped ds-kit RoPE tables hold 65,536 rows (`CONTEXT` ≤ rows − 49). This pair runs the creator kit's full
**1,114,112 hash-verified rows**, generated with the pinned CPU generator
(`~/venvs/tfp-inputs`, `prepare_inputs.generate_rope`, reference = `assets/creator_kit_v0.6.1_rope.json`) and
installed into `~/tfp/deploy/current/ds-kit` on **both** boxes (read-only deploy: chmod u+w → copy → 400/555).
The ds-kit is not covered by the HIP kit manifest check; both boxes must hold identical files.

- Originals: `~/tfp/run/ds-kit-65536-backup/` on both boxes. Rollback = copy them back the same way, set
  `CONTEXT=8192` (or ≤ 65487), `PEAK_GIB=101`, sync-conf, restart.
- The clean from-scratch alternative (a second full `prepare_inputs.sh` with `R=1048576`) is documented in
  GETTING-STARTED.md "Longer context" and PR #50 §10.
- `CONTEXT` hard cap with the full tables: 1,114,063. `/health` reports CONTEXT − 18.

## Artifact inventory (same layout on both boxes)

| artifact | path |
|---|---|
| engines | `~/tfp/deploy/current/native-hip/bin/{tensorfold-native,tf-dsv41-lanes}` |
| HIP kit (manifest-checked) | `~/tfp/deploy/current/native-hip/share/tensorfold/hip/gfx1151/dsv41` |
| ds-kit (RoPE + engram.json) | `~/tfp/deploy/current/ds-kit` |
| serve tools | `~/tfp/deploy/current/tools/dsv41-hip` (first_light.sh, serve-rank{0,1}.sh, serve_lib.sh, bench) |
| model bundle | `~/models/tf-port/inputs-tp2-c178a012` (model/, rank0/rank1 caches ~99 GiB each, token map, manifest) |
| Engram shards | `~/models/tf-port/ds1017-1bae0e10` (~190 GiB) |
| checkpoint | `~/models/tf-port/libertai-2.9bpw` (~197 GiB) |
| serving config | `~/tfp/run/conf/my.conf` (identical on both boxes) |
| runs | `~/tfp/run/serve/<RUN_ID>/` — rank logs, pids, resolved.json, bench.json; `latest` symlink |
| source checkout | `~/tfp/src/TensorFold` (node1) |
| venvs | `~/venvs/tfp-inputs` (torch CPU, inputs/rope), `~/venvs/triton` (node1) |
| GPU lock | `/var/tmp/halo-gpu.lock` (per box) |

`make show` prints all of this live on both boxes.

## Benchmarking

```bash
# the three bench cases against a live run (on node0):
ssh node0 'cd ~/tfp/deploy/current/tools/dsv41-hip && RUN_ID=<run> TF_SERVE_CONF=$HOME/tfp/run/conf/my.conf ./serve-rank0.sh bench'
# writing speed vs context depth (from node1; adjust URL/model to the conf):
cd ~/tfp/src/TensorFold && python3 tools/dsv41-hip/ctx_sweep.py http://10.40.0.1:8888 local-model zig/src 0,2000,8000,32000 1 sweep.json
```

Last measured (19 Nov 2026, CONTEXT=1048576, DRAFTS=1): code 71.7 / prose 41.7 tok/s, prompt reading
1,258 tok/s at 1,818 tokens; ctx sweep writing 68–72 tok/s flat to 32k depth, prefill ~1,250 tok/s. At the
shipped 8K context: 70.8 / 41.9 / 1,260. Full numbers: PR #50 and docs/COMMUNITY-RESULTS.md upstream.

### CPU power profile — the one safe, quality-neutral lever

The conf above is already at the upstream tuned reference (two-cable stripe, MTU 1500, proxy + HIP graphs,
drafts, `AUX=hip`, `PREFILL_SPLIT_LARGE=1`); there is no conf-level speedup left to guess. The remaining
quality-neutral lever is the CPU power profile. Set it on **both** boxes (persists across reboot via
power-profiles-daemon; unprivileged `powerprofilesctl set` is polkit-denied over ssh, so use sudo):

```bash
sudo powerprofilesctl set performance   # both nodes; verify: powerprofilesctl get -> performance
```

Measured on this pair (CONTEXT=1048576, greedy, two bench runs averaged vs balanced): **prefill 1,290 →
1,394 tok/s (+8%, best run +11.6%)**, decode code 70.95 → 72.27 (+1.9%) / prose 41.53 → 41.98 (+1.1%),
TTFT 1.41 → 1.35 s. All three completion sha256s **bit-identical** to balanced — no quality trade. Decode
is GPU/USB4-latency bound so CPU clocks barely move it; prefill (CPU-side gather/proxy) gains most. Temps
under load stay safe (node0 CPU ~75 °C / GPU ~57 °C, node1 cooler; throttle ~95 °C). Revert with
`sudo powerprofilesctl set balanced`. The experimental knobs (`HC_SIDE`/`ENGRAM_AIO`/`L2_PREFETCH`) and the
screened "mb5" `ROUND_MS` table have no qualified verdict upstream — left off.

After a staggered start, `bench.json` lives in **node0's** run dir (`make bench` reads node1's, which is
empty); run it on node0:

```bash
RID=$(ssh node0 'readlink ~/tfp/run/serve/latest')
ssh node0 "cd ~/tfp/deploy/current/tools/dsv41-hip && RUN_ID=$RID TF_SERVE_CONF=\$HOME/tfp/run/conf/my.conf ./serve-rank0.sh bench"
```

## Related

- Upstream guide: [Shoestring-dev/StrixFold PR #50](https://github.com/Shoestring-dev/StrixFold/pull/50)
  (docs/FRAMEWORK-DESKTOP.md — the from-scratch walkthrough this runbook condenses).
- Agent skill: `strixfold-two-box` (optional, Hermes-specific: setup audit workflow +
  `references/serve-lifecycle.md` with the wedge analysis and the RoPE extension procedure).
- Hermes's local LLM backend points at this serve (`local-model`); with the serve down, switch the agent to a
  portal model or restore halogen.