# How the 1M-token window fits in 128 GB — and what uses the SSD

Clarification for the pair's `CONTEXT=1048576` configuration. Short version: the SSD is used, but
not as swap for the KV cache. The disk-resident part is the Engram tables; the 1M window itself fits
in unified memory because the per-position KV is tiny.

## Memory budget at 1M, per rank (measured)

| item | size | source |
|---|---|---|
| weights in GTT | ~99 GiB | `tools/dsv41-hip/RESULTS.md`: 98.79 GiB after load, unchanged while serving |
| arena (pool + working buffers) | ~4.84 GiB used / 4.93 GiB reserved | `~/tfp/run/serve/latest/rank1.log`: `arena_used` 5,199,763,920 B, `arena_reserved` 5,289,019,648 B at `pool=context=1048576` |
| host / other | ~2–3 GiB | — |
| **total** | **~104 GiB** | `PEAK_GIB=107`, start gate `MemAvailable >= 115 GiB` |

## Why the KV pool is small

This is a compressed-latent attention model. `config.json` has `head_dim=512` and
`qk_rope_head_dim=64` — 576 values per position, stored compactly (fp8 + scales), which is the
"~0.9 KB a position a rank" in `serve.conf`'s `POOL` comment. At 1,048,576 positions that is
**~0.9 GiB of pool per rank**. The rest of the 4.84 GiB arena is working buffers (prefill split,
drafts, collectives staging).

Attention is sparse: `index_topk=512`, `candidate_blocks=2048`, so each query scores a 512-key
subset of the pool rather than all 1M. That keeps compute flat and means no per-position index
cache is kept.

## What actually lives on the SSD

| artifact | size | path |
|---|---|---|
| Engram shards | 203 GB | `~/models/tf-port/ds1017-1bae0e10` |
| checkpoint | 197 GB | `~/models/tf-port/libertai-2.9bpw` (prepare-time only) |
| rank caches | 106 GB each, per box | `~/models/tf-port/inputs-tp2-c178a012/rank{0,1}/rank-cache` (loaded into GTT at startup) |

Engram is a giant lookup table: each row is 100 bytes of weight + 3 bytes of scale
(`engram_aio.zig`'s test fixture shows shape `[rows,100]` U8 + `[rows,3]` U8). At serve time each
token's Engram lookup reads its rows by offset — one pread per row on a thread pool
(`engram_io.zig`: "Engram rows from the original FP8 tables on local NVMe ... one pread each on a
pool of threads, so a step's random rows cost about one latency"). With `ENGRAM_AIO=1` it switches
to Linux AIO with `O_DIRECT`, bypassing the page cache; the conf ships `ENGRAM_AIO=0`, so the
default is buffered preads and hot rows can sit in page cache.

The checkpoint and rank caches are disk artifacts too, but they are not read during serving: the
rank cache is what gets loaded into GTT at startup, and the checkpoint is only used by
`prepare_inputs.sh` to build it.

## What does not happen

Nothing pages the KV cache to disk. There is no swap knob in `my.conf`, and the pool lives in the
device arena (GTT). The 1M window fits because 1M positions cost under a gigabyte of pool, not
because anything is spilled to SSD.
