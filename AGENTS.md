# AGENTS.md — operating instructions for AI agents

You are setting up or operating a StrixFold TP2 pair: two boxes with the AMD Ryzen AI Max+ 395 (gfx1151,
128 GB), linked by two USB4 cables, serving the DeepSeek-V4.1-Flash port through an OpenAI-compatible API.
This repo automates as much of that as possible. Read this file fully before acting.

## Topology and ground rules

- **node1** is the box you run on (the build/ops box, rank 1). **node0** is rank 0 and serves the API.
  node0 is reached by the ssh alias `node0` (created in phase 03; before that, by its LAN IP or 10.40.0.1).
- Every setup script is **check-first and idempotent**: it reports what is already done, does what it can
  unprivileged, and prints the exact remaining commands. Re-running a finished phase is a safe no-op.
  Exit codes: `0` = nothing to do / done, `2` = actions remain (read the `[DO]` lines), `1` = error.
- **Privileged steps** (apt, grub, netplan, fwupd, reboots): if `sudo -n true` works, the scripts run them;
  otherwise they print the exact commands. Run those through the terminal with the user's approval, or hand
  them to the user. NEVER type or store passwords; never guess credentials.
- **Reboots and BIOS updates need explicit user confirmation** — they interrupt everything, and a pair
  mid-setup may lose its link. Say what will happen and wait for a yes.
- The user's own LLM backend may be one of the GPU consumers you must stop before serving (phase 09 says
  how). Warn the user before stopping anything that serves their agent — the session can go silent.
- Do not modify the read-only deployment (`~/tfp/deploy/<commit>`) except the documented ds-kit RoPE
  extension (README "1M-token window"), and never edit upstream source to work around a problem.

## The setup sequence

Run `bash scripts/setup/00-preflight.sh` first. It audits BOTH boxes and prints a gap list. Then work the
phases in order, re-running preflight after each; a phase whose checks are all `[ok]` is skipped.

| phase | script | what it does | needs |
|---|---|---|---|
| 00 | `00-preflight.sh` | audit both boxes, gap list | read-only |
| 01 | `01-firmware.sh` | BIOS ≥ 3.06 via fwupd | sudo, reboot, user OK |
| 02 | `02-kernel.sh` | GRUB: `amdgpu.gttsize=126976 ttm.pages_limit=32505856 amd_iommu=pt` | sudo, reboot |
| 03 | `03-network.sh` | USB4 IPs (netplan or nmcli), ssh alias `node0`, render/video groups | sudo, cables plugged |
| 04 | `04-rocm.sh` | AMD ubuntu2604 repo, gfx1151-only ROCm 10.1, ldconfig registration | sudo |
| 05 | `05-toolchain.sh` | python3.13 (uv or deadsnakes), zig 0.17.0, clone, both venvs | internet |
| 06 | `06-build.sh` | Triton AOT kit (280 variants), zig build, GPU tests | ~30–60 min CPU |
| 07 | `07-models.sh` | pinned downloads (~400 GB) + rsync to node0 | disk: 620 GB node1 / 510 GB node0 |
| 08 | `08-inputs.sh` | prepare inputs (`ROWS=1048576` for 1M), verify rank 1, deploy both, verify rank 0 | ~1 TB reads; ~15 min checks |
| 09 | `09-serve.sh` | my.conf on both boxes, staggered start, health + probe | free memory (see below) |

Phases 01–04 run on BOTH boxes (the scripts say which commands go where; run node0's over ssh).
Phases 05–09 run on node1 and drive node0 over ssh.

## Serving and the load wedge (read before phase 09)

- A rank starts only with `MemAvailable >= PEAK_GIB + 8` and no other engine on its box. Stop other GPU
  consumers first (another inference server, a GPU container). `scripts/start-serve.sh` refuses to start
  while the `halogen-flash-server` podman container runs on node0.
- On stock Ubuntu kernels (7.3.x observed) the weight load intermittently wedges ~3 GiB in: rank 1 spins in
  libhsa `BusyWaitSignal`, GPU idle, kernel `svm_range_restore_work` livelock; rank 0 dies `PeerNeverLinked`,
  rank 1's log empty. **After a wedge-kill, instant retries re-wedge; loads ≥150 s later are clean.**
  `scripts/start-serve.sh` already implements staggered boot + stall detection + 150 s cooldown retry.
  Do not hammer `first_light.sh up` in a loop — use the script, or wait out the cooldown manually.
- Rank 1 retries its peer connect for ~2 minutes after loading: once rank 1 is loaded, start rank 0 promptly.

## Verification gates (do not declare success without these)

1. preflight: no `[GAP]` lines for the phases you claim done.
2. build: `Build Summary: N/N steps succeeded`; `run_gpu_tests.sh` smoke/ABI/glue exit 0.
3. inputs: both `verify-rank{0,1}` reports `status: pass`.
4. serve: `/health` answers with the configured model name; a probe chat completion names Paris;
   `/v1/models` lists the alias. `make health models probe` from this repo.
5. Report the real numbers (`make bench` or `serve-rank0.sh bench`), never invented ones.

## Day-2 operations

`make help` in this repo: start/stop/restart/status/show/logs/health/models/probe/conf/sync-conf/bench/
halogen-stop/halogen-up. Configuration lives in `~/tfp/run/conf/my.conf`, identical on both boxes
(`make sync-conf` after any edit). README.md is the full runbook: port/alias/context changes, the 1M RoPE
extension and rollback, artifact inventory, benchmarking.

## Style of work

- Audit before acting; one batched read-only probe beats ten guesses.
- Long jobs (downloads, kit build, input prep): run in the background, poll, and rsync to node0
  incrementally while the download runs (07-models.sh does this).
- When something fails, capture the actual log line and the kernel log (`journalctl -k`) before theorizing.
  Small-sample correlations lie: this repo's wedge history has several plausible-looking false causes.
- Keep the user informed at phase boundaries; ask before reboots, before stopping their services, and
  before anything that spends money or deletes data.