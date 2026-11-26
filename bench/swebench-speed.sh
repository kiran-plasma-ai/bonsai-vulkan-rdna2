#!/usr/bin/env bash
# Measure model throughput for a benchmark run from llama-server's Prometheus counters.
#
# Usage:
#   swebench-speed.sh snapshot /tmp/before.txt
#   ... run the benchmark ...
#   swebench-speed.sh snapshot /tmp/after.txt
#   swebench-speed.sh report /tmp/before.txt /tmp/after.txt
#
# The counters are cumulative, so the report is the exact average over the window: prompt tokens over
# prompt seconds gives prefill tok/s, predicted tokens over predicted seconds gives decode tok/s, and
# cached prompt tokens show how much of the work was KV reuse rather than fresh prefill.
#
# The server needs --metrics. Port defaults to 8884, override with PORT.
set -euo pipefail
PORT=${PORT:-8884}
URL=http://127.0.0.1:$PORT/metrics

get() { grep -E "^llamacpp:$2 " "$1" 2>/dev/null | awk '{print $2}' | head -1; }

case ${1:?usage: $0 snapshot <file> | report <before> <after>} in
  snapshot)
    curl -sf "$URL" > "$2"
    echo "snapshot written to $2"
    ;;
  report)
    B=${2:?before snapshot}; A=${3:?after snapshot}
    pt=$(get "$A" prompt_tokens_total);  pt0=$(get "$B" prompt_tokens_total)
    ps=$(get "$A" prompt_seconds_total); ps0=$(get "$B" prompt_seconds_total)
    ct=$(get "$A" prompt_tokens_cached_total); ct0=$(get "$B" prompt_tokens_cached_total)
    gt=$(get "$A" tokens_predicted_total); gt0=$(get "$B" tokens_predicted_total)
    gs=$(get "$A" tokens_predicted_seconds_total); gs0=$(get "$B" tokens_predicted_seconds_total)
    awk -v pt="$pt" -v pt0="$pt0" -v ps="$ps" -v ps0="$ps0" -v ct="$ct" -v ct0="$ct0" \
        -v gt="$gt" -v gt0="$gt0" -v gs="$gs" -v gs0="$gs0" 'BEGIN {
      dpt=pt-pt0; dps=ps-ps0; dct=ct-ct0; dgt=gt-gt0; dgs=gs-gs0;
      printf "prompt tokens   %10d   (cached %d, %.0f%%)\n", dpt+dct, dct, (dpt+dct>0 ? 100*dct/(dpt+dct) : 0);
      printf "prefill         %10.0f tok/s  over %.1f s of compute\n", (dps>0 ? dpt/dps : 0), dps;
      printf "generated       %10d\n", dgt;
      printf "decode          %10.1f tok/s  over %.1f s of compute\n", (dgs>0 ? dgt/dgs : 0), dgs;
      printf "total compute   %10.1f s\n", dps+dgs;
    }'
    ;;
  *) echo "usage: $0 snapshot <file> | report <before> <after>" >&2; exit 2 ;;
esac
