# Agentic coding on one card: Bonsai on SWE-bench Pro

One HARD-51 task from SWE-bench Pro, run end to end on the RX 6800 XT. The point was not to chase a
leaderboard. It was to answer a working question: can this model, served by this stack, finish a real
multi-file change in a sandbox, cheaply enough to use as a delegated coding agent.

Short answer: it completes the task shape and lands 310 of 311 required tests, but the benchmark scores
all or nothing, so the recorded reward is 0. The remaining miss is a detail of the change, not a wall in
the plumbing.

## The task

`instance_NodeBB__NodeBB-8168c6c4` covers account deletion in NodeBB, a JavaScript service. The task ships
311 required tests and asks for a multi-file change under `src/`, including socket handlers and user
deletion paths.

## Setup

| part | value |
|---|---|
| engine | Prism's llama.cpp fork, Vulkan, build `f702476` |
| weights | `Ternary-Bonsai-2.5-27B-Q2_0-mtp.gguf`, 7.14 GiB |
| drafting | MTP, draft max 2, min 0 (measured best on this card) |
| context | 64K with f16 KV in the first attempt, 131072 with q8_0 KV in the second |
| agent | mini-swe-agent-locked 2.4.6, `mini_toolcall` config, `reasoning_effort` medium |
| sandbox | Docker, the task's own image, all-public network policy |

The all-public network policy is not a shortcut. Harbor's egress sidecar cuts long streaming responses
against a local endpoint about 12 seconds in, which kills the run with a connection error and an empty
patch. The workaround and its audit rule are described in [BENCHMARKS.md](BENCHMARKS.md#running-it).

## Context is the first wall

The first attempt ran 64K with f16 KV. Its trajectory crossed 65,682 tokens, the server refused past
65,536, and the run died mid-stream with no patch. Replaying the incomplete patch it had written scored
0 of the required tests, so a truncated run also produces a worthless artifact.

The second attempt moved the same model to 131072 with q8_0 KV. The trajectory that previously died now
completed. On a 16 GB card the cost of that headroom is measurable:

| KV | context | decode | VRAM |
|---|---:|---:|---:|
| f16 | 65536 | 72.4 tok/s | 15.77 GiB |
| q8_0 | 131072 | 52.0 tok/s | 13.69 GiB |

q8_0 at double the context is 28% slower per token and leaves about 2.3 GiB for the card. For agent loops
that reuse the prefix, prompt cache hit rates above 95% keep the slower decode from dominating.

## Result

| metric | value |
|---|---|
| wall time | 24 min 18 s (agent 23 min 26 s, verifier 25 s) |
| patch | 6.4 KiB across five files |
| required tests | 310 of 311 pass |
| missing test | `test/user.js \| User socket methods should clean profile images after account deletion` |
| harness reward | 0.0 (all-or-nothing) |
| tokens | 3.11M input, 2.98M cached, 29.5k output |
| spend | one card, 24 minutes, no API cost |

The patch touched `src/groups/cover.js`, `src/socket.io/user/picture.js`, `src/socket.io/user/profile.js`,
`src/user/delete.js` and `src/user/picture.js`. Deletion cleanup was attempted, in the right file, but one
behaviour was left unimplemented. The agent stopped itself with most of its 200-minute budget unused, so
neither time nor context was the binding constraint. Finishing that detail is a capability question, not a
plumbing one.

## What this implies for delegation

A main agent that hands code work to this endpoint should expect:

- sandboxed tool loops that run for tens of minutes and survive 65k-token trajectories at 128K;
- about 52 to 56 tok/s decode at depth, with prompt caching carrying most of the context;
- a patch that is usually close, and no reliable self-verification. The caller must run the tests and send
  failures back, as the harness did here.

One card serves one request at a time at 128K. Delegation is a queue, not a fan-out.

## Reproduce

The helpers in `bench/` are the same ones used for this run:

```sh
bench/bench-bonsai.sh                      # throughput, plain and with MTP
bench/swebench-speed.sh <job-dir> <job>    # per-token decode while a run is live
bench/swebench-snapshot.sh <container> p   # patch snapshot at the 50-minute mark
bench/swebench-regrade.sh <tasks> <id> <patch> <job>   # authoritative re-grade
```

## Limits

One task, one completed run. Nothing here estimates a general solve rate. The 64K failure is specific to
trajectories above the window, and the 128K configuration is the one to keep for agent work on this card.
