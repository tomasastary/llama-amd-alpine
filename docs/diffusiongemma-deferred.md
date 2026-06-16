# DiffusionGemma — deferred

`unsloth/diffusiongemma-26B-A4B-it-GGUF` was evaluated on this rig and **deferred**.
It is intentionally **not** in `install.sh` / `models.ini`. This note records why, and
the exact steps to bring it back once upstream support lands.

## Why deferred

1. **It can't run through the router.** Block-diffusion generates by iteratively
   denoising a token canvas with bidirectional attention — not autoregressive decoding.
   Neither support PR wires diffusion-gemma into `tools/server`'s generation loop, so it
   cannot be a `--models-preset` model on `:8080`. It needs its own dedicated binary
   (`llama-diffusion-cli`, or the separate `llama-diffusion-gemma-server`).
2. **No AMD/Vulkan acceleration for the sampler.** With `-ngl 99` the model *forward
   pass* runs on Vulkan like everything else, but the diffusion *sampler* (top-k /
   entropy / canvas-update kernels) is **CUDA-only**
   (`ggml/src/ggml-cuda/diffusion-sampling.cu`). On Vulkan it logs
   `on-device sampling unsupported on this backend; using host sampling` and falls back
   to CPU for that step. Works, but no GPU sampler path on this box.

Arch support is unreleased: draft PRs **#24423** (Unsloth/danielhanchen) and **#24427**
(lnigam). Mainline `llama-server` rejects the GGUF with
`unknown model architecture: 'diffusion-gemma'`.

## Evaluation result (2026-06-16)

Built `llama-diffusion-cli` from PR #24423 (Vulkan) in an isolated git worktree and ran
it with the live server stopped:

- Output was **coherent** (incl. a `<|channel>thought … <channel|>` reasoning block).
- **~12.9 tok/s** (GPU forward + CPU sampler) — comparable to the dense 31B model, i.e.
  **not faster** than the MoE models in the fleet (29–36 t/s).

## How to bring it back

```bash
# On the server, isolated from the live build (master stays untouched):
cd ~/AI/llama.cpp
git fetch origin pull/24423/head:diffusiongemma-pr24423
git worktree add ../llama.cpp-diffusion diffusiongemma-pr24423

cd ~/AI/llama.cpp-diffusion
export CXXFLAGS="-I/usr/include"
cmake -S . -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --target llama-diffusion-cli -j6

# Run (needs ~16 GB free — stop the router first if RAM-tight):
./build/bin/llama-diffusion-cli \
  -m ~/AI/diffusiongemma-26B-A4B-it-Q4_K_M.gguf \
  -ngl 99 -cnv -n 2048
# useful flags: --diffusion-steps N (default 256), --diffusion-visual,
#               --diffusion-block-length, --temp, --top-k, --top-p, --seed
```

**Re-enable in the fleet** once either (a) a released llama.cpp integrates diffusion-gemma
into the server, or (b) the diffusion sampler gets a Vulkan/ROCm path. At that point,
re-add the GGUF download + a `models.ini`/vibe entry (or stand up
`llama-diffusion-gemma-server` on its own port) — see git history before commit `8c1ab97`
for the exact blocks that were removed.

## Cleanup (if abandoning the local build)

```bash
cd ~/AI/llama.cpp
git worktree remove ../llama.cpp-diffusion --force
git branch -D diffusiongemma-pr24423
rm -f ~/AI/diffusiongemma-26B-A4B-it-Q4_K_M.gguf   # reclaim 15.7 GB
```
