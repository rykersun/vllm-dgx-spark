#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# DGX Spark vLLM Worker Node - Production Setup Script
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Configuration
IMAGE="${IMAGE:-nvcr.io/nvidia/vllm:25.10-py3}"
RAY_VERSION="${RAY_VERSION:-2.51.0}"
HF_CACHE="${HF_CACHE:-/raid/hf-cache}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Auto-detect Network Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# DGX Spark uses RoCE (RDMA over Converged Ethernet) with ConnectX-7 NICs.
# Interface names are enp1s0f1np1 or enP2p1s0f1np1, NOT ib0/ib1.
# We prefer enp1* interfaces over enP2p* per NVIDIA's NCCL playbook.
# WORKER_IP must be the 169.254.x.x link-local address on the RoCE interface.
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

# HEAD_IP is required - must be provided (it's the head node's RoCE IP)
if [ -z "${HEAD_IP:-}" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "❌ ERROR: HEAD_IP is not set"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "⚠️  The HEAD_IP environment variable must be set before starting a worker node."
  echo ""
  echo "Prerequisites:"
  echo "  1. ✅ Head node must be running first"
  echo "  2. ✅ You need the head node's RoCE/InfiniBand IP (169.254.x.x)"
  echo ""
  echo "To find the head node IP:"
  echo "  - Check the output from start_head_vllm.sh (shown as 'Head IP')"
  echo "  - OR run on head node: ibdev2netdev  # to find the RoCE interface"
  echo "  - Then: ip addr show <interface> | grep 169.254"
  echo ""
  echo "Then set HEAD_IP and run this script:"
  echo "  export HEAD_IP=169.254.x.x  # Use your head node's RoCE IP"
  echo "  bash start_worker_vllm.sh"
  echo ""
  echo "Note: Everything else (WORKER_IP, network interfaces) will be auto-detected!"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  exit 1
fi

# Auto-detect WORKER_IP from RoCE interface (or use override)
if [ -z "${WORKER_IP:-}" ]; then
  if [ -n "${PRIMARY_ROCE_IF}" ]; then
    WORKER_IP=$(get_roce_ip "${PRIMARY_ROCE_IF}")
  fi
  # Final fallback if auto-detection fails
  if [ -z "${WORKER_IP:-}" ]; then
    echo "ERROR: Could not auto-detect WORKER_IP from RoCE interface."
    echo ""
    echo "Please ensure:"
    echo "  1. The 200 Gb cable is connected between Spark nodes"
    echo "  2. Run 'ibdev2netdev' to verify RoCE interfaces are Up"
    echo "  3. Check that a 169.254.x.x IP is assigned to the RoCE interface"
    echo ""
    echo "Then either:"
    echo "  - Fix the interface and re-run this script, OR"
    echo "  - Set WORKER_IP manually: export WORKER_IP=169.254.x.x"
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

# Generate unique worker name based on hostname
WORKER_NAME="ray-worker-$(hostname -s)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

error() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
  exit 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Starting DGX Spark vLLM Worker Setup"
log "Configuration:"
log "  Image:         ${IMAGE}"
log "  Worker Name:   ${WORKER_NAME}"
log "  Head IP:       ${HEAD_IP}"
log "  Worker IP:     ${WORKER_IP} (auto-detected)"
log "  Ray Version:   ${RAY_VERSION}"
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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 1/6: Testing connectivity to head"
if ! nc -zv -w 3 "${HEAD_IP}" 6379 2>&1 | grep -q "succeeded"; then
  error "Cannot reach Ray head at ${HEAD_IP}:6379. Check network connectivity and firewall."
fi
log "  ✅ Head is reachable"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 2/6: Pulling Docker image"
if ! docker pull "${IMAGE}"; then
  error "Failed to pull image ${IMAGE}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 3/6: Cleaning old container"
if docker ps -a --format '{{.Names}}' | grep -qx "${WORKER_NAME}"; then
  log "  Removing existing container: ${WORKER_NAME}"
  docker rm -f "${WORKER_NAME}" >/dev/null
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 4/6: Starting worker container"

# Build environment variable args for RoCE/NCCL configuration
# These are passed into the container to ensure NCCL uses the 200 Gb link
docker run -d \
  --restart unless-stopped \
  --name "${WORKER_NAME}" \
  --gpus all \
  --network host \
  --shm-size=16g \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  --device=/dev/infiniband \
  -v "${HF_CACHE}:/root/.cache/huggingface" \
  -e VLLM_HOST_IP="${WORKER_IP}" \
  -e GLOO_SOCKET_IFNAME="${GLOO_IF}" \
  -e TP_SOCKET_IFNAME="${TP_IF}" \
  -e NCCL_SOCKET_IFNAME="${NCCL_IF}" \
  -e UCX_NET_DEVICES="${UCX_DEV}" \
  -e OMPI_MCA_btl_tcp_if_include="${OMPI_MCA_IF}" \
  -e NCCL_IB_DISABLE=0 \
  -e NCCL_IB_HCA="${NCCL_IB_HCA}" \
  -e NCCL_NET_GDR_LEVEL=5 \
  -e NCCL_DEBUG="${NCCL_DEBUG:-INFO}" \
  -e NCCL_DEBUG_SUBSYS="${NCCL_DEBUG_SUBSYS:-INIT,NET}" \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e RAY_memory_usage_threshold=0.995 \
  "${IMAGE}" sleep infinity

if ! docker ps | grep -q "${WORKER_NAME}"; then
  error "Container failed to start"
fi

log "  Container started successfully"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 5/6: Installing Ray ${RAY_VERSION}"
if ! docker exec "${WORKER_NAME}" bash -lc "pip install -q -U 'ray==${RAY_VERSION}'"; then
  error "Failed to install Ray"
fi

# Verify Ray version
INSTALLED_RAY_VERSION=$(docker exec "${WORKER_NAME}" python3 -c "import ray; print(ray.__version__)" 2>/dev/null || echo "unknown")
if [ "${INSTALLED_RAY_VERSION}" != "${RAY_VERSION}" ]; then
  error "Ray version mismatch: expected ${RAY_VERSION}, got ${INSTALLED_RAY_VERSION}"
fi

log "  Ray ${INSTALLED_RAY_VERSION} installed"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Step 6/6: Joining Ray cluster"
docker exec "${WORKER_NAME}" bash -lc "
  ray stop --force 2>/dev/null || true
  ray start --address=${HEAD_IP}:6379 --node-ip-address=${WORKER_IP}
" >/dev/null

log "  Worker started, waiting for cluster registration..."

# Wait for worker to join cluster
for i in {1..30}; do
  if docker exec "${WORKER_NAME}" bash -lc "ray status --address=${HEAD_IP}:6379 2>/dev/null | grep -q 'Healthy:'" 2>/dev/null; then
    log "  ✅ Worker connected to cluster (${i}s)"
    break
  fi
  if [ $i -eq 30 ]; then
    log "  ⚠️  Worker may not be connected after 30s"
    log "     Check cluster status from head:"
    log "     docker exec ray-head ray status --address=127.0.0.1:6379"
  fi
  sleep 1
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Worker ${WORKER_NAME} is ready!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🔍 Verify from head node:"
echo "  docker exec ray-head ray status --address=127.0.0.1:6379"
echo ""
echo "📊 Expected output should show multiple 'Healthy' nodes"
echo ""
echo "🌐 Ray Dashboard: http://${HEAD_IP}:8265"
echo "   (Check 'Cluster' tab to see all nodes)"
echo ""
echo "⚙️  To increase parallelism, update head vLLM with:"
echo "  --tensor-parallel-size <num_total_gpus>"
echo ""
echo "🔧 Worker logs:"
echo "  docker logs -f ${WORKER_NAME}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
