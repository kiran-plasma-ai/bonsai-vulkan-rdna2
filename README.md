# Ternary Bonsai 2.5 on RDNA2: the missing Hadamard kernel

Ternary Bonsai 2.5 27B is a 1.76-bit ternary model whose weights live in a blockwise Hadamard basis.
Stock llama.cpp loads it on Vulkan and answers correctly, at **3.4 tokens/s**. On the same card, with
Prism's fork built for Vulkan, the same file decodes at **44.8 tokens/s**, and its MTP variant reaches
**72.4 tokens/s** on code. This repository records that measurement, the cause, and a build recipe.

Why it matters: the format's Fast Walsh-Hadamard transform is expressed as a `mul_mat` carrying
`GGML_HINT_SRC0_IS_HADAMARD`. llama.cpp implements FWHT for CPU, BLAS and Hexagon only. On Vulkan the
hint is ignored, so the transform runs as a dense matrix multiply, which is 13x slower and pegs the GPU
at 99% while moving only 7 GiB per token.

## Numbers

AMD RX 6800 XT 16 GB (RDNA2, `gfx1030`), Mesa RADV, llama.cpp Vulkan, greedy, one card.

| build | pack (GiB) | prefill 512 | prefill 2048 | decode | + MTP `n-max 2` |
|---|---|---:|---:|---:|---:|
| stock llama.cpp b12669 | Q2_0 (7.14) | 132 | - | 3.42 | n/a |
| Prism fork `f702476` | Q2_0 (7.14) | 500.8 | 488.8 | 44.8 | 66.2 |
| Prism fork `f702476` | PQ2_0 (6.74) | 409.4 | 405.9 | 47.2 | 68.7 |
| Prism fork `f702476` | PTQ1_0 (5.57) | 217.0 | 214.8 | 50.7 | **72.4** |

The stock build is not wrong, only slow: its output is coherent ("The capital of France is" leads to
Paris in the thinking block), all 64 layers are on the GPU, and CPU-only runs at 4.9 tokens/s, which is
*faster* than its own GPU path. Prism's Vulkan backend removes that inversion.

## MTP tuning depends on the card

Their CUDA presets use three drafts. On this card two is best, and the difference is large:

| `--spec-draft-n-max` | 1 | 2 | 3 | 4 | 5 |
|---|---:|---:|---:|---:|---:|
| decode tok/s (PTQ1_0, code) | 67.5 | **72.4** | 57.1 | 54.5 | 48.7 |

Flags: `--spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0`. Prose drafts less (65.6), as
their documentation also says. A quantized KV cache is a trap here: `-ctk q8_0 -ctv q8_0` drops decode
from 72.4 to 41.8. Flash attention on or off is noise (50.3 vs 49.5 plain).

## What is still slow

`PTQ1_0` prefills at 217 tok/s against 489 for `Q2_0`, because the fork ships only matvec kernels for
that type (`mul_mat_vec_ptq1_0`, `mul_mat_vecq_ptq1_0`) while `Q2_0` uses the stock
`matmul_q2_0_q8_1` matrix-matrix path. A matrix-matrix kernel for `PTQ1_0` is the obvious next
contribution: it would put prefill near 490 and keep the 51 tok/s decode. Until then, an agentic
workload that re-reads long prompts is better served by `Q2_0` with MTP (489 prefill, 66 decode).

## Serve it

`systemd/llama-server-bonsai.service` runs `Q2_0-mtp` at 64K context on port 8884 through the fork, with
MTP drafting at `n-max 2`. Measured through the HTTP server on this card: 490 tok/s prefill on a 5.7k
prompt, 74 tok/s decode, 13.5 GiB of VRAM, native tool calls working. A 30.5k-token prompt prefills in
66 s and decodes at 64 tok/s. Configuration, client notes and the settings that do not work are in
[docs/SERVING.md](docs/SERVING.md).

For model comparison, [docs/BENCHMARKS.md](docs/BENCHMARKS.md) surveys the agentic suites that can be
pointed at an OpenAI-compatible endpoint (t-bench text, Terminal-Bench, SWE-bench with mini-swe-agent,
Aider polyglot) with wiring notes and wall-time estimates for this card.

## Reproduce

```sh
# 1. build Prism's fork with the Vulkan backend (see docs/BUILD.md for the gotchas)
bench/build-prism-vulkan.sh f702476 ~/.local/share/llama.cpp-prism

# 2. weights (Apache 2.0), about 5.6 to 7.4 GiB per pack
hf download prism-ml/Ternary-Bonsai-2.5-27B-GGUF Ternary-Bonsai-2.5-27B-Q2_0.gguf --local-dir models

# 3. benchmark
bench/bench-bonsai.sh models/Ternary-Bonsai-2.5-27B-Q2_0.gguf
```

Raw `llama-bench` and `llama-cli` output for every row above is in `bench/logs/`, and the method,
depth behaviour and build timings are in [docs/RESULTS.md](docs/RESULTS.md).

## Scope

This repository measures speed, not quality. The agentic scores reported elsewhere for this model
(16/20 on a 20-task coding benchmark) were not reproduced here; the point of these numbers is that the
format is usable on an AMD Vulkan card once the transform has a kernel, and that stock llama.cpp is not
yet the runtime for it.

Tested with Mesa RADV 26.3.1 on Linux 7.3, Vulkan 1.4, Prism fork `f702476`, and stock llama.cpp
`b12669` built with `GGML_VULKAN=ON`. No ROCm, no HIP, and no NVIDIA driver involved.
