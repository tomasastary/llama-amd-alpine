#!/bin/bash
# =============================================================================
# install.sh — Alpine Linux AMD GPU LLM inference setup
#
# Installs and configures:
#   1. llama.cpp (Vulkan, AMD GPU) with OpenRC service
#   2. 6 GGUF models (Qwen3.6-27B, Qwen3.6-35B-A3B, Gemma-4-12B, Gemma-4-31B)
#   3. models.ini with MTP draft support
#   4. GRUB kernel params for AMD GPU memory tuning
#   5. Vibe CLI config template + SSE patch instructions
#
# Requirements:
#   - Alpine Linux (OpenRC)
#   - AMD GPU with ROCm/Vulkan support
#   - Root privileges
#
# Usage: sudo bash install.sh
# =============================================================================
set -e

# Detect real user (when run via sudo)
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
usermod -aG video "${REAL_USER}" || true

LLAMA_DIR="/opt/llama.cpp"
MODEL_DIR="/opt/models"
API_KEY="$(openssl rand -hex 16)"
echo "Vygenerovaný API kľúč: ${API_KEY}"

echo "Aktualizujem repozitáre a inštalujem závislosti..."
sed -i '/community/s/^#//' /etc/apk/repositories
apk update && apk add cmake git build-base vulkan-loader vulkan-tools mesa-vulkan-ati mesa-dri-gallium sudo vulkan-headers vulkan-loader-dev shaderc spirv-headers glslang-dev openssl-dev linux-headers bash util-linux-misc

echo "Vypínam nepotrebné OS služby pre uvoľnenie RAM..."
rc-update del chronyd default || true
rc-update del acpid default || true

echo "Konfigurujem sysctl tuning..."
cat > /etc/sysctl.d/99-ai-server.conf << 'SYSCTL_EOF'
# cold anon blobs (prompt cache, checkpoints) may swap; pinned GTT memory never swaps anyway
vm.swappiness = 100
vm.min_free_kbytes = 262
SYSCTL_EOF
sysctl -p /etc/sysctl.d/99-ai-server.conf || true
rc-update add sysctl boot || true

echo "Vytváram swapfile (8G)..."
if [[ ! -f /swapfile ]]; then
    dd if=/dev/zero of=/swapfile bs=1M count=8192
    chmod 600 /swapfile
    mkswap /swapfile
fi
swapon /swapfile || true
if ! grep -q '/swapfile' /etc/fstab; then
    echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi

echo "Konfigurujem výkonnostné nastavenia..."
cat > /etc/local.d/perf-tuning.start << 'PERF_EOF'
#!/bin/sh
# iGPU: pin clocks
echo high > /sys/class/drm/card1/device/power_dpm_force_performance_level

# CPU: performance governor on all cores
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$g"
done
PERF_EOF
chmod +x /etc/local.d/perf-tuning.start
rc-update add local default || true

echo "Klonujem a kompilujem llama.cpp..."
mkdir -p "$LLAMA_DIR"
cd "$LLAMA_DIR"
git clone https://github.com/ggml-org/llama.cpp .
export CXXFLAGS="-I/usr/include"
rm -rf build
cmake -S . -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --target llama-server -j$(nproc)

echo "Sťahujem modely..."
AI_DIR="${REAL_HOME}/AI"
mkdir -p "${AI_DIR}"
wget -P "${AI_DIR}" "https://huggingface.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF/resolve/main/gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf"
wget -P "${AI_DIR}" "https://huggingface.co/unsloth/gemma-4-26B-A4B-it-qat-GGUF/resolve/main/mtp-gemma-4-26B-A4B-it.gguf"
wget -P "${AI_DIR}" "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-IQ4_NL.gguf"
wget -P "${AI_DIR}" "https://huggingface.co/unsloth/Qwen3.6-27B-A3B-MTP-GGUF/resolve/main/Qwen3.6-27B-UD-Q4_K_XL.gguf"
wget -P "${AI_DIR}" "https://huggingface.co/unsloth/gemma-4-31B-it-qat-GGUF/resolve/main/mtp-gemma-4-31B-it.gguf"
wget -P "${AI_DIR}" "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/mtp-gemma-4-12b-it.gguf"
wget -P "${AI_DIR}" "https://huggingface.co/unsloth/gemma-4-12B-it-qat-GGUF/resolve/main/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf"
wget -P "${AI_DIR}" "https://huggingface.co/unsloth/gemma-4-31B-it-qat-GGUF/resolve/main/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf"
wget -P "${AI_DIR}" "https://huggingface.co/unsloth/diffusiongemma-26B-A4B-it-GGUF/resolve/main/diffusiongemma-26B-A4B-it-Q4_K_M.gguf"
wget -P "${AI_DIR}" "https://huggingface.co/mradermacher/CyberPal2.0-20B-i1-GGUF/resolve/main/CyberPal2.0-20B.i1-MXFP4_MOE.gguf"
wget -P "${AI_DIR}" "https://huggingface.co/unsloth/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-Q8_0.gguf"
wget -P "${AI_DIR}" "https://huggingface.co/unsloth/Nemotron-3-Nano-30B-A3B-GGUF/resolve/main/Nemotron-3-Nano-30B-A3B-IQ4_NL.gguf"

echo "Vytváram models.ini..."
mkdir -p "$MODEL_DIR"
AI_DIR="${REAL_HOME}/AI"
cat > "$MODEL_DIR/models.ini" << MODELS_EOF
version = 1

# ============================================================================
# Per-model flags. The global server command carries only server/router flags
# (--models-preset --models-max --api-key --host --port); every model-instance
# flag (n-gpu-layers, context-shift, swa-checkpoints, kv-unified, cache-reuse,
# chat-template-kwargs) lives here so each model can be tuned individually.
# Hybrid (Nemotron) and diffusion (diffusiongemma) models opt OUT of
# context-shift / swa-checkpoints, which break recurrent / block-decode memory.
# ============================================================================

[qwen3.6-27b]
model = ${AI_DIR}/Qwen3.6-27B-UD-Q4_K_XL.gguf
ctx-size = 98304
batch-size = 2048
ubatch-size = 512
n-gpu-layers = 99
context-shift = true
swa-checkpoints = 2
kv-unified = true
cache-reuse = 256
chat-template-kwargs = {"preserve_thinking": true}
spec-type = draft-mtp
spec-draft-n-max = 4
cache-type-k = q8_0
cache-type-v = q8_0
parallel = 1
jinja = true
flash-attn = true
cache-ram = 2048

[qwen3.6-35b-a3b]
model = ${AI_DIR}/Qwen3.6-35B-A3B-UD-IQ4_NL.gguf
ctx-size = 131072
batch-size = 2048
ubatch-size = 512
n-gpu-layers = 99
context-shift = true
swa-checkpoints = 2
kv-unified = true
cache-reuse = 256
chat-template-kwargs = {"preserve_thinking": true}
spec-type = draft-mtp
spec-draft-n-max = 4
cache-type-k = q8_0
cache-type-v = q8_0
parallel = 1
jinja = true
flash-attn = true
cache-ram = 2048

[gemma-4-12b-it]
model = ${AI_DIR}/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf
ctx-size = 131072
batch-size = 2048
ubatch-size = 512
n-gpu-layers = 99
context-shift = true
swa-checkpoints = 2
kv-unified = true
cache-reuse = 256
chat-template-kwargs = {"preserve_thinking": true}
model-draft = ${AI_DIR}/mtp-gemma-4-12b-it.gguf
spec-type = draft-mtp
spec-draft-n-max = 4
cache-type-k = f16
cache-type-v = f16
parallel = 1
jinja = true
flash-attn = true
cache-ram = 2048

[gemma-4-31b-it]
model = ${AI_DIR}/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf
ctx-size = 81920
batch-size = 2048
ubatch-size = 512
n-gpu-layers = 99
context-shift = true
swa-checkpoints = 2
kv-unified = true
cache-reuse = 256
chat-template-kwargs = {"preserve_thinking": true}
model-draft = ${AI_DIR}/mtp-gemma-4-31B-it.gguf
spec-type = draft-mtp
spec-draft-n-max = 4
cache-type-k = q8_0
cache-type-v = q8_0
parallel = 1
jinja = true
flash-attn = true
fit = off
cache-ram = 0

[gemma-4-26b-a4b-it]
model = ${AI_DIR}/gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf
ctx-size = 131072
batch-size = 2048
ubatch-size = 512
n-gpu-layers = 99
context-shift = true
swa-checkpoints = 2
kv-unified = true
cache-reuse = 256
chat-template-kwargs = {"preserve_thinking": true}
model-draft = ${AI_DIR}/mtp-gemma-4-26B-A4B-it.gguf
spec-type = draft-mtp
spec-draft-n-max = 4
cache-type-k = q8_0
cache-type-v = q8_0
parallel = 1
jinja = true
flash-attn = true
cache-ram = 2048

[cyberpal-2.0-20b]
model = ${AI_DIR}/CyberPal2.0-20B.i1-MXFP4_MOE.gguf
ctx-size = 8192
batch-size = 2048
ubatch-size = 512
n-gpu-layers = 99
context-shift = true
swa-checkpoints = 2
kv-unified = true
cache-reuse = 256
cache-type-k = q8_0
cache-type-v = q8_0
parallel = 1
jinja = true
flash-attn = true
cache-ram = 1024

[gpt-oss-20b]
model = ${AI_DIR}/gpt-oss-20b-Q8_0.gguf
ctx-size = 65536
batch-size = 2048
ubatch-size = 512
n-gpu-layers = 99
context-shift = true
swa-checkpoints = 2
kv-unified = true
cache-reuse = 256
cache-type-k = q8_0
cache-type-v = q8_0
parallel = 1
jinja = true
flash-attn = true
cache-ram = 2048

# Hybrid Mamba2-Transformer: recurrent state breaks context-shift / swa-checkpoints
[nemotron-3-nano-30b-a3b]
model = ${AI_DIR}/Nemotron-3-Nano-30B-A3B-IQ4_NL.gguf
ctx-size = 65536
batch-size = 2048
ubatch-size = 512
n-gpu-layers = 99
kv-unified = true
cache-reuse = 256
cache-type-k = q8_0
cache-type-v = q8_0
parallel = 1
jinja = true
flash-attn = true
cache-ram = 2048

# Block-diffusion: no autoregressive context-shift / checkpoints
[diffusiongemma-26b-a4b-it]
model = ${AI_DIR}/diffusiongemma-26B-A4B-it-Q4_K_M.gguf
ctx-size = 8192
batch-size = 2048
ubatch-size = 512
n-gpu-layers = 99
parallel = 1
jinja = true
cache-ram = 512
MODELS_EOF

echo "Vytváram OpenRC službu..."
cat > /etc/init.d/llama-server << EOF
#!/sbin/openrc-run
export RADV_PERFTEST=nogttspill
export GGML_VK_PREFER_HOST_MEMORY=1

name="llama-server"
description="LLM Inference Server (Router Mode)"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0

command="/usr/bin/taskset"
# Only server/router flags here. All model-instance flags (n-gpu-layers,
# context-shift, swa-checkpoints, kv-unified, cache-reuse, chat-template-kwargs)
# are tuned per-model in models.ini.
command_args="-c 2-15 $LLAMA_DIR/build/bin/llama-server \\
  --models-preset $MODEL_DIR/models.ini \\
  --models-max 1 \\
  --api-key \"${API_KEY}\" \\
  --host 0.0.0.0 \\
  --port 8080"

# Vynútenie spustenia pod používateľom, inak nepôjde GPU akcelerácia!
command_user="${REAL_USER}:${REAL_USER}"

output_log="/var/log/llama-server.log"
error_log="/var/log/llama-server.log"

start_post() {
    # give the router OOM-kill resistance; model children stay killable
    sleep 1
    pid=\$(cat /run/llama-server.pid 2>/dev/null) || return 0
    echo -500 > /proc/\$pid/oom_score_adj 2>/dev/null
    return 0
}

depend() {
    need localmount
    need net
}
EOF

echo "Inicializujem logy a aktivujem službu..."
touch /var/log/llama-server.log
chmod +x /etc/init.d/llama-server
rc-update add llama-server default
rc-service llama-server start

# ============================================================================
# COPY PATCH FILES TO SYSTEM (for re-running after uv tool upgrade)
# ============================================================================
PATCH_DEST="${LLAMA_DIR}"
mkdir -p "${PATCH_DEST}"

cat > "${PATCH_DEST}/vibe_sse_patch.sh" << 'PATCH_SH_EOF'
#!/usr/bin/env bash
# Re-apply the vibe SSE keep-alive fix after `uv tool upgrade mistral-vibe`.
#
# Bug: vibe's stream parser in vibe/core/llm/backend/generic.py requires every
# SSE line to contain ": " and raises
#   ValueError: Stream chunk improperly formatted. Expected `key: value`, received `:`
# on llama.cpp's bare ":" keep-alive line (sent during slow prompt-eval on the
#  780M rig). Fix: ignore ":"-prefixed comment lines and make the post-colon
# space optional, per the SSE spec.
#
# Idempotent: safe to run repeatedly. Usage: ./vibe_sse_patch.sh
set -euo pipefail

# Locate generic.py inside the installed uv tool (any python3.x).
TOOL_ROOT="${HOME}/.local/share/uv/tools/mistral-vibe"
FILE="$(ls "${TOOL_ROOT}"/lib/python*/site-packages/vibe/core/llm/backend/generic.py 2>/dev/null | head -n1 || true)"

if [[ -z "${FILE}" || ! -f "${FILE}" ]]; then
    echo "ERROR: could not find vibe generic.py under ${TOOL_ROOT}" >&2
    echo "       Is mistral-vibe installed via 'uv tool'?" >&2
    exit 1
fi
echo "Target: ${FILE}"

PY="$(ls "${TOOL_ROOT}"/bin/python* 2>/dev/null | head -n1 || command -v python3)"

# Already patched? (our marker comment)
if grep -q "starting with \":\" is a comment" "${FILE}"; then
    echo "Already patched — nothing to do."
    exit 0
fi

# Apply via Python literal string replacement (no fragile line numbers).
"${PY}" - "${FILE}" <<'PYEOF'
import sys, py_compile, shutil, time

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

OLD = '''            async for line in response.aiter_lines():
                if line.strip() == "":
                    continue

                DELIM_CHAR = ":"
                if f"{DELIM_CHAR} " not in line:
                    raise ValueError(
                        f"Stream chunk improperly formatted. "
                        f"Expected `key{DELIM_CHAR} value`, received `{line}`"
                    )
                delim_index = line.find(DELIM_CHAR)
                key = line[0:delim_index]
                value = line[delim_index + 2 :]

                if key != "data":
                    # This might be the case with openrouter, so we just ignore it
                    continue
                if value == "[DONE]":
                    return
                yield json.loads(value.strip())'''

NEW = '''            async for line in response.aiter_lines():
                line = line.rstrip("\\r")
                if line.strip() == "":
                    continue

                # Per the SSE spec, a line starting with ":" is a comment
                # (e.g. llama.cpp's keep-alive sent during slow prompt eval)
                # and must be ignored.
                if line.startswith(":"):
                    continue

                DELIM_CHAR = ":"
                delim_index = line.find(DELIM_CHAR)
                if delim_index == -1:
                    # Field with no value; nothing useful to parse.
                    continue
                key = line[0:delim_index]
                value = line[delim_index + 1 :]
                # The single optional space after the colon is part of the
                # delimiter and is stripped per the SSE spec.
                if value.startswith(" "):
                    value = value[1:]

                if key != "data":
                    # This might be the case with openrouter, so we just ignore it
                    continue
                if value == "[DONE]":
                    return
                yield json.loads(value.strip())'''

if OLD not in src:
    print("ERROR: expected original code block not found.", file=sys.stderr)
    print("       vibe may have changed upstream — inspect/patch manually:", file=sys.stderr)
    print("      ", path, file=sys.stderr)
    sys.exit(2)

backup = path + ".orig." + time.strftime("%Y%m%d-%H%M%S")
shutil.copy2(path, backup)
open(path, "w", encoding="utf-8").write(src.replace(OLD, NEW, 1))
py_compile.compile(path, doraise=True)
print("Patched OK. Backup:", backup)
PYEOF

echo "Done."
PATCH_SH_EOF
chmod +x "${PATCH_DEST}/vibe_sse_patch.sh"
echo "Patch skript vytvorený: ${PATCH_DEST}/vibe_sse_patch.sh"

cat > "${PATCH_DEST}/vibe_sse_patch.diff" << 'PATCH_DIFF_EOF'
--- a/vibe/core/llm/backend/generic.py	2026-06-10 11:07:38.639118429 +0200
+++ b/vibe/core/llm/backend/generic.py	2026-06-10 10:58:27.671630938 +0200
@@ -417,18 +417,27 @@
 		await response.aread()
 	    response.raise_for_status()
 	    async for line in response.aiter_lines():
+                line = line.rstrip("\r")
 	        if line.strip() == "":
 	            continue
 
+                # Per the SSE spec, a line starting with ":" is a comment
+                # (e.g. llama.cpp's keep-alive sent during slow prompt eval)
+                # and must be ignored.
+                if line.startswith(":"):
+                    continue
+
 	        DELIM_CHAR = ":"
-                if f"{DELIM_CHAR} " not in line:
-                    raise ValueError(
-                        f"Stream chunk improperly formatted. "
-                        f"Expected `key{DELIM_CHAR} value`, received `{line}`"
-                    )
 	        delim_index = line.find(DELIM_CHAR)
+                if delim_index == -1:
+                    # Field with no value; nothing useful to parse.
+                    continue
 	        key = line[0:delim_index]
-                value = line[delim_index + 2 :]
+                value = line[delim_index + 1 :]
+                # The single optional space after the colon is part of the
+                # delimiter and is stripped per the SSE spec.
+                if value.startswith(" "):
+                    value = value[1:]
 
 	        if key != "data":
 	            # This might be the case with openrouter, so we just ignore it
PATCH_DIFF_EOF
echo "Patch diff vytvorený: ${PATCH_DEST}/vibe_sse_patch.diff"

echo "Konfigurujem GRUB..."
if ! grep -q 'ttm.pages_limit' /etc/default/grub; then
    sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 zswap.enabled=1 zswap.compressor=lz4 zswap.max_pool_percent=20 ttm.pages_limit=5400000 ttm.page_pool_size=5400000 iommu=pt amdgpu.sg_display=0 transparent_hugepage=madvise"/' /etc/default/grub
fi
grub-mkconfig -o /boot/grub/grub.cfg || grub2-mkconfig -o /boot/grub2/grub.cfg || true

echo "Pridávam lz4 do /etc/modules..."
if ! grep -q '^lz4$' /etc/modules 2>/dev/null; then
    echo lz4 >> /etc/modules
fi

# ============================================================================
# OPTIONAL: Vibe installation & configuration
# ============================================================================
VIBE_PATCH_FILE="/opt/llama.cpp/vibe_sse_patch.sh"
VIBE_DIFF_FILE="/opt/llama.cpp/vibe_sse_patch.diff"
VIBE_CONFIG="${REAL_HOME}/.vibe/config.toml"

echo ""
echo "========================================================================"
echo "  Vibe Installation & Configuration Instructions"
echo "========================================================================"
echo ""
echo "1. INSTALL VIBE (if not already installed):"
echo "   uv tool install mistral-vibe"
echo ""
echo "2. APPLY SSE PATCH (fixes llama.cpp keep-alive lines):"
if [[ -f "${VIBE_PATCH_FILE}" ]]; then
    echo "   bash ${VIBE_PATCH_FILE}"
    echo "   (Safe to re-run after 'uv tool upgrade mistral-vibe')"
    echo ""
    if [[ -f "${VIBE_DIFF_FILE}" ]]; then
        echo "   Unified diff (vibe_sse_patch.diff):"
        echo "   ----------------------------------------------------------------"
        cat "${VIBE_DIFF_FILE}"
        echo "   ----------------------------------------------------------------"
    fi
    echo ""
    echo "   Shell patch script (vibe_sse_patch.sh):"
    echo "   ----------------------------------------------------------------"
    cat "${VIBE_PATCH_FILE}"
    echo "   ----------------------------------------------------------------"
else
    echo "   Patch file not found at ${VIBE_PATCH_FILE}"
fi
echo ""
echo "3. CONFIGURE VIBE (${VIBE_CONFIG}):"
echo ""
echo "   Skopíruj nasledujúci config a merge ho do existujúceho"
echo "   ${VIBE_CONFIG} (alebo ho použi ako nový súborm)."
echo ""
echo "   --- START OF VIBE CONFIG (llamacpp provider + models) ---"
cat << VIBE_CONFIG_EOF
[[providers]]
name = "llamacpp"
api_base = "http://localhost:8080/v1"
api_key_env_var = "LLAMACPP_API_KEY"
api_style = "openai"
backend = "generic"
reasoning_field_name = "reasoning_content"
project_id = ""
region = ""

[providers.extra_headers]

[[models]]
name = "qwen3.6-27b"
provider = "llamacpp"
alias = "qwen3.6-27b"
temperature = 0.2
input_price = 0.0
output_price = 0.0
thinking = "high"
supports_images = true
auto_compact_threshold = 98304

[[models]]
name = "qwen3.6-35b-a3b"
provider = "llamacpp"
alias = "qwen3.6-35b-a3b"
temperature = 0.2
input_price = 0.0
output_price = 0.0
thinking = "high"
supports_images = true
auto_compact_threshold = 131072

[[models]]
name = "gemma-4-26b-a4b-it"
provider = "llamacpp"
alias = "gemma-4-26b-a4b-it"
temperature = 0.2
input_price = 0.0
output_price = 0.0
thinking = "high"
supports_images = true
auto_compact_threshold = 131072

[[models]]
name = "gemma-4-12b-it"
provider = "llamacpp"
alias = "gemma-4-12b-it"
temperature = 0.2
input_price = 0.0
output_price = 0.0
thinking = "high"
supports_images = true
auto_compact_threshold = 131072

[[models]]
name = "gemma-4-31b-it"
provider = "llamacpp"
alias = "gemma-4-31b-it"
temperature = 0.2
input_price = 0.0
output_price = 0.0
thinking = "high"
supports_images = true
auto_compact_threshold = 81920

[[models]]
name = "diffusiongemma-26b-a4b-it"
provider = "llamacpp"
alias = "diffusiongemma-26b-a4b-it"
temperature = 0.2
input_price = 0.0
output_price = 0.0
thinking = "none"
supports_images = false
auto_compact_threshold = 8192

[[models]]
name = "cyberpal-2.0-20b"
provider = "llamacpp"
alias = "cyberpal-2.0-20b"
temperature = 0.2
input_price = 0.0
output_price = 0.0
thinking = "high"
supports_images = false
auto_compact_threshold = 8192

[[models]]
name = "gpt-oss-20b"
provider = "llamacpp"
alias = "gpt-oss-20b"
temperature = 0.2
input_price = 0.0
output_price = 0.0
thinking = "high"
supports_images = false
auto_compact_threshold = 65536

[[models]]
name = "nemotron-3-nano-30b-a3b"
provider = "llamacpp"
alias = "nemotron-3-nano-30b-a3b"
temperature = 0.2
input_price = 0.0
output_price = 0.0
thinking = "high"
supports_images = false
auto_compact_threshold = 65536
VIBE_CONFIG_EOF
echo "   --- END OF VIBE CONFIG ---"
echo ""
echo "   Nastav env premennú pre API kľúč:"
echo "   export LLAMACPP_API_KEY=${API_KEY}"
echo ""
echo "   Potom nastav active_model v config.toml:"
echo "   active_model = \"gpt-oss-20b\""
echo ""
echo "4. VERIFY SERVICE:"
echo "   rc-service llama-server status"
echo "   curl -s http://localhost:8080/models | head -20"
echo ""
echo "========================================================================"

echo ""
echo "Inštalácia dokončená!"
echo "Rebootni systém pre aplikovanie GRUB zmien a GPU nastavení:"
echo "   sudo reboot"
