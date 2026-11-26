# Measurements

All numbers on one machine, one session, one card: AMD RX 6800 XT 16 GB (RDNA2, `gfx1030`), Ryzen 5
5600X, 31 GB RAM, Mesa RADV 26.3.1, Vulkan 1.4. The card reports `warp size: 32`, `int dot: 1`,
`matrix cores: none`, so every kernel runs without tensor cores.

## Models

`prism-ml/Ternary-Bonsai-2.5-27B-GGUF`, Apache 2.0, base Qwen3.8-27B, architecture string `qwen35`,
262K context, hybrid attention (about 75% linear layers), ternary weights with one FP16 scale per 128
values in a blockwise Sylvester-Walsh-Hadamard basis. Packs:

| pack | size | decode kernels on Vulkan |
|---|---:|---|
| `Q2_0` | 7.14 GiB | stock matrix-matrix (`matmul_q2_0_q8_1`) plus matvec |
| `PQ2_0` | 6.74 GiB | matvec plus dequant |
| `PTQ1_0` | 5.57 GiB | matvec only (`mul_mat_vec_ptq1_0`) |

Each pack also ships an `-mtp` variant with a multi-token prediction draft head.

## Stock llama.cpp b12669

| run | prefill 512 | decode | note |
|---|---:|---:|---|
| Vulkan, `-ngl 99` | 132 | 3.42 | GPU 99% busy during decode |
| CPU, `-ngl 0` | 264 | 4.92 | faster than its own Vulkan path |

The GPU is the slower path, which is the signature of the missing transform: the dense matmul for each
FWHT is compute work, so bandwidth is wasted. Effective traffic during decode is about 24 GB/s on a card
that sustains several hundred.

Root cause, from the source tree:

- `ggml/src/ggml-cpu/ggml-cpu.c` dispatches a `mul_mat` with `GGML_HINT_SRC0_IS_HADAMARD` to
  `ggml_compute_forward_fwht`.
- `ggml/src/ggml-cpu/ops.cpp` and `ggml/src/ggml-hexagon/htp/unary-ops.c` carry the implementations.
- `ggml/src/ggml-vulkan/` in b12669 has no reference to the hint.

## Prism fork f702476

The fork adds `ggml_vk_can_use_fwht`, `pipeline_fwht_f32` and `pipeline_fwht_f16` with a signed fused
variant, plus the ternary matvec kernels. Built with `-DGGML_VULKAN=ON` (recipe and gotchas in
[BUILD.md](BUILD.md)).

| pack | run | prefill 512 | prefill 2048 | decode | decode @8K depth |
|---|---|---:|---:|---:|---:|
| Q2_0 | llama-bench | 500.81 | 488.84 | 44.81 | 42.45 |
| PQ2_0 | llama-bench | 409.44 | 405.94 | 47.16 | - |
| PTQ1_0 | llama-bench | 217.01 | 214.75 | 50.67 | 46.75 |
| PTQ1_0-mtp | llama-cli, no drafts | - | - | 50.4 | - |
| PTQ1_0-mtp | llama-cli, MTP `n-max 2` | - | - | 72.4 | - |
| Q2_0-mtp | llama-cli, no drafts | - | - | 43.6 | - |
| Q2_0-mtp | llama-cli, MTP `n-max 2` | - | - | 66.2 | - |
| PQ2_0-mtp | llama-cli, MTP `n-max 2` | - | - | 68.7 | - |

`llama-bench` with `-p 512 -n 128 -r 3`; `llama-cli` with 128 generated tokens, greedy, `-fa on`,
`-c 8192`, the same code prompt ("Write a Python function that merges two sorted lists, with a docstring
and type hints"). Prose prompt with the same settings on PTQ1_0: 65.6 tok/s with MTP `n-max 2`.

## MTP sweep (PTQ1_0-mtp, code prompt)

| `--spec-draft-n-max` | p-min | decode tok/s |
|---:|---:|---:|
| 1 | 0 | 67.5 |
| 2 | 0 | 72.3 / 69.5 (two runs) |
| 2 | 0.1 | 71.8 |
| 3 | 0.1 | 57.1 |
| 4 | 0 | 54.5 |
| 5 | 0 | 48.7 |

Their CUDA presets use three drafts with p-min 0.1. On this card the verify window that pays is two, and
beyond three the drafts cost more than they save.

## Other settings

- KV cache: `-ctk q8_0 -ctv q8_0` gives 41.8 tok/s against 72.4 with f16. Keep f16 on this backend.
- Flash attention: 50.3 tok/s with `-fa on`, 49.5 with `-fa off`, plain decode. Noise.
- Depth: PTQ1_0 loses 8% decoding at 8K depth (50.7 to 46.8); Q2_0 loses 5% (44.8 to 42.5).
- Build cost: the fork takes about 2 minutes to build on 7 threads once the headers are present.

## What was not measured

- Quality, perplexity or the reported agentic scores.
- Context lengths beyond 8K, where the hybrid attention should hold up well but was not exercised.
- CUDA or ROCm paths; this card has no working HIP runtime here.

## Caveats

The `llama-cli` rows include prompt processing of a roughly 20-token prompt, so they are not identical
to `llama-bench`'s `tg128`, which decodes from an empty context. Rows are from one session; treat
differences under 5% as noise, and the MTP sweep as the reliable part (it is a 20-point spread).
