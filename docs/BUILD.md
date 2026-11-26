# Building Prism's llama.cpp fork with the Vulkan backend

Verified at `f702476` (2026-11-25) on Linux with Mesa RADV 26.3.1. The fork carries the Hadamard and
ternary kernels that upstream llama.cpp does not have on Vulkan yet.

## Prerequisites

- `git`, `cmake` 3.24 or newer, `ninja`, a C++17 compiler.
- Vulkan headers. Distro packages often skip them; the script clones `KhronosGroup/Vulkan-Headers`
  into a temporary directory when `/usr/include/vulkan/vulkan.h` is missing.
- SPIRV-Headers. The fork's Vulkan code includes `spirv/unified1/spirv.hpp`, which upstream did not
  need. The script builds and installs them under `/tmp` and passes the include path explicitly.

## Script

```sh
bench/build-prism-vulkan.sh f702476            # builds into ./.prism-llama by default
bench/build-prism-vulkan.sh main ~/llama-prism # any ref, any prefix
```

The script clones the fork, provisions the headers, configures with
`-DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF -DLLAMA_BUILD_IS_DEV=OFF
-DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_BUILD_TESTS=OFF`, then builds `llama-bench` and
`llama-cli`. About two minutes on 7 threads.

## Gotchas, in the order they bite

**The UI asset target fails the build.** `tools/ui/CMakeLists.txt` declares `llama-ui-assets` as an
`ALL` target. Provisioning downloads a partial bundle from the project's Hugging Face bucket and then
`ui_validate_assets` aborts with `bundle[hash].js ... missing`. Builds of `llama-bench` and `llama-cli`
inherit the dependency through `common`.

Workaround, used by the script: create placeholder `index.html`, `manifest.webmanifest`, `sw.js`,
`build.json`, `version.json`, `bundle.js`, `bundle.css` and `workbox.js` inside `<build>/tools/ui/dist`
before the build. The UI is unused by the CLI tools; `llama-server` embeds the placeholders and serves a
blank page, which is harmless for benchmarking.

**SPIRV headers are required.** Without them the build stops at
`ggml-vulkan-types.h:47: spirv/unified1/spirv.hpp: No such file or directory`. Add
`-DCMAKE_CXX_FLAGS=-I<prefix>/include` where `<prefix>` is the SPIRV-Headers install.

**Build targets, not `ALL`.** `cmake --build build` builds the server and the UI as well, which is
slower and needs the placeholder assets. Ask for the targets you need:
`cmake --build build --target llama-bench llama-cli`.

**Shared libraries.** With `BUILD_SHARED_LIBS=ON` (the default for a standalone build) the binaries need
`LD_LIBRARY_PATH=<build>/bin`. An install step strips RUNPATH, so the same applies to an installed copy.

## Verifying the build

```sh
LD_LIBRARY_PATH=<build>/bin <build>/bin/llama-bench \
  -m Ternary-Bonsai-2.5-27B-Q2_0.gguf -ngl 99 -p 512 -n 128 -r 3
```

On a card without good Vulkan kernels for this model, decode lands near 3.4 tokens/s; with the fork's
FWHT path it lands near 45 for `Q2_0` and 51 for `PTQ1_0`. If you see the low number, the hint is being
executed as a dense matmul, which usually means the binary is stock llama.cpp rather than this fork.

## What the fork changes for this model

- `ggml_vk_can_use_fwht` and the `pipeline_fwht_f32`/`pipeline_fwht_f16` pipelines, plus a fused signed
  variant, so `GGML_HINT_SRC0_IS_HADAMARD` runs as a fast transform instead of a matrix multiply.
- `mul_mat_vec_ptq1_0`, `mul_mat_vecq_ptq1_0` and the `pq2_0` dequant path, so the 1.76-bit and 2.13-bit
  packs decode at memory speed.
- Neither type has a matrix-matrix kernel yet on Vulkan, which is why `PTQ1_0` prefills at half the rate
  of `Q2_0`. See the note in the top-level README.
