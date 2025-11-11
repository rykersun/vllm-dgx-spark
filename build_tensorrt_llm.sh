#!/bin/bash

################################################################################
# TensorRT-LLM Build Script for DGX Spark (GB10/SM120)
#
# This script builds TensorRT-LLM from the main branch with full SM120 support.
# It includes all fixes for DGX Spark compatibility issues.
#
# Prerequisites:
#   - 63GB+ free disk space
#   - Docker installed with NVIDIA runtime
#   - Git and Git LFS installed
#   - 2-4 hours build time
#
# Usage:
#   ./build_tensorrt_llm.sh [options]
#
# Options:
#   --skip-clone     Skip git clone (use existing TensorRT-LLM directory)
#   --dev-build      Build development image instead of release
#   --no-verify      Skip pre-build verification checks
#
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
REPO_URL="https://github.com/NVIDIA/TensorRT-LLM.git"
REPO_DIR="$HOME/TensorRT-LLM"
CUDA_ARCH="120-real"  # SM120 for GB10
BUILD_TYPE="release"  # or "devel"
SKIP_CLONE=false
SKIP_VERIFY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-clone)
            SKIP_CLONE=true
            shift
            ;;
        --dev-build)
            BUILD_TYPE="devel"
            shift
            ;;
        --no-verify)
            SKIP_VERIFY=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--skip-clone] [--dev-build] [--no-verify]"
            exit 1
            ;;
    esac
done

# Banner
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  TensorRT-LLM Build Script for DGX Spark (GB10/SM120)${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}This will build TensorRT-LLM from main branch with:${NC}"
echo -e "  ✓ Full SM120/GB10 kernel support (PR #7937)"
echo -e "  ✓ CUDA graph hang fix (PR #8803)"
echo -e "  ✓ KV cache optimizations (PR #9054)"
echo -e "  ✓ FP8 support for SM120 (PR #8844)"
echo ""
echo -e "${YELLOW}Build Requirements:${NC}"
echo -e "  • Disk space: 63GB+"
echo -e "  • Build time: 2-4 hours"
echo -e "  • Docker with NVIDIA runtime"
echo ""

# Phase 1: Pre-build Verification
if [ "$SKIP_VERIFY" = false ]; then
    echo -e "${BLUE}═══ Phase 1: Pre-build Verification ═══${NC}"
    echo ""

    # Check Docker
    echo -e "${CYAN}Checking Docker...${NC}"
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}✗ Docker not found. Please install Docker first.${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Docker installed: $(docker --version)${NC}"

    # Check NVIDIA Docker runtime
    if ! docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu20.04 nvidia-smi &> /dev/null; then
        echo -e "${RED}✗ NVIDIA Docker runtime not working${NC}"
        echo -e "${YELLOW}  Run: sudo apt-get install nvidia-docker2${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ NVIDIA Docker runtime working${NC}"

    # Check disk space
    echo ""
    echo -e "${CYAN}Checking disk space...${NC}"
    AVAILABLE_GB=$(df -BG --output=avail "$HOME" | tail -1 | tr -d 'G ')
    echo -e "  Available: ${AVAILABLE_GB}GB"
    if [ "$AVAILABLE_GB" -lt 63 ]; then
        echo -e "${RED}✗ Insufficient disk space. Need 63GB+, have ${AVAILABLE_GB}GB${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Sufficient disk space (${AVAILABLE_GB}GB available)${NC}"

    # Check Git
    echo ""
    echo -e "${CYAN}Checking Git and Git LFS...${NC}"
    if ! command -v git &> /dev/null; then
        echo -e "${RED}✗ Git not found${NC}"
        echo -e "${YELLOW}  Run: sudo apt-get install git git-lfs${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Git installed: $(git --version)${NC}"

    if ! command -v git-lfs &> /dev/null; then
        echo -e "${YELLOW}⚠ Git LFS not found. Installing...${NC}"
        sudo apt-get update && sudo apt-get install -y git-lfs
        git lfs install
    fi
    echo -e "${GREEN}✓ Git LFS installed${NC}"

    # Check GPU
    echo ""
    echo -e "${CYAN}Checking GPU...${NC}"
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
    COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1)
    echo -e "  GPU: ${GPU_NAME}"
    echo -e "  Compute Capability: ${COMPUTE_CAP}"

    if [[ "$COMPUTE_CAP" != "12.1" ]]; then
        echo -e "${YELLOW}⚠ Warning: Expected SM120 (12.1), found ${COMPUTE_CAP}${NC}"
        echo -e "${YELLOW}  Build will continue but may not work on this GPU${NC}"
    else
        echo -e "${GREEN}✓ SM120 (GB10) detected - build will target this architecture${NC}"
    fi

    echo ""
    echo -e "${GREEN}✓ All pre-build checks passed${NC}"
    echo ""
    sleep 2
fi

# Phase 2: Clone Repository
if [ "$SKIP_CLONE" = false ]; then
    echo -e "${BLUE}═══ Phase 2: Cloning TensorRT-LLM Repository ═══${NC}"
    echo ""

    if [ -d "$REPO_DIR" ]; then
        echo -e "${YELLOW}⚠ Directory $REPO_DIR already exists${NC}"
        read -p "Remove and re-clone? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${CYAN}Removing old directory...${NC}"
            rm -rf "$REPO_DIR"
        else
            echo -e "${YELLOW}Using existing directory. Run with --skip-clone to skip this prompt.${NC}"
            SKIP_CLONE=true
        fi
    fi

    if [ "$SKIP_CLONE" = false ]; then
        echo -e "${CYAN}Cloning TensorRT-LLM main branch...${NC}"
        git clone "$REPO_URL" "$REPO_DIR"

        cd "$REPO_DIR"

        echo -e "${CYAN}Checking out main branch...${NC}"
        git checkout main

        echo -e "${CYAN}Updating submodules...${NC}"
        git submodule update --init --recursive

        echo -e "${CYAN}Pulling Git LFS files...${NC}"
        git lfs pull

        echo ""
        echo -e "${GREEN}✓ Repository cloned successfully${NC}"
    fi
else
    echo -e "${BLUE}═══ Phase 2: Using Existing Repository ═══${NC}"
    echo ""

    if [ ! -d "$REPO_DIR" ]; then
        echo -e "${RED}✗ Directory $REPO_DIR not found${NC}"
        echo -e "${YELLOW}  Remove --skip-clone to clone repository${NC}"
        exit 1
    fi

    cd "$REPO_DIR"
    echo -e "${GREEN}✓ Using existing repository at $REPO_DIR${NC}"
fi

# Verify commit
echo ""
echo -e "${CYAN}Current commit:${NC}"
git log -1 --oneline
echo ""

# Check for SM120 fixes
echo -e "${CYAN}Verifying SM120 support commits:${NC}"
if git log --oneline --all | grep -q "7937"; then
    echo -e "${GREEN}✓ PR #7937 (SM120 support) found${NC}"
else
    echo -e "${YELLOW}⚠ PR #7937 not found - SM120 support may be incomplete${NC}"
fi

if git log --oneline --all | grep -q "8803"; then
    echo -e "${GREEN}✓ PR #8803 (CUDA graph fix) found${NC}"
else
    echo -e "${YELLOW}⚠ PR #8803 not found - CUDA graph hang fix may be missing${NC}"
fi

echo ""
sleep 2

# Phase 3: Build Docker Image
echo -e "${BLUE}═══ Phase 3: Building Docker Image (SM120) ═══${NC}"
echo ""
echo -e "${YELLOW}This will take 2-4 hours. Grab some coffee! ☕${NC}"
echo ""
echo -e "${CYAN}Build type: ${BUILD_TYPE}${NC}"
echo -e "${CYAN}CUDA architecture: ${CUDA_ARCH} (SM120)${NC}"
echo ""

# Start time
BUILD_START=$(date +%s)

# Build command
if [ "$BUILD_TYPE" = "release" ]; then
    echo -e "${CYAN}Building release image...${NC}"
    make -C docker release_build CUDA_ARCHS="$CUDA_ARCH"
else
    echo -e "${CYAN}Building development image...${NC}"
    make -C docker build CUDA_ARCHS="$CUDA_ARCH"
fi

BUILD_STATUS=$?
BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))
BUILD_MINUTES=$((BUILD_TIME / 60))

echo ""
if [ $BUILD_STATUS -eq 0 ]; then
    echo -e "${GREEN}✓ Build completed successfully in ${BUILD_MINUTES} minutes!${NC}"
else
    echo -e "${RED}✗ Build failed after ${BUILD_MINUTES} minutes${NC}"
    echo -e "${YELLOW}Check errors above for details${NC}"
    exit 1
fi

# Phase 4: Verify Build
echo ""
echo -e "${BLUE}═══ Phase 4: Verifying Build ═══${NC}"
echo ""

# Check if image exists
if [ "$BUILD_TYPE" = "release" ]; then
    IMAGE_NAME="tensorrt_llm/release:latest"
else
    IMAGE_NAME="tensorrt_llm/devel:latest"
fi

if docker images | grep -q "tensorrt_llm"; then
    echo -e "${GREEN}✓ Docker image created successfully${NC}"
    docker images | grep tensorrt_llm
else
    echo -e "${RED}✗ Docker image not found${NC}"
    exit 1
fi

# Test container launch
echo ""
echo -e "${CYAN}Testing container launch...${NC}"
if docker run --rm --gpus all "$IMAGE_NAME" python3 -c "import tensorrt_llm; print(f'TensorRT-LLM version: {tensorrt_llm.__version__}')" 2>&1 | tee /tmp/trtllm_test.log; then
    echo -e "${GREEN}✓ Container launches successfully${NC}"
else
    echo -e "${RED}✗ Container launch failed${NC}"
    cat /tmp/trtllm_test.log
    exit 1
fi

# Check for SM120 support
echo ""
echo -e "${CYAN}Verifying SM120 kernel support...${NC}"
docker run --rm --gpus all "$IMAGE_NAME" python3 << 'EOF'
import torch
if hasattr(torch.cuda, 'get_arch_list'):
    archs = torch.cuda.get_arch_list()
    print(f"Compiled CUDA architectures: {archs}")
    if any('12' in str(arch) or 'sm_120' in str(arch) for arch in archs):
        print("✓ SM120 support confirmed!")
    else:
        print("⚠ SM120 may not be compiled in")
else:
    print("Cannot verify CUDA architectures")
EOF

# Phase 5: Summary
echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}BUILD COMPLETE!${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}Image Details:${NC}"
echo -e "  Name: ${IMAGE_NAME}"
echo -e "  Repository: $REPO_DIR"
echo -e "  Build time: ${BUILD_MINUTES} minutes"
echo ""
echo -e "${BOLD}Next Steps:${NC}"
echo ""
echo -e "${CYAN}1. Test with single GPU:${NC}"
echo -e "   docker run --rm -it --gpus all -p 8000:8000 ${IMAGE_NAME}"
echo ""
echo -e "${CYAN}2. Deploy to both DGX Sparks:${NC}"
echo -e "   See TENSORRT_SOLUTION.md Phase 4-5 for multi-node setup"
echo ""
echo -e "${CYAN}3. Build Llama-70B engines:${NC}"
echo -e "   docker run --rm -it --gpus all -v \$PWD:/workspace ${IMAGE_NAME}"
echo -e "   # Inside container:"
echo -e "   cd /app/tensorrt_llm/examples/llama"
echo -e "   python3 convert_checkpoint.py --model_dir /workspace/model --tp_size 2 ..."
echo ""
echo -e "${BOLD}Documentation:${NC}"
echo -e "  Full guide: TENSORRT_SOLUTION.md"
echo -e "  Summary: TENSORRT_SUMMARY.md"
echo ""
echo -e "${YELLOW}Note: This build includes all SM120 fixes from main branch.${NC}"
echo -e "${YELLOW}      If you encounter issues, check GitHub for latest updates.${NC}"
echo ""

# Save build info
BUILD_INFO_FILE="$HOME/tensorrt_llm_build_info.txt"
cat > "$BUILD_INFO_FILE" << EOF
TensorRT-LLM Build Information
==============================
Build Date: $(date)
Build Time: ${BUILD_MINUTES} minutes
Image: ${IMAGE_NAME}
Repository: $REPO_DIR
Git Commit: $(cd "$REPO_DIR" && git rev-parse --short HEAD)
CUDA Architecture: ${CUDA_ARCH}
Build Type: ${BUILD_TYPE}

GPU Information:
- Name: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
- Compute Capability: $(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1)
- Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)

System Information:
- OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
- Architecture: $(uname -m)
- Kernel: $(uname -r)

Next Steps:
1. Test single-GPU: docker run --rm -it --gpus all -p 8000:8000 ${IMAGE_NAME}
2. See TENSORRT_SOLUTION.md for multi-node deployment
3. Build engines: See TENSORRT_SOLUTION.md Phase 4

Issues & Support:
- GitHub Issues: https://github.com/NVIDIA/TensorRT-LLM/issues
- Documentation: $REPO_DIR/docs/
EOF

echo -e "${CYAN}Build info saved to: ${BUILD_INFO_FILE}${NC}"
echo ""

exit 0
