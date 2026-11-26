# Which agentic benchmark is worth running here

Short answer: **SWE-Bench Pro V2**, specifically its HARD-51 split, under the locked protocol with the
mini-swe-agent scaffold. It is the newest hardened benchmark built from real pull requests, and it is the
only one where a model of our class has a published number on the same harness.

## Why this one

- **Real work, not synthetic tasks.** 642 tasks from 11 actively maintained repositories (Python, Go,
  JavaScript, TypeScript). Each task ships a human-written specification (problem statement, requirements,
  new interfaces), a container at the base commit, hidden tests, and a reference patch. Changes are
  long-horizon and multi-file, which is the shape of real issue work.
- **Audited as of November 2026.** The V2 paper reports repairing or retiring 480 of 731 tasks: 23
  engineers, 404 hours, blind re-implementation of every instruction repair, and a hardened verifier for
  all tasks. It exists because agents started reaching defects that weaker models never hit.
- **Hard to game.** The agent phase is offline except for the model endpoint, git history is scrubbed, and
  every patch is re-graded on a pristine image, because agents forged module caches and binaries outside
  the patch.
- **A reference point for our hardware class.** The paper's table runs Inkling (xhigh) with
  mini-swe-agent at **89.9% on the full set and 56.9% on HARD-51**. We can run the same scaffold against a
  local endpoint, so a score here is comparable to something published rather than free-floating.
- **A Hard split that still separates.** Frontier systems solve about 99% of the full set, but HARD-51
  spreads systems from 52.9% to 98.0%. On the full set a 2-bit model's failures would mostly be noise; on
  Hard they are the signal.

## Why the alternatives are worse for this decision

| suite | problem for our purpose |
|---|---|
| SWE-bench Verified | saturated, and an OpenAI audit found task defects plus contamination; the V2 paper cites roughly 30% broken tasks in SWE-Bench Pro v1 as the reason for its rework |
| Terminal-Bench 2.0 | measures terminal work broadly, so a failure can be tooling rather than code understanding |
| DeepSWE | 113 original long-horizon tasks, genuinely hard, but no published number for a model like ours, so our result would have no anchor |
| τ-bench 2.0 | tool-use policy adherence, not repo-scale coding; good for API behaviour, not for "can it fix my issue" |
| Aider polyglot | narrow edit-this-file exercises, far from multi-file work |
| Pi agent, 20 issues | the number in the model announcement; the harness is not published, so it cannot be reproduced |

## What a run costs on this card

Harbor enforces a 50-minute budget per task. Our measured throughput is about 480 tok/s prefill and 74
tok/s decode, with a 64K context. Expect 20 to 40 minutes per HARD-51 task once retries and test runs are
included.

| scope | wall time | useful for |
|---|---|---|
| 5 tasks, pilot | 2 to 3 h | proving the wiring, the endpoint allowlist, and the re-grade step |
| HARD-51 | 17 to 34 h | a score comparable to the published Inkling row |
| full 642 | 2 to 3 weeks | nothing we need; the full set is near saturation anyway |

Two packs can be compared on the same 5 tasks first: `Q2_0-mtp` (489 prefill, 66 decode) against
`PTQ1_0-mtp` (217 prefill, 72 decode). Long-horizon tasks spend most of their time prefilling, so `Q2_0`
is the likely winner, and the pilot answers that in an afternoon instead of an opinion.

## Wiring

The harness is `scaleapi/SWE-bench_Pro-os`, tasks are Harbor directories under `v2/tasks/`, and the
locked mini-swe-agent agent takes any OpenAI-compatible endpoint:

```sh
uv tool install 'harbor[modal]>=0.22'       # Modal path, needs an account and token
git clone https://github.com/scaleapi/SWE-bench_Pro-os

PYTHONPATH=v2/tooling harbor run -p v2/tasks \
  $(sed 's/^/-i /' v2/hard51_ids.txt | head -5) \
  -e docker -n 1 \
  -a locked_mini_swe:LockedMiniSwe \
  -m openai/bonsai-2.5-27b \
  --ak config_file=v2/tooling/configs/mini_toolcall.yaml \
  --ae OPENAI_API_BASE=http://<host-address>:8884/v1 \
  --ae OPENAI_API_KEY=dummy \
  --allow-agent-host <host-address> \
  --job-name bonsai-q2-hard5
```

Then re-grade, which is the number to report:

```sh
PYTHONPATH=v2/tooling harbor run -p v2/tasks -e docker -n 1 \
  -a patch_replay:PatchReplayAgent -m replay \
  --ak source_job=jobs/bonsai-q2-hard5 --job-name bonsai-q2-hard5-regrade
```

Notes from reading their docs, before anything is installed here:

- `-e modal` is the supported executor and gives per-phase network policy. The local Docker executor is
  beta, and the Docker daemon is not running on this machine; starting it needs root once.
- Containers must reach the model endpoint. On Docker that means binding llama-server on a bridge-reachable
  address for the run, and passing it as `OPENAI_API_BASE` plus `--allow-agent-host`.
- The agent phase has no network, so the model cannot fetch anything; our server must be the only reachable
  host, which also means the 64K context is the real limit for long tasks.
- Prompts from the tasks are large. The pilot exists to find whether 64K truncates, and if it does, whether
  `-c 131072` fits with `Q2_0` (7.14 GiB of weights leaves room, unlike the Inkling case).

## What to record per run

Resolved tasks after re-grade, task ids, wall time per task, peak context, and whether any request hit the
64K limit. A truncated trajectory scores as a failure and would be read as a capability gap. Also record
the pack and draft setting, since a 30% decode difference changes how many tasks fit in a day.

## Smaller alternatives worth keeping

- τ-bench airline, five tasks: a ten-minute smoke test that the tool-call surface works. Good for checking a
  new endpoint, useless as a capability score.
- Terminal-Bench 2.0, five tasks: broad terminal agency, useful when the question is "can it run commands
  and recover", not "can it fix an issue".

## Running it

Three things that are not obvious from the upstream docs and cost time to discover:

- The model endpoint must be reachable from the task's sandbox network, not just from the host. Harbor
  puts each task on its own compose network, so point the agent at a host address that network can route
  to and allowlist it with `--allow-agent-host`.
- Harbor's docker executor builds an egress-control sidecar and needs the `docker buildx` CLI plugin.
  Without it the trial dies in about two seconds with `unknown flag: --file`.
- Harbor's Docker egress sidecar can cut long streaming responses against a local endpoint, roughly
  12 seconds and 650 tokens into each call, which surfaces as `litellm ... Connection error` and a
  trajectory with no patch. Running a copy of the task with an all-public network policy removes the
  sidecar. That also removes the sandbox's network isolation, so audit the trajectory for fetches if you
  care about cheating; every scored trajectory here is checked for it.
- Bonsai's chat template accepts `reasoning_effort` values `xhigh` (its default), `medium` and `low`. The
  harness sends `high` by default, which the template rejects with a Jinja exception surfaced as
  `InternalServerError` and retried indefinitely. Pass `--effort medium`. The symptom is a running agent,
  a healthy container and an idle GPU.

For speed, start the server with `--metrics` and bracket the run with `bench/swebench-speed.sh`. Agent
loops reuse the conversation prefix, so in a mid-run window 33,735 of 33,739 prompt tokens came from the
KV cache: a fresh-prefill number would misrepresent the run.

## Budget: report the deadline, do not stop at it

The protocol scores the patch present at the 50-minute deadline. On a consumer card at roughly 60 tok/s
that clock measures our hardware more than the model, so the useful run keeps going.

Run with `--agent-timeout-multiplier 4` and take a snapshot at the 50-minute mark with
`bench/swebench-snapshot.sh <container> deadline.patch`. Grade both patches: the deadline one tells you
what the benchmark's own rule would have scored, and the final one tells you whether the model eventually
finishes the task. Report them as two lines, never merged:

| | meaning |
|---|---|
| resolved at deadline | comparable to published V2 numbers |
| resolved when allowed to finish | capability on this hardware, not comparable |
| wall time and tokens to finish | the real cost of the task on this card |

Measured on the first HARD-51 task here, `medium` effort: 18 turns, about 5,800 generated tokens per
turn, 59.7 tok/s decode, and still reading when the 50 minutes ran out, with no patch written.
