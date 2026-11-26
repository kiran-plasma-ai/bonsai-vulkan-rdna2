# Agentic benchmarks we could run against this endpoint

The claim behind this model is an agentic coding score: 16/20 on twenty real GitHub issues fixed with
the Pi agent. That harness is not published with the weights, so the number cannot be reproduced
directly. What can be reproduced is a standard suite run against the local endpoint, which also gives a
comparison to the models already served here (Inkling 2 Mini, and Bonsai at other packs).

The endpoint is OpenAI-compatible at `http://127.0.0.1:8884/v1`, model id `bonsai-2.5-27b`, 64K
context, native tool calls. Measured throughput for the estimates below: about 480 tok/s prefill,
64 to 74 tok/s decode.

## Candidates

| suite | what it measures | harness | extras | estimate on this card |
|---|---|---|---|---|
| τ-bench 2.0, text domains | policy-following tool use against a simulated user | `tau2`, LiteLLM | Python only, no Docker | 1 to 3 min per task; 5-task smoke about 10 min |
| Terminal-Bench 2.0 | multi-step terminal work with a verifier | `tb` or `harbor` | Docker, network | 5 to 15 min per task |
| SWE-bench Verified (sample) | patch a real GitHub issue in a repo | mini-swe-agent plus Docker images | Docker, about 20 GB of images | 10 to 20 min per instance, 20 instances about 4 h |
| Aider polyglot | edit real code in six languages | aider benchmark repo | Docker | 5 to 10 min per exercise, 225 exercises |
| BFCL v4 | function-call syntax and selection | gorilla harness | handler shim for local endpoints | hours, setup heavy |
| Pi agent, 20 issues | the original claim | not published | - | not reproducible |

Scores are not comparable across harnesses or subsets. What is comparable is the same harness run
against two models on this machine, which is the useful experiment here.

## Recommended order

1. **Smoke the endpoint** with five τ-bench airline tasks. It exercises tools, multi-turn state and
   instruction following, and it fails fast when the chat template or tool schema is wrong.
2. **Terminal-Bench, five tasks**, for terminal agency. It is the closest published analogue to harnessed
   issue fixing and it runs in Docker without a per-repo image build.
3. **SWE-bench Verified, 20 instances** sampled from the Verified split, with mini-swe-agent. This is the
   only option on the list that resembles the 16/20 claim, and 20 keeps the run at about four hours.

Then repeat the same three against Inkling 2 Mini on port 8882, which gives a model comparison that does
not depend on anyone else's harness.

## Wiring each one to this endpoint

mini-swe-agent takes any LiteLLM provider, so a local server is a config change. In the agent config:

```yaml
model:
  model_name: openai/bonsai-2.5-27b
  model_kwargs:
    api_base: http://127.0.0.1:8884/v1
    api_key: dummy
  cost_tracking: ignore_errors
```

Run with `MSWEA_COST_TRACKING=ignore_errors` in the environment, or every step logs a cost lookup error.
Their SWE-bench runner is `mini-extra swebench`; check `--help` for the subset and worker flags, since
they move between releases.

τ-bench is LiteLLM too, and the agent and the user simulator are separate models. The user simulator can
stay on a hosted model if one is available; otherwise run both on the local endpoint and accept the
slower run.

```sh
tau2 run --domain airline --num-tasks 5 \
  --agent-llm openai/bonsai-2.5-27b \
  --agent-llm-args '{"api_base": "http://127.0.0.1:8884/v1"}'
```

Terminal-Bench routes model ids through LiteLLM as well, so `openai/bonsai-2.5-27b` with
`OPENAI_API_BASE` pointed at the endpoint is the usual pattern. Docker has to be running, and the first
task pulls images.

Aider accepts the endpoint directly:

```sh
aider --model openai/bonsai-2.5-27b --openai-api-base http://127.0.0.1:8884/v1
```

The polyglot suite itself lives in the aider benchmark repository and expects its own container setup.

## What to record

Per task: solved or not, number of model calls, total wall time, peak context, and whether any request
hit the 64K limit. The last one matters, because a truncated trajectory scores as a failure and looks
like a capability gap. Also log the pack and draft setting, since a 30 percent difference in decode
speed changes how many tasks fit in an evening.

## Caveats specific to this model

- Thinking goes to `reasoning_content`. Harnesses that count only `content` see short answers and may
  conclude the model is terse. Give a few hundred tokens of budget so the answer is not all thinking.
- The chat template defaults to `reasoning_effort: xhigh`. For long agent loops, `medium` roughly halves
  the thinking tokens at some accuracy cost.
- Context is 64K here. Agentic trajectories with large files can exceed it; the server truncates rather
  than erroring in some clients, so watch for it.
