#!/usr/bin/env bash
# Snapshot the patch an agent has produced so far, from a trial that is still running.
#
# Usage: swebench-snapshot.sh <container> <out.patch>
#   container  the task container, e.g. instance_<name>__<suffix>__env-main-1
#   out.patch  where to write the diff on the host
#
# Why: the protocol scores the patch present at the 50-minute deadline, but a slow consumer GPU should
# not be stopped there. Run with a larger agent timeout, snapshot at the 50-minute mark, and keep going.
# Then report two numbers: what the agent had at the deadline, and what it finished with. Grading the
# deadline patch separately is what makes the comparison honest.
#
# The container is left untouched: the diff is staged, written to /tmp inside, then unstaged again.
set -euo pipefail
C=${1:?usage: $0 <container> <out.patch>}
OUT=${2:?usage: $0 <container> <out.patch>}

docker exec "$C" sh -c '
  repo=$(git -C /app rev-parse --show-toplevel 2>/dev/null || git -C /testbed rev-parse --show-toplevel 2>/dev/null || echo /app)
  cd "$repo" || exit 1
  git add -A >/dev/null 2>&1
  git diff --cached > /tmp/snapshot.patch 2>/dev/null
  git reset -q >/dev/null 2>&1
  wc -c < /tmp/snapshot.patch
' | tail -1 | xargs -I{} echo "patch bytes inside container: {}"

docker cp "$C":/tmp/snapshot.patch "$OUT"
ls -l "$OUT"
