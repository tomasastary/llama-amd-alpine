# llama.cpp on AMD Radeon 780M (Alpine Linux)

A single `install.sh` that turns a mini-PC with an **AMD Ryzen / Radeon 780M iGPU**
into a multi-model LLM inference server using **llama.cpp in router mode** over Vulkan.

It compiles llama.cpp, downloads a fleet of GGUF models, generates a tuned
`models.ini`, and wires up an OpenRC service — plus OS/memory tuning for running
20–35B models on an iGPU that shares system RAM.

## Hardware

| Component | Spec |
|---|---|
| CPU | AMD Ryzen 7 255 (8C / 16T, Zen) |
| GPU | AMD Radeon 780M (RDNA3 iGPU, `RADV PHOENIX`, Vulkan) |
| RAM | 24 GB (≈22.3 GiB usable; **20.6 GiB GTT** addressable by the iGPU) |
| Storage | NVMe SSD |
| OS | Alpine Linux v3.23 (OpenRC) |
| Kernel | 6.18 LTS |

The iGPU has no dedicated VRAM — model weights live in **GTT** (system RAM mapped
to the GPU). The whole design is shaped by the ~20.6 GiB GTT ceiling: MoE models
win because only a few billion parameters are active per token.

## Software stack

- **llama.cpp** (Vulkan backend, `-DGGML_VULKAN=ON`)
- **Router mode** (`--models-preset`) — all models defined in one `models.ini`,
  one model loaded at a time (`--models-max 1`), swapped on demand per request.
- **MTP speculative decoding** (`draft-mtp`) where a draft head is available.
- **Per-model tuning** — every model-instance flag (context length, KV cache type,
  cache-reuse, speculative decoding, `context-shift`) lives per-model in
  `models.ini`, so hybrid (Mamba) models can opt out of flags that
  break their memory model.
- **OpenRC + supervise-daemon** service with OOM-kill resistance for the router.
- **OS tuning**: zswap (lz4), 8 GB swapfile, `vm.swappiness`, performance CPU
  governor, pinned iGPU clocks, disabled unneeded services.

## Models

Eight GGUF models, all served locally at zero marginal cost, swapped on demand
(one resident at a time). Quant choice is shaped by the GTT ceiling — and by the
fact that MoE expert weights are often already low-bit (e.g. gpt-oss is natively
MXFP4, so quantizing the experts further buys nothing).

| Model | Base / arch | Quant | Weights | Context | MTP draft | Role |
|---|---|---|---:|---:|:---:|---|
| `gpt-oss-20b` | OpenAI MoE (3.6B active) | Q8_0 | 11.3 GB | 65 536 | — | general + agentic / tool-use (**default**) |
| `qwen3.6-35b-a3b` | Qwen MoE (~3B active) | UD-IQ4_NL | ~18 GB | 131 072 | ✓ | general reasoning |
| `qwen3.6-27b` | Qwen dense | UD-Q4_K_XL | ~16 GB | 65 536 | ✓ | general (reference) |
| `gemma-4-26b-a4b-it` | Gemma MoE (~4B active) | UD-Q4_K_XL (QAT) | ~14 GB | 131 072 | ✓ | general, **fastest** |
| `gemma-4-12b-it` | Gemma dense | UD-Q4_K_XL (QAT) | 6.7 GB | 131 072 | ✓ | lightweight general (f16 KV) |
| `gemma-4-31b-it` | Gemma dense | UD-Q4_K_XL (QAT) | 17.4 GB | 65 536 | ✓ | largest dense |
| `nemotron-3-nano-30b-a3b` | NVIDIA hybrid Mamba2-MoE (3.5B active) | IQ4_NL | 16.9 GB | 65 536 | — | hard math / reasoning, long context |
| `cyberpal-2.0-20b` | gpt-oss MoE, IBM CTI fine-tune | MXFP4_MOE | 11.3 GB | 8 192 | — | defensive cybersecurity specialist |

Notes:
- **MTP** = multi-token-prediction draft head (speculative decoding); ~55–65%
  draft acceptance observed, worth ~1.5–2× throughput.
- `gemma-4-31b-it` and `qwen3.6-27b` are capped at 65 536 context: their ~16–17 GB
  weights + KV + the MTP draft model must fit under the ~20.6 GiB GTT ceiling.
  Higher context overcommits — the load hangs during slot init (qwen3.6-27b was
  previously set to 98 304 and never loaded).
- DiffusionGemma (block-diffusion) is **deferred** — it can't run through the
  router and its diffusion sampler is CUDA-only (no AMD/Vulkan path yet). See
  [`docs/diffusiongemma-deferred.md`](docs/diffusiongemma-deferred.md).

## Performance — generation speed

Measured on the 780M (Vulkan), 200-token generation after a clean boot:

| Model | Arch | Active params | Gen t/s | Prompt t/s |
|---|---|---:|---:|---:|
| gemma-4-26b-a4b-it | MoE | ~4B | **35.9** | 68.1 |
| qwen3.6-35b-a3b | MoE | ~3B | 33.5 | 29.8 |
| nemotron-3-nano-30b-a3b | hybrid Mamba2-MoE | 3.5B | 29.5 | 36.3 |
| gpt-oss-20b | MoE | 3.6B | 28.9 | 84.9 |
| cyberpal-2.0-20b | MoE | 3.6B | 28.8 | 78.0 |
| gemma-4-12b-it | dense | 12B | 22.8 | 53.1 |
| gemma-4-31b-it | dense | 31B | 12.1 | 21.7 |
| qwen3.6-27b | dense | 27B @65K | 10.0 | 12.3 |

**Takeaway:** it's dense-vs-MoE, not size. The MoE models activate only ~3–4B
params per token and run 3–4× faster than the dense models despite being larger in
total — `gemma-4-26b-a4b-it` (26B, ~4B active) hits 35.9 t/s while the dense
`qwen3.6-27b` (27B) manages 10.0. On a memory-bandwidth-bound iGPU, MoE wins
decisively. MTP speculative decoding adds a further ~1.5–2× on models that ship a
draft head (≈55–65% draft acceptance observed).

## Performance — accuracy

A 37-question battery spanning math, logic, reasoning, coding, knowledge,
instruction-following, and classic LLM traps (scored against known answers):

| Model | Score | % |
|---|---:|---:|
| gpt-oss-20b | 35/37 | 94% |
| gemma-4-26b-a4b-it | 35/37 | 94% |
| gemma-4-31b-it | 35/37 | 94% |
| qwen3.6-35b-a3b | 35/37 | 94% |
| gemma-4-12b-it | 35/37 | 94% |
| qwen3.6-27b | 34/37 | 91% |
| cyberpal-2.0-20b | 27/37 | 72% |
| *MiniMax-M3 (cloud reference)* | *36/37* | *97%* |

**Takeaway:** the general models cluster tightly at 94% — the local fleet is
competitive with a frontier cloud model on this battery, at zero cost. The
security-specialist `cyberpal-2.0-20b` scores lower on **general** reasoning/math
(it was fine-tuned narrowly for CTI/CVE classification) but is fast and strong in
its domain — its C/CWE vulnerability analysis is accurate. `gpt-oss-20b` is the
best all-rounder: top accuracy, ~29 t/s, and native tool-use — hence the default.

This 37-question battery has a low ceiling (most models saturate it). For *hard*
reasoning, `nemotron-3-nano-30b-a3b` is the standout — its published numbers
(AIME25 89.1, GPQA 73.0, MMLU-Pro 78.3, RULER-100 @ 256k = 92.9) are well above
the rest of the fleet, and its hybrid Mamba layers make long context cheap on KV.
It isn't scored above because the battery doesn't probe that level of difficulty.

## Usage

```sh
sudo bash install.sh
```

Requirements: Alpine Linux (OpenRC), an AMD GPU with Vulkan support, root.

The script prints a generated API key on completion and reboot instructions
(GRUB kernel params + GPU tuning require a reboot). After reboot the server
listens on `:8080` with an OpenAI-compatible API:

```sh
curl -s http://localhost:8080/v1/models -H "Authorization: Bearer <API_KEY>"
```

It also emits an optional config block for the [vibe](https://github.com/mistralai/vibe)
CLI (llama.cpp provider + per-model entries) and an SSE keep-alive patch for it.

## Notes

- **Edit paths/models before running.** The script downloads a specific model set
  to `$HOME/AI` and assumes that layout in `models.ini`.
- The `[default]` entry that appears in `/v1/models` is a harmless router artifact
  (the global flags with no model attached), not a loadable model.
- Numbers above are single-run measurements on one machine; treat them as
  directional, not benchmarks.
