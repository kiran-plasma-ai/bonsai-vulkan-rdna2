#!/usr/bin/env bash
# Build Prism's llama.cpp fork with the Vulkan backend.
#
# Usage: build-prism-vulkan.sh <ref> [prefix]
#   ref     branch, tag or commit of https://github.com/PrismML-Eng/llama.cpp, e.g. f702476
#   prefix  install prefix, default <cwd>/.prism-llama
#
# Why this fork: it carries the Fast Walsh-Hadamard transform and the ternary matvec kernels for
# Vulkan. Stock llama.cpp runs a Bonsai file at about 3 tok/s because the transform falls back to a
# dense matrix multiply. See docs/BUILD.md for the details and the build gotchas this script handles.
#
# Requirements: git, cmake 3.24+, ninja, a C++17 compiler. Vulkan and SPIRV headers are fetched into
# temporary directories when the system has none.
set -euo pipefail

REF=${1:?usage: $0 <ref> [prefix]}
PREFIX=${2:-$(pwd)/.prism-llama}
JOBS=${JOBS:-$(nproc)}
WORK=${WORK:-/tmp/prism-llama-build-$REF}

if [ ! -f /usr/include/vulkan/vulkan.h ] && [ ! -f /tmp/Vulkan-Headers/include/vulkan/vulkan.h ]; then
  git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Headers /tmp/Vulkan-Headers
fi
VULKAN_INCLUDE=/usr/include
[ -f /usr/include/vulkan/vulkan.h ] || VULKAN_INCLUDE=/tmp/Vulkan-Headers/include

SPIRV_PREFIX=/usr
if [ ! -f /usr/include/spirv/unified1/spirv.hpp ]; then
  SPIRV_PREFIX=/tmp/spirv-headers-install
  if [ ! -f "$SPIRV_PREFIX/include/spirv/unified1/spirv.hpp" ]; then
    rm -rf /tmp/SPIRV-Headers
    git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers /tmp/SPIRV-Headers
    cmake -S /tmp/SPIRV-Headers -B /tmp/SPIRV-Headers/build -DCMAKE_INSTALL_PREFIX="$SPIRV_PREFIX" >/dev/null
    cmake --install /tmp/SPIRV-Headers/build >/dev/null
  fi
fi

rm -rf "$WORK"
git clone --depth 1 --branch "$REF" https://github.com/PrismML-Eng/llama.cpp "$WORK"

cmake -S "$WORK" -B "$WORK/build" -G Ninja \
  -DGGML_VULKAN=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_CURL=OFF \
  -DLLAMA_BUILD_IS_DEV=OFF \
  -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_UI=OFF \
  -DLLAMA_BUILD_HTML=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DVulkan_INCLUDE_DIR="$VULKAN_INCLUDE" \
  -DCMAKE_CXX_FLAGS="-I$SPIRV_PREFIX/include" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX"

# tools/ui declares llama-ui-assets as an ALL target, and its validator aborts when the downloaded
# bundle is incomplete. The CLI tools do not need a real UI; placeholder files satisfy the check.
DIST="$WORK/build/tools/ui/dist"
mkdir -p "$DIST"
for f in index.html manifest.webmanifest sw.js build.json version.json bundle.js bundle.css workbox.js; do
  [ -f "$DIST/$f" ] || printf 'placeholder\n' > "$DIST/$f"
done

cmake --build "$WORK/build" -j"$JOBS" --target llama-bench llama-cli
cmake --install "$WORK/build" >/dev/null

echo "built $REF into $PREFIX"
echo "run with: LD_LIBRARY_PATH=$PREFIX/bin $PREFIX/bin/llama-bench -m <model.gguf> -ngl 99 -p 512 -n 128"
