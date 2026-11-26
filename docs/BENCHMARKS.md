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

## Running it on this machine: what actually had to be fixed

Verified while piloting one HARD-51 task, 2026-11-26. None of this is in the upstream docs.

**Reaching the model from the sandbox.** Harbor gives every task its own Docker compose network
(`172.20.0.0/16` here), which the host firewall drops on the way in. The model also binds loopback only.

The working shape: a `socat` relay on the docker gateway (`172.17.0.1:8884` to `127.0.0.1:8884`) plus
one ufw rule covering all Docker subnets,
`sudo ufw allow from 172.16.0.0/12 to 172.17.0.1 port 8884 proto tcp`. Nothing is exposed on the LAN.
Then pass `--ae OPENAI_API_BASE=http://172.17.0.1:8884/v1 --allow-agent-host 172.17.0.1`.

**Harbor needs the buildx plugin.** Without it the egress sidecar image fails with
`unknown flag: --file`. Drop the `docker-buildx` binary into `~/.docker/cli-plugins/`, no root needed.

**Reasoning effort is a hard failure, not a downgrade.** The harness sends `reasoning_effort: high` by
default. Bonsai's template accepts only `xhigh` (its own default), `medium` and `low`, and renders a
Jinja exception for anything else, which arrives as `InternalServerError` and is retried forever with no
tokens generated. Pass `--effort medium`. Symptom to recognise: container up, agent running, GPU idle.

**Speed is measured from the server, not inferred.** Start it with `--metrics` and bracket the run:
`bench/swebench-speed.sh snapshot before`, run, `snapshot after`, then `report`. Agent loops reuse the
KV prefix, so a mid-run window showed 33,735 of 33,739 prompt tokens served from cache; quoting a fresh
prefill number for such a run would be wrong. Expected decode here is 55 to 75 tok/s.
