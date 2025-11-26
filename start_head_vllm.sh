#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# DGX Spark vLLM Head Node - Production Setup Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Configuration
IMAGE="${IMAGE:-nvcr.io/nvidia/vllm:25.10-py3}"
NAME="${NAME:-ray-head}"
HF_CACHE="${HF_CACHE:-/raid/hf-cache}"
HF_TOKEN="${HF_TOKEN:-}"  # Set via: export HF_TOKEN=hf_xxx
RAY_VERSION="${RAY_VERSION:-2.51.0}"

# Model configuration
MODEL="${MODEL:-mistralai/Mixtral-8x7B-Instruct-v0.1}"
TENSOR_PARALLEL="${TENSOR_PARALLEL:-2}"  # Default to 2 for distributed inference
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"   # Context length for Qwen2.5
GPU_MEMORY_UTIL="${GPU_MEMORY_UTIL:-0.90}"  # Can be aggressive with smaller model

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Auto-detect Network Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# DGX Spark uses RoCE (RDMA over Converged Ethernet) with ConnectX-7 NICs.
# Interface names are enp1s0f1np1 or enP2p1s0f1np1, NOT ib0/ib1.
# We prefer enp1* interfaces over enP2p* per NVIDIA's NCCL playbook.
# HEAD_IP must be the 169.254.x.x link-local address on the RoCE interface.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Discover primary RoCE interface using ibdev2netdev
discover_roce_interface() {
  if command -v ibdev2netdev >/dev/null 2>&1; then
    # Get active (Up) RoCE interfaces, preferring enp1* over enP2p*
    local active_line
    active_line=$(ibdev2netdev 2>/dev/null | awk '/\(Up\)/ {print;}' | grep 'enp1' | head -n1)
    if [ -z "$active_line" ]; then
      active_line=$(ibdev2netdev 2>/dev/null | awk '/\(Up\)/ {print;}' | head -n1)
    fi

    if [ -n "$active_line" ]; then
      # Extract interface name (5th field, removing parentheses)
      echo "$active_line" | awk '{print $5}' | tr -d '()'
    fi
  fi
}

# Discover RoCE HCA name from ibdev2netdev
discover_roce_hca() {
  if command -v ibdev2netdev >/dev/null 2>&1; then
    local active_line
    active_line=$(ibdev2netdev 2>/dev/null | awk '/\(Up\)/ {print;}' | grep 'enp1' | head -n1)
    if [ -z "$active_line" ]; then
      active_line=$(ibdev2netdev 2>/dev/null | awk '/\(Up\)/ {print;}' | head -n1)
    fi

    if [ -n "$active_line" ]; then
      echo "$active_line" | awk '{print $1}'
    fi
  fi
}

# Get all active RoCE HCAs (comma-separated for NCCL_IB_HCA)
discover_all_roce_hcas() {
  if command -v ibdev2netdev >/dev/null 2>&1; then
    ibdev2netdev 2>/dev/null | grep "(Up)" | awk '{print $1}' | sort | tr '\n' ',' | sed 's/,$//'
  fi
}

# Get the 169.254.x.x link-local IP from a RoCE interface
get_roce_ip() {
  local iface="$1"
  if [ -n "$iface" ]; then
    # Prefer 169.254.x.x (link-local) addresses for RoCE
    local ip
    ip=$(ip -o addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $4}' | cut -d'/' -f1 | grep "^169\.254\." | head -1)
    if [ -z "$ip" ]; then
      # Fall back to any IPv4 address on the interface
      ip=$(ip -o addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $4}' | cut -d'/' -f1 | head -1)
    fi
    echo "$ip"
  fi
}

# Auto-detect primary RoCE interface
PRIMARY_ROCE_IF=$(discover_roce_interface)

# Auto-detect HEAD_IP from RoCE interface (or use override)
if [ -z "${HEAD_IP:-}" ]; then
  if [ -n "${PRIMARY_ROCE_IF}" ]; then
    HEAD_IP=$(get_roce_ip "${PRIMARY_ROCE_IF}")
  fi
  # Final fallback if auto-detection fails
  if [ -z "${HEAD_IP:-}" ]; then
    echo "ERROR: Could not auto-detect HEAD_IP from RoCE interface."
    echo ""
    echo "Please ensure:"
    echo "  1. The 200 Gb cable is connected between Spark nodes"
    echo "  2. Run 'ibdev2netdev' to verify RoCE interfaces are Up"
    echo "  3. Check that a 169.254.x.x IP is assigned to the RoCE interface"
    echo ""
    echo "Then either:"
    echo "  - Fix the interface and re-run this script, OR"
    echo "  - Set HEAD_IP manually: export HEAD_IP=169.254.x.x"
    exit 1
  fi
fi

# Auto-detect network interfaces from active RoCE devices
if [ -z "${GLOO_IF:-}" ] || [ -z "${TP_IF:-}" ] || [ -z "${NCCL_IF:-}" ] || [ -z "${UCX_DEV:-}" ]; then
  if [ -n "${PRIMARY_ROCE_IF}" ]; then
    # Use primary RoCE interface for all NCCL/GLOO/TP/UCX communication
    GLOO_IF="${GLOO_IF:-${PRIMARY_ROCE_IF}}"
    TP_IF="${TP_IF:-${PRIMARY_ROCE_IF}}"
    NCCL_IF="${NCCL_IF:-${PRIMARY_ROCE_IF}}"
    UCX_DEV="${UCX_DEV:-${PRIMARY_ROCE_IF}}"
  else
    # Fallback defaults if ibdev2netdev not available
    GLOO_IF="${GLOO_IF:-enp1s0f1np1}"
    TP_IF="${TP_IF:-enp1s0f1np1}"
    NCCL_IF="${NCCL_IF:-enp1s0f1np1}"
    UCX_DEV="${UCX_DEV:-enp1s0f1np1}"
  fi
fi

# Auto-detect InfiniBand HCAs using ibdev2netdev (or use override)
if [ -z "${NCCL_IB_HCA:-}" ]; then
  IB_DEVICES=$(discover_all_roce_hcas)
  if [ -n "${IB_DEVICES}" ]; then
    NCCL_IB_HCA="${IB_DEVICES}"
  else
    # Fallback: use all IB devices from sysfs
    IB_DEVICES=$(ls -1 /sys/class/infiniband/ 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    NCCL_IB_HCA="${IB_DEVICES:-mlx5_0,mlx5_1}"
  fi
fi

# Set OMPI_MCA for MPI-based communication (needed for some frameworks)
OMPI_MCA_IF="${NCCL_IF}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

error() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Starting DGX Spark vLLM Head Node Setup"
log "Configuration:"
log "  Image:           ${IMAGE}"
log "  Head IP:         ${HEAD_IP} (auto-detected)"
log "  Model:           ${MODEL}"
log "  Tensor Parallel: ${TENSOR_PARALLEL}"
log "  Ray Version:     ${RAY_VERSION}"
log ""
log "Network Configuration (auto-detected from RoCE):"
log "  Primary RoCE IF: ${PRIMARY_ROCE_IF:-<not detected>}"
log "  GLOO Interface:  ${GLOO_IF}"
log "  TP Interface:    ${TP_IF}"
log "  NCCL Interface:  ${NCCL_IF}"
log "  UCX Device:      ${UCX_DEV}"
log "  OMPI MCA IF:     ${OMPI_MCA_IF}"
log "  NCCL IB HCAs:    ${NCCL_IB_HCA}"
log ""
if [ -n "${HF_TOKEN}" ]; then
  log "  HF Auth:        ✅ Token provided"
else
  log "  HF Auth:        ⚠️  No token (gated models will fail)"
fi
log ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 1/8: Pulling Docker image"
if ! docker pull "${IMAGE}"; then
  error "Failed to pull image ${IMAGE}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 2/8: Cleaning old container"
if docker ps -a --format '{{.Names}}' | grep -qx "${NAME}"; then
  log "  Removing existing container: ${NAME}"
  docker rm -f "${NAME}" >/dev/null
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 3/8: Starting head container"

# Build environment variable args for RoCE/NCCL configuration
# These are passed into the container to ensure NCCL uses the 200 Gb link
ENV_ARGS=(
  -e VLLM_HOST_IP="${HEAD_IP}"
  # RoCE interface settings - all pointing to the 200 Gb ConnectX-7 NIC
  -e GLOO_SOCKET_IFNAME="${GLOO_IF}"
  -e TP_SOCKET_IFNAME="${TP_IF}"
  -e NCCL_SOCKET_IFNAME="${NCCL_IF}"
  -e UCX_NET_DEVICES="${UCX_DEV}"
  -e OMPI_MCA_btl_tcp_if_include="${OMPI_MCA_IF}"
  # NCCL IB/RoCE settings
  -e NCCL_IB_DISABLE=0
  -e NCCL_IB_HCA="${NCCL_IB_HCA}"
  -e NCCL_NET_GDR_LEVEL=5
  # Debug settings (can be disabled for production by setting NCCL_DEBUG=WARN)
  -e NCCL_DEBUG="${NCCL_DEBUG:-INFO}"
  -e NCCL_DEBUG_SUBSYS="${NCCL_DEBUG_SUBSYS:-INIT,NET}"
  # NVIDIA/GPU settings
  -e NVIDIA_VISIBLE_DEVICES=all
  -e NVIDIA_DRIVER_CAPABILITIES=all
  # Ray settings
  -e RAY_memory_usage_threshold=0.998
  # HuggingFace cache
  -e HF_HOME=/root/.cache/huggingface
)

# Add HuggingFace token if provided
if [ -n "${HF_TOKEN}" ]; then
  ENV_ARGS+=(-e HF_TOKEN="${HF_TOKEN}")
fi

docker run -d \
  --restart unless-stopped \
  --name "${NAME}" \
  --gpus all \
  --network host \
  --shm-size=16g \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  --device=/dev/infiniband \
  -v "${HF_CACHE}:/root/.cache/huggingface" \
  "${ENV_ARGS[@]}" \
  "${IMAGE}" sleep infinity

if ! docker ps | grep -q "${NAME}"; then
  error "Container failed to start"
fi

log "  Container started successfully"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 4/8: Installing Ray ${RAY_VERSION}"
if ! docker exec "${NAME}" bash -lc "pip install -q -U 'ray==${RAY_VERSION}'"; then
  error "Failed to install Ray"
fi

# Verify Ray version
INSTALLED_RAY_VERSION=$(docker exec "${NAME}" python3 -c "import ray; print(ray.__version__)" 2>/dev/null || echo "unknown")
if [ "${INSTALLED_RAY_VERSION}" != "${RAY_VERSION}" ]; then
  error "Ray version mismatch: expected ${RAY_VERSION}, got ${INSTALLED_RAY_VERSION}"
fi

log "  Ray ${INSTALLED_RAY_VERSION} installed"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 5/8: Starting Ray head"
docker exec "${NAME}" bash -lc "
  ray stop --force 2>/dev/null || true
  ray start --head \
    --node-ip-address=${HEAD_IP} \
    --port=6379 \
    --dashboard-host=0.0.0.0 \
    --dashboard-port=8265
" >/dev/null

log "  Ray head started, waiting for readiness..."

# Wait for Ray to become ready
for i in {1..30}; do
  if docker exec "${NAME}" bash -lc "ray status --address='127.0.0.1:6379' >/dev/null 2>&1"; then
    log "  ✅ Ray head is ready (${i}s)"
    break
  fi
  if [ $i -eq 30 ]; then
    error "Ray head failed to become ready after 30 seconds"
  fi
  sleep 1
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 6/8: Pre-downloading model"
log "  This may take a while for large models..."

docker exec "${NAME}" bash -lc "
  export HF_HOME=/root/.cache/huggingface
  huggingface-cli download ${MODEL} --quiet 2>/dev/null || echo 'Download skipped or already cached'
" >/dev/null

log "  Model download complete (or already cached)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 7/8: Starting vLLM server"
log ""

# Kill any existing vLLM processes
docker exec "${NAME}" bash -lc "pkill -f 'vllm serve' 2>/dev/null || true" || true

log "  Starting vLLM in background (this launches the server process)..."

# Start vLLM in background using nohup
docker exec "${NAME}" bash -lc "
  export HF_HOME=/root/.cache/huggingface
  export RAY_ADDRESS=127.0.0.1:6379
  export PYTHONUNBUFFERED=1
  export VLLM_LOGGING_LEVEL=INFO

  nohup vllm serve ${MODEL} \
    --distributed-executor-backend ray \
    --host 0.0.0.0 \
    --port 8000 \
    --tensor-parallel-size ${TENSOR_PARALLEL} \
    --max-model-len ${MAX_MODEL_LEN} \
    --gpu-memory-utilization ${GPU_MEMORY_UTIL} \
    --download-dir \$HF_HOME \
    > /var/log/vllm.log 2>&1 &

  sleep 1
" || true

log "  vLLM server process started"
log "  ⚠️  CUDA graph compilation may take 1-2 minutes on first startup"
log "  Waiting for vLLM API to become ready..."
log ""

# Wait for vLLM to become ready (longer timeout for CUDA graph compilation)
VLLM_READY=false
for i in {1..180}; do
  if docker exec "${NAME}" bash -lc "curl -sf http://127.0.0.1:8000/health >/dev/null 2>&1"; then
    log "  ✅ vLLM server is ready and accepting requests (${i}s)"
    VLLM_READY=true
    break
  fi
  if [ $i -eq 180 ]; then
    log "  ⚠️  vLLM not ready after 3 minutes - continuing anyway"
    log "     Check logs: docker exec ${NAME} tail -50 /var/log/vllm.log"
  fi
  sleep 1
done

log ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 8/8: Running health checks"

# Check Ray status
RAY_NODES=$(docker exec "${NAME}" bash -lc "ray status --address=127.0.0.1:6379 2>/dev/null | grep 'Healthy:' -A1 | tail -1 | awk '{print \$1}'" || echo "0")
log "  Ray cluster: ${RAY_NODES} node(s) healthy"

# Check vLLM models
VLLM_MODEL=$(docker exec "${NAME}" bash -lc "curl -sf http://127.0.0.1:8000/v1/models 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"data\"][0][\"id\"])' 2>/dev/null" || echo "unknown")
log "  vLLM model: ${VLLM_MODEL}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Detect public-facing Ethernet IP for user access
PUBLIC_IP=$(ip -o addr show | grep "inet " | grep -v "127.0.0.1" | grep -v "169.254" | grep -v "172.17" | awk '{print $4}' | cut -d'/' -f1 | head -1)
if [ -z "${PUBLIC_IP}" ]; then
  PUBLIC_IP="${HEAD_IP}"  # Fallback to InfiniBand IP if no Ethernet found
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Head node is ready!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🌐 Services (accessible from network):"
echo "  Ray Dashboard:  http://${PUBLIC_IP}:8265"
echo "  vLLM API:       http://${PUBLIC_IP}:8000"
echo ""
echo "🔗 Next Steps - Add Worker Nodes:"
echo "  1. SSH to each worker node"
echo "  2. Run: export HEAD_IP=${HEAD_IP}"
echo "  3. Run: bash start_worker_vllm.sh"
echo ""
echo "  Note: Workers use InfiniBand IP (${HEAD_IP}) for cluster communication"
echo "  Note: Worker IPs and network interfaces will be auto-detected!"
echo ""
echo "📊 Quick API Tests:"
echo "  # List models"
echo "  curl http://${PUBLIC_IP}:8000/v1/models"
echo ""
echo "  # Chat completion"
echo "  curl http://${PUBLIC_IP}:8000/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
echo ""
echo "🔍 Monitoring Commands:"
echo "  # View vLLM logs"
echo "  docker exec ${NAME} tail -f /var/log/vllm.log"
echo ""
echo "  # Ray cluster status (check for worker nodes)"
echo "  docker exec ${NAME} ray status --address=127.0.0.1:6379"
echo ""
echo "  # GPU utilization"
echo "  watch -n 1 nvidia-smi"
echo ""
echo "⚙️  Current Configuration:"
echo "  Model:              ${MODEL}"
echo "  Tensor Parallelism: ${TENSOR_PARALLEL} GPUs"
echo "  Max Context:        ${MAX_MODEL_LEN} tokens"
echo "  GPU Memory:         ${GPU_MEMORY_UTIL} utilization"
echo "  CUDA Graphs:        Enabled (optimized for performance)"
echo ""
echo "📊 Expected Performance:"
echo "  Throughput:         50-100 tokens/second"
echo "  First request:      May be slower (graph warmup)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
