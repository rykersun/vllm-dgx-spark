#!/bin/bash

################################################################################
# GPU Utilization Monitor During Inference
#
# This script monitors GPU utilization while running an inference request
# to help identify if the bottleneck is compute-bound or network-bound.
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

VLLM_URL="${1:-http://localhost:8000}"
OUTPUT_FILE="gpu_utilization_$(date +%Y%m%d_%H%M%S).log"

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}GPU Utilization Monitor${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# Start inference request in background
echo -e "${YELLOW}Starting inference request...${NC}"
START_TIME=$(date +%s.%N)

curl -s -X POST "${VLLM_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.3-70B-Instruct",
    "messages": [
      {"role": "user", "content": "Write a detailed explanation of how neural networks work, including the mathematics behind backpropagation. Be thorough and detailed."}
    ],
    "max_tokens": 500,
    "temperature": 0.7
  }' > /tmp/inference_response.json 2>&1 &

CURL_PID=$!
echo -e "${CYAN}Inference request PID: ${CURL_PID}${NC}"
echo ""

# Wait a moment for request to start processing
sleep 1

# Monitor GPU utilization
echo -e "${BOLD}Monitoring GPU utilization (Head Node):${NC}"
echo ""
{
  echo "GPU Utilization Monitoring - $(date)"
  echo "========================================"
  echo ""
} > "$OUTPUT_FILE"

SAMPLE=0
while kill -0 $CURL_PID 2>/dev/null; do
  SAMPLE=$((SAMPLE + 1))
  TIMESTAMP=$(date +%H:%M:%S.%N | cut -c1-12)

  # Query head node GPU
  GPU_DATA=$(docker exec ray-head nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.used,power.draw --format=csv,noheader,nounits 2>/dev/null || echo "N/A,N/A,N/A,N/A")

  echo -e "${CYAN}[$TIMESTAMP] Sample ${SAMPLE}:${NC} GPU: ${GPU_DATA}" | tee -a "$OUTPUT_FILE"

  sleep 0.5
done

END_TIME=$(date +%s.%N)
ELAPSED=$(echo "$END_TIME - $START_TIME" | bc -l)

echo ""
echo -e "${GREEN}✓ Inference complete${NC}"
echo ""

# Parse response
if [ -f /tmp/inference_response.json ]; then
  COMPLETION_TOKENS=$(cat /tmp/inference_response.json | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null || echo "0")
  PROMPT_TOKENS=$(cat /tmp/inference_response.json | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['prompt_tokens'])" 2>/dev/null || echo "0")

  if [ "$COMPLETION_TOKENS" != "0" ]; then
    TOKENS_PER_SEC=$(echo "scale=2; $COMPLETION_TOKENS / $ELAPSED" | bc -l)

    echo -e "${BOLD}Results:${NC}"
    echo -e "  Completion tokens: ${COMPLETION_TOKENS}"
    echo -e "  Prompt tokens: ${PROMPT_TOKENS}"
    echo -e "  Total time: ${ELAPSED}s"
    echo -e "  ${BOLD}Throughput: ${TOKENS_PER_SEC} tokens/s${NC}"
    echo ""

    {
      echo ""
      echo "Results:"
      echo "  Completion tokens: ${COMPLETION_TOKENS}"
      echo "  Prompt tokens: ${PROMPT_TOKENS}"
      echo "  Total time: ${ELAPSED}s"
      echo "  Throughput: ${TOKENS_PER_SEC} tokens/s"
      echo ""
    } >> "$OUTPUT_FILE"
  else
    echo -e "${RED}✗ Failed to parse response${NC}"
    cat /tmp/inference_response.json
  fi
fi

# Analyze GPU utilization
echo -e "${BOLD}Analysis:${NC}"
AVG_GPU_UTIL=$(grep "Sample" "$OUTPUT_FILE" | grep -oP 'GPU: \K[0-9.]+' | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print 0}')

echo -e "  Average GPU utilization: ${AVG_GPU_UTIL}%"
echo ""

if (( $(echo "$AVG_GPU_UTIL < 30" | bc -l 2>/dev/null || echo 1) )); then
  echo -e "${RED}⚠️  LOW GPU UTILIZATION (<30%)${NC}"
  echo -e "   This suggests the bottleneck is NOT compute-bound."
  echo -e "   Possible causes:"
  echo -e "   - Network communication overhead (cross-node tensor parallelism)"
  echo -e "   - CPU bottleneck in preprocessing/postprocessing"
  echo -e "   - Small batch size (single request)"
  echo -e "   - Memory bandwidth limitations"
elif (( $(echo "$AVG_GPU_UTIL > 80" | bc -l 2>/dev/null || echo 0) )); then
  echo -e "${GREEN}✓ HIGH GPU UTILIZATION (>80%)${NC}"
  echo -e "   The GPUs are working hard. The bottleneck is compute-bound."
  echo -e "   This is expected for large models like 70B."
else
  echo -e "${YELLOW}⚠️  MODERATE GPU UTILIZATION (30-80%)${NC}"
  echo -e "   Mixed bottleneck - both compute and other factors."
fi

echo ""
echo -e "Detailed logs saved to: ${CYAN}${OUTPUT_FILE}${NC}"
echo ""
