#!/usr/bin/env bash
# Re-grade a captured patch on a pristine image, using the benchmark's own PatchReplayAgent.
#
# Usage: swebench-regrade.sh <tasks-dir> <task-id> <patch-file> <job-name>
#   tasks-dir  directory holding the task (v2/tasks or a policy copy like local-tasks)
#   task-id    the instance directory name
#   patch-file a unified diff, for example a deadline snapshot
#   job-name   harbor job name for the verdict (written under ./jobs)
#
# Why: the protocol's authoritative score is the patch replayed on a clean container, not the grade
# inside the agent's own sandbox. This also lets you grade a snapshot taken mid-run, which is what makes
# "resolved at the deadline" comparable to "resolved when allowed to finish".
set -euo pipefail
TASKS=${1:?usage: $0 <tasks-dir> <task-id> <patch-file> <job-name>}
ID=${2:?task id}
PATCH=${3:?patch file}
JOB=${4:?job name}
SRC=$(mktemp -d /tmp/regrade-XXXXXX)/instance_$ID
mkdir -p "$SRC/agent"
printf '{"task_name": "%s"}\n' "$ID" > "$SRC/result.json"
cp "$PATCH" "$SRC/agent/model.patch"

PYTHONPATH=v2/tooling harbor run -p "$TASKS" -i "$ID" -e docker -n 1 \
  -a patch_replay:PatchReplayAgent -m replay \
  --ak "source_job=$(dirname "$SRC")" \
  --job-name "$JOB" --yes
