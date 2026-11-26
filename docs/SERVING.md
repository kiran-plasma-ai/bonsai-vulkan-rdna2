# Serving Ternary Bonsai 2.5 on this card

The unit `systemd/llama-server-bonsai.service` serves `Q2_0-mtp` at 128K context through the Prism fork
on port 8884, OpenAI-compatible. It is the configuration below, measured on an RX 6800 XT 16 GB.

```ini
ExecStart=%h/.local/share/llama.cpp-prism/bin/llama-server \
    -m %h/models/bonsai/Ternary-Bonsai-2.5-27B-Q2_0-mtp.gguf \
    -ngl 99 -fa on -c 131072 --jinja --metrics --parallel 1 \
    --cache-type-k q8_0 --cache-type-v q8_0 \
    --alias bonsai-2.5-27b \
    --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-p-min 0 \
    --host 127.0.0.1 --port 8884 --timeout 600
```

Install and run:

```sh
install -m 644 systemd/llama-server-bonsai.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user start llama-server-bonsai
curl -sf http://127.0.0.1:8884/health
```

## Measured behaviour

| test | result |
|---|---|
| load to healthy | about 15 s warm page cache |
| VRAM after load at 128K | 13.69 GiB of 15.98 GiB |
| short chat, 200 token budget | 1.1 s wall, `content` "OK" plus 85 characters of reasoning |
| tool call (one function) | valid `tool_calls` JSON, 1.8 s |
| 5.7k-token prompt | TTFT 11.6 s (about 490 tok/s prefill), decode 74.2 tok/s |
| 30.5k-token prompt | TTFT 65.6 s (about 465 tok/s), decode about 64 tok/s |
| 65k-token prompt at 128K | decode 52.0 tok/s, 28% below the 72.4 measured at 64K with f16 KV |
| draft acceptance, logged by the server | 0.90 to 0.97, mean accepted run 2.8 to 2.9 |

## Client notes

- Model id is `bonsai-2.5-27b` (`--alias`). `/v1/models` carries the standard OpenAI `data` array plus
  an extra `models` key in the Ollama schema; clients that read `data` are unaffected.
- Thinking arrives in `reasoning_content`, the answer in `content`. A small `max_tokens` can be spent
  entirely on thinking, so give agent harnesses a few hundred tokens of room.
- Tool calling works through `--jinja` with the model's own template. The chat template defaults to
  `reasoning_effort: xhigh`; pass `chat_template_kwargs: {"reasoning_effort": "medium"}` to shorten it.
- Streaming, `/props`, and the Anthropic-style messages endpoint follow the fork's llama-server.

## Things that do not work

- `LLAMA_MTP_CHAIN=1` (chained drafts, mentioned in the server log as off by default) segfaults this
  build on this card. Leave it alone.
- KV quantization is expensive but sometimes required. At 64K, `-ctk q8_0 -ctv q8_0` gave 41.8 tok/s
  against 72.4 with f16, so f16 was the right choice there. At 128K the f16 KV no longer fits: q8_0 keeps
  the card at 13.69 GiB and still decodes at 52.0 tok/s, 28% below the 64K f16 number. Agent trajectories
  above 65k tokens failed against 64K, which is why the unit now serves 128K with q8_0. See
  [AGENTIC.md](AGENTIC.md).
- Draft counts above two cost more than they save: see the sweep in
  [RESULTS.md](RESULTS.md#mtp-sweep-ptq10-mtp-code-prompt).

## Coexistence with the other local models

One card, so the units conflict: `llama-server-bonsai` declares `Conflicts=` against
`llama-server-inkling` (Inkling 2 Mini at 8882, has vision) and `rustingstrata-inkling` (same model on
RustingStrata at 8899). Starting one stops the others. Switching is a single `systemctl --user start`
of the unit you want.
