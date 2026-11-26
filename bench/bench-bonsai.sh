#!/usr/bin/env bash
# Benchmark a Ternary Bonsai pack with a Vulkan llama.cpp build.
#
# Usage: bench-bonsai.sh <model.gguf> [llama-bench] [logdir]
#   model.gguf    e.g. Ternary-Bonsai-2.5-27B-Q2_0.gguf (or the -mtp variant)
#   llama-bench   default: llama-bench from PATH
#   logdir        default: ./logs
#
# Runs prefill at 512 and 2048 tokens, decode from an empty context, and decode at 8K depth. Prints a
# summary and keeps the raw output, because `llama-bench` prints its table at the end and piping it
# through `grep` has produced empty output in practice.
#
# For MTP, use llama-cli with the draft flags; llama-bench has no speculative path:
#   llama-cli -m <pack>-mtp.gguf -ngl 99 -fa on -c 8192 -n 128 --temp 0 \
#     --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0 -p "your prompt"
set -euo pipefail

MODEL=${1:?usage: $0 <model.gguf> [llama-bench] [logdir]}
BENCH=${2:-llama-bench}
LOG=${3:-./logs}
mkdir -p "$LOG"
BASE=$(basename "$MODEL" .gguf)

run() {
  local tag=$1; shift
  "$BENCH" -m "$MODEL" -ngl 99 "$@" > "$LOG/$BASE-$tag.log" 2>&1 || {
    echo "failed: see $LOG/$BASE-$tag.log" >&2; return 1; }
}

# First run after a load is cold: shaders compile and the page cache fills. Discard it.
run warmup -p 128 -n 8 -r 1
run p512  -p 512  -n 128 -r 3
run p2048 -p 2048 -n 64  -r 2
run d8k   -p 0    -n 64  -d 8192 -r 1

echo "== $BASE"
for tag in p512 p2048 d8k; do
  [ -f "$LOG/$BASE-$tag.log" ] || continue
  grep -hE 'pp512|pp2048|tg128|tg64' "$LOG/$BASE-$tag.log" | sed -E 's/^\| *//; s/ *\| */ | /g'
done
