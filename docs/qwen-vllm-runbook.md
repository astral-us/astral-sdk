# Qwen vLLM Runbook

This runbook records the working setup for serving Qwen on the `saib` box.

## Hardware

- Host: `saib`
- OS: Ubuntu 24.04
- GPU: 2 x NVIDIA GeForce RTX 5090
- VRAM: about 32 GB per GPU
- vLLM: `0.19.1`
- vLLM environment: `/opt/ml/llm-serve/.venv`

## Current Recommendation

As of 2026-07-12, do not use `Qwen/Qwen3.6-35B-A3B-FP8` as the default IDE model on this box. It can load, but repeated inference requests have crashed inside the Qwen3.6/Qwen3-Next linear-attention path:

```text
RuntimeError: Kernel requires a runtime memory allocation, but no allocator was set. Use triton.set_allocator to specify an allocator.
```

The failure happens during generation in vLLM/Triton/FLA, not during HTTP startup and not from GPU OOM. For daily IDE use, prefer a coder checkpoint that avoids this unstable path:

```text
Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8
```

This model is FP8, code-focused, non-thinking by default, and should be a better fit for IDE clients because it returns normal content instead of reasoning-only responses.

## Previous Working Model

Use:

```text
Qwen/Qwen3.6-35B-A3B-FP8
```

The full BF16 model did not fit reliably on the two 32 GB cards. The FP8 model was the first path that loaded on this machine, but the later runtime allocator crash makes it unstable for pair-programming use until the vLLM/Triton stack is changed or upgraded.

## Recommended Coder Start Command

```bash
cd /opt/ml/llm-serve
source .venv/bin/activate

export HF_HOME="$HOME/.cache/huggingface"
export HUGGINGFACE_HUB_CACHE="$HOME/.cache/huggingface/hub"
export VLLM_CACHE_ROOT="$HOME/.cache/vllm"
export PYTORCH_ALLOC_CONF=expandable_segments:True
export TORCHDYNAMO_DISABLE=1
unset VLLM_ATTENTION_BACKEND

CUDA_VISIBLE_DEVICES=0,1 vllm serve Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 \
  --host 0.0.0.0 \
  --port 8001 \
  --tensor-parallel-size 2 \
  --max-model-len 32768 \
  --attention-backend FLASH_ATTN \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --disable-custom-all-reduce \
  --enforce-eager \
  2>&1 | tee /tmp/vllm-qwen3-coder-30b-fp8.log
```

Test it with:

```bash
curl http://localhost:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8",
    "messages": [
      {"role": "user", "content": "Reply with READY only."}
    ],
    "max_tokens": 16,
    "temperature": 0
  }'
```

## Start Command

Before starting, make sure no stale vLLM workers are using GPU memory:

```bash
nvidia-smi
ps aux | grep -Ei '[v]llm|VLLM::|Qwen3.6'
```

Both GPUs should be near idle, around `21MiB` to `24MiB` used.

Then run:

```bash
cd /opt/ml/llm-serve
source .venv/bin/activate

export HF_HOME="$HOME/.cache/huggingface"
export HUGGINGFACE_HUB_CACHE="$HOME/.cache/huggingface/hub"
export VLLM_CACHE_ROOT="$HOME/.cache/vllm"
export PYTORCH_ALLOC_CONF=expandable_segments:True
export TORCHDYNAMO_DISABLE=1
unset VLLM_ATTENTION_BACKEND

CUDA_VISIBLE_DEVICES=0,1 vllm serve Qwen/Qwen3.6-35B-A3B-FP8 \
  --host 0.0.0.0 \
  --port 8001 \
  --tensor-parallel-size 2 \
  --max-model-len 16384 \
  --attention-backend FLASH_ATTN \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --language-model-only \
  --disable-custom-all-reduce \
  --enforce-eager \
  2>&1 | tee /tmp/vllm-qwen36-fp8-no-dynamo.log
```

## Readiness Checks

In another terminal:

```bash
tail -f /tmp/vllm-qwen36-fp8-no-dynamo.log
```

Check whether the OpenAI-compatible API is listening:

```bash
curl http://localhost:8001/v1/models
```

Check GPU usage:

```bash
nvidia-smi
```

## Test Request

```bash
curl http://localhost:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3.6-35B-A3B-FP8",
    "messages": [
      {
        "role": "user",
        "content": "Write a Python function that validates an email address and include tests."
      }
    ],
    "temperature": 0.6,
    "top_p": 0.95
  }'
```

## Cleanup

If startup fails or workers become stale:

```bash
pkill -f 'Qwen3.6-35B-A3B-FP8'
pkill -f '/opt/ml/llm-serve/.venv/bin/vllm'
pkill -f 'VLLM::'
nvidia-smi
```

If a single stale worker still holds GPU memory, kill the PID shown by `nvidia-smi`:

```bash
kill -9 <PID>
```

## Known Failed Attempts

Full BF16 model:

```text
Qwen/Qwen3.6-35B-A3B
```

This OOMed during model loading on 2 x RTX 5090:

```text
CUDA out of memory
Failed to load model - not enough GPU memory
```

FP8 with `FLASHINFER` attention:

```text
Qwen/Qwen3.6-35B-A3B-FP8
```

This loaded weights but hung during startup on this machine.

FP8 with `--kv-cache-dtype fp8` and `FLASH_ATTN`:

```text
ValueError: Selected backend AttentionBackendEnum.FLASH_ATTN is not valid for this configuration. Reason: ['kv_cache_dtype not supported']
```

Do not combine `--kv-cache-dtype fp8` with `--attention-backend FLASH_ATTN`.

FP8 without `TORCHDYNAMO_DISABLE=1`:

```text
torch._inductor.exc.InductorError: PermissionError: [Errno 13] Permission denied: 'nvcc'
```

The working command avoids this by setting:

```bash
export TORCHDYNAMO_DISABLE=1
```

Qwen3.6 FP8 runtime generation:

```text
RuntimeError: Kernel requires a runtime memory allocation, but no allocator was set. Use triton.set_allocator to specify an allocator.
```

This occurs after the server accepts a chat request. It points at the `qwen3_next.py` linear-attention/GDN path through vLLM's FLA Triton kernels, so treat it as a vLLM/Triton/model-kernel compatibility issue rather than an API, port, or VRAM problem.

## Notes

- `VLLM_ATTENTION_BACKEND` is not recognized by vLLM `0.19.1` on this setup. Use the CLI flag instead:

```bash
--attention-backend FLASH_ATTN
```

- `--enforce-eager` is kept in the working command to avoid CUDA graph or compile-related startup issues.
- `--disable-custom-all-reduce` is used because vLLM reported custom all-reduce/P2P warnings on this machine.
