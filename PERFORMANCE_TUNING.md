# vLLM Performance Tuning Guide

## Current Performance Analysis

Your benchmark shows **~3.3 tokens/second** with the following configuration:

```
Model: Llama-3.3-70B-Instruct
Tensor Parallel: 2 GPUs (across 2 nodes)
Max Context: 2048 tokens
GPU Memory Util: 0.70 (70%)
Mode: --enforce-eager (CUDA graphs disabled)
Network: InfiniBand/RoCE (NET/IBext_v10) ✅
```

## Good News

✅ **InfiniBand/RoCE is working correctly!**
- NCCL is using `NET/IBext_v10` (InfiniBand)
- Both GPUs are connected via high-speed network
- Network configuration is optimal

## Performance Bottleneck

❌ **`--enforce-eager` flag is severely limiting performance**

The `--enforce-eager` flag forces PyTorch to execute operations immediately without CUDA graph optimization. This is useful for debugging but **drastically reduces inference speed**.

### Performance Impact:
- **With --enforce-eager**: ~3-5 tokens/s (what you're seeing)
- **Without --enforce-eager** (CUDA graphs): **30-80 tokens/s expected**

## Recommended Configuration Changes

### Option 1: Remove --enforce-eager (Recommended)

Edit `start_head_vllm.sh` and remove the `--enforce-eager` flag:

```bash
# Find this line (around line 251-259):
nohup vllm serve ${MODEL} \
  --distributed-executor-backend ray \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size ${TENSOR_PARALLEL} \
  --max-model-len ${MAX_MODEL_LEN} \
  --gpu-memory-utilization ${GPU_MEMORY_UTIL} \
  --download-dir \$HF_HOME \
  --enforce-eager \                          # <-- REMOVE THIS LINE
  > /var/log/vllm.log 2>&1 &
```

**Expected improvement: 10-25x faster (30-80 tokens/s)**

### Option 2: Increase Context Length

```bash
export MAX_MODEL_LEN=8192  # or 16384 for longer contexts
./start_head_vllm.sh
```

**Benefit**: Better batching, improved throughput for longer conversations

### Option 3: Increase GPU Memory Utilization

```bash
export GPU_MEMORY_UTIL=0.90
./start_head_vllm.sh
```

**Benefit**: More KV cache, can handle more concurrent requests

### Option 4: All Optimizations Combined

```bash
# Edit start_head_vllm.sh:
# 1. Remove --enforce-eager line
# 2. Then restart with optimal settings:

export MAX_MODEL_LEN=8192
export GPU_MEMORY_UTIL=0.90
./start_head_vllm.sh
```

**Expected result: 50-100 tokens/s** (15-30x improvement!)

## Step-by-Step: Apply Optimizations

### 1. Stop Current vLLM

```bash
docker stop ray-head ray-worker
docker rm ray-head ray-worker
```

### 2. Edit start_head_vllm.sh

```bash
cd ~/vllm-dgx-spark
nano start_head_vllm.sh

# Find the vllm serve command and remove --enforce-eager
# Save and exit (Ctrl+X, Y, Enter)
```

### 3. Restart with Optimized Settings

```bash
# On head node
export MAX_MODEL_LEN=8192
export GPU_MEMORY_UTIL=0.90
./start_head_vllm.sh

# On worker node
export HEAD_IP=169.254.103.56
./start_worker_vllm.sh
```

### 4. Wait for Model to Load

```bash
# Monitor progress
docker exec ray-head tail -f /var/log/vllm.log

# Wait for: "vLLM server is ready"
```

### 5. Run Benchmark Again

```bash
./benchmark_tokens_per_second.sh
```

**You should now see 30-100 tokens/s!**

## Understanding --enforce-eager

### Why it exists:
- Debugging CUDA errors
- Development and testing
- Environments where CUDA graphs don't work

### Why you don't need it:
- Your setup is stable and working
- InfiniBand is configured correctly
- You want production performance

### What happens when you remove it:
- ✅ vLLM compiles CUDA graphs (one-time ~30-60s delay at startup)
- ✅ Subsequent inference is 10-25x faster
- ✅ More efficient GPU utilization
- ⚠️  Slightly longer initialization time
- ⚠️  Uses slightly more GPU memory

## Troubleshooting After Removing --enforce-eager

### If vLLM fails to start:

Check logs:
```bash
docker exec ray-head tail -100 /var/log/vllm.log
```

### Common issues:

1. **Out of memory during graph compilation**
   ```bash
   # Reduce context length temporarily
   export MAX_MODEL_LEN=4096
   export GPU_MEMORY_UTIL=0.85
   ```

2. **CUDA graph compilation errors**
   ```bash
   # Check CUDA version compatibility
   docker exec ray-head nvidia-smi
   ```

3. **Very slow startup (>5 minutes)**
   - This is normal! CUDA graph compilation takes time
   - Wait patiently, it only happens once
   - Check logs to see progress

## Expected Performance Metrics

### With --enforce-eager (current):
- Short prompts: ~3.3 tokens/s
- Long prompts: ~3.3 tokens/s
- Consistent but slow

### Without --enforce-eager (optimized):
- Short prompts: 50-80 tokens/s
- Medium prompts: 60-100 tokens/s
- Long prompts: 40-70 tokens/s
- Much faster, slight variation based on prompt length

### Best case (all optimizations):
- Llama-3.3-70B on 2x GB10 (128GB each)
- InfiniBand/RoCE network
- CUDA graphs enabled
- Max context 8192
- GPU memory 0.90

**Expected: 60-100 tokens/s sustained throughput**

## Alternative: Keep --enforce-eager for Stability

If you prefer stability over performance (development/testing):

Current setup is working correctly! You're getting the expected performance for eager mode:
- ~3.3 tokens/s is normal for --enforce-eager with 70B models
- Network (InfiniBand) is configured correctly
- Both GPUs are being utilized

Trade-offs:
- ✅ More stable
- ✅ Easier to debug issues
- ✅ Faster restarts
- ❌ 10-25x slower inference

## Summary

| Configuration | Tokens/s | Best For |
|--------------|----------|----------|
| Current (--enforce-eager) | ~3.3 | Development, debugging |
| Remove --enforce-eager | 30-80 | Production, performance |
| + Increase context (8192) | 50-90 | Long conversations |
| + Increase GPU memory (0.90) | 60-100 | Maximum throughput |

**Recommendation**: Remove `--enforce-eager` for a **10-30x performance boost** while maintaining stability. Your InfiniBand network is configured correctly and ready for high-performance inference!

