#!/bin/bash

################################################################################
# InfiniBand/RoCE Diagnostic Script for DGX Spark
#
# This script checks RoCE (RDMA over Converged Ethernet) connectivity and
# configuration for the 200 Gb ConnectX-7 links between DGX Spark nodes.
#
# Key insight: DGX Spark uses RoCE, not traditional InfiniBand. The interfaces
# are named enp1s0f1np1 or enP2p1s0f1np1, NOT ib0/ib1.
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}RoCE/InfiniBand Diagnostic Check${NC}"
echo -e "${BLUE}DGX Spark 200 Gb Link Verification${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. Check for Mellanox/NVIDIA hardware
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo -e "${YELLOW}1. Checking for Mellanox/NVIDIA ConnectX Hardware...${NC}"
if lspci | grep -i -E "mellanox|nvidia.*connectx" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ ConnectX hardware detected:${NC}"
    lspci | grep -i -E "mellanox|nvidia.*connectx"
else
    echo -e "${RED}✗ No Mellanox/NVIDIA ConnectX hardware found${NC}"
fi
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. Check if IB tools are installed
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo -e "${YELLOW}2. Checking InfiniBand Tools Installation...${NC}"
TOOLS_OK=true

if command -v ibdev2netdev > /dev/null 2>&1; then
    echo -e "${GREEN}✓ ibdev2netdev is installed (CRITICAL for RoCE detection)${NC}"
else
    echo -e "${RED}✗ ibdev2netdev is NOT installed${NC}"
    echo -e "  Install with: ${GREEN}sudo apt-get install infiniband-diags${NC}"
    TOOLS_OK=false
fi

if command -v ibstat > /dev/null 2>&1; then
    echo -e "${GREEN}✓ ibstat is installed${NC}"
else
    echo -e "${RED}✗ ibstat is NOT installed${NC}"
fi

if command -v ibstatus > /dev/null 2>&1; then
    echo -e "${GREEN}✓ ibstatus is installed${NC}"
else
    echo -e "${RED}✗ ibstatus is NOT installed${NC}"
fi
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. Check IB kernel modules
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo -e "${YELLOW}3. Checking InfiniBand/RoCE Kernel Modules...${NC}"
IB_MODULES=$(lsmod | grep -E '^ib_|^rdma|^mlx')
if [ -n "$IB_MODULES" ]; then
    echo -e "${GREEN}✓ RDMA/InfiniBand kernel modules loaded:${NC}"
    echo "$IB_MODULES"
else
    echo -e "${RED}✗ No InfiniBand/RDMA kernel modules loaded${NC}"
fi
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. Check IB devices
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo -e "${YELLOW}4. Checking InfiniBand/RoCE Devices...${NC}"
if [ -d /dev/infiniband ]; then
    echo -e "${GREEN}✓ InfiniBand devices found:${NC}"
    ls -la /dev/infiniband/
else
    echo -e "${RED}✗ No InfiniBand devices at /dev/infiniband/${NC}"
fi
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. CRITICAL: Detect RoCE devices using ibdev2netdev
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo -e "${YELLOW}5. Detecting RoCE Devices (ibdev2netdev)...${NC}"
echo -e "${BLUE}   NOTE: DGX Spark uses RoCE, not traditional IB. Interfaces are named${NC}"
echo -e "${BLUE}   enp1s0f1np1 or enP2p1s0f1np1, NOT ib0/ib1!${NC}"
echo ""

ROCE_DETECTED=false
ACTIVE_ROCE_IF=""
ACTIVE_ROCE_HCA=""
ACTIVE_ROCE_IP=""

if command -v ibdev2netdev > /dev/null 2>&1; then
    echo "All RoCE/IB devices:"
    ibdev2netdev 2>&1 | while read line; do
        echo "  $line"
    done
    echo ""

    # Find active (Up) RoCE interfaces, preferring enp1* over enP2p*
    ACTIVE_LINE=$(ibdev2netdev 2>/dev/null | awk '/\(Up\)/ {print;}' | grep 'enp1' | head -n1)
    if [ -z "$ACTIVE_LINE" ]; then
        ACTIVE_LINE=$(ibdev2netdev 2>/dev/null | awk '/\(Up\)/ {print;}' | head -n1)
    fi

    if [ -n "$ACTIVE_LINE" ]; then
        ROCE_DETECTED=true
        ACTIVE_ROCE_HCA=$(echo "$ACTIVE_LINE" | awk '{print $1}')
        ACTIVE_ROCE_IF=$(echo "$ACTIVE_LINE" | awk '{print $5}' | tr -d '()')

        echo -e "${GREEN}✓ Active RoCE interface detected:${NC}"
        echo -e "  HCA Device:  ${GREEN}${ACTIVE_ROCE_HCA}${NC}"
        echo -e "  Net Device:  ${GREEN}${ACTIVE_ROCE_IF}${NC}"

        # Get the 169.254.x.x IP from this interface
        ACTIVE_ROCE_IP=$(ip -o addr show "${ACTIVE_ROCE_IF}" 2>/dev/null | grep "inet " | awk '{print $4}' | cut -d'/' -f1 | grep "^169\.254\." | head -1)
        if [ -z "$ACTIVE_ROCE_IP" ]; then
            # Fall back to any IP on the interface
            ACTIVE_ROCE_IP=$(ip -o addr show "${ACTIVE_ROCE_IF}" 2>/dev/null | grep "inet " | awk '{print $4}' | cut -d'/' -f1 | head -1)
        fi

        if [ -n "$ACTIVE_ROCE_IP" ]; then
            echo -e "  IP Address:  ${GREEN}${ACTIVE_ROCE_IP}${NC}"
        else
            echo -e "  IP Address:  ${RED}No IP assigned${NC}"
        fi
        echo ""

        # List all active interfaces
        echo "All active RoCE interfaces:"
        ibdev2netdev 2>/dev/null | grep "(Up)" | while read line; do
            echo -e "  ${GREEN}$line${NC}"
        done
    else
        echo -e "${RED}✗ No active (Up) RoCE interfaces found${NC}"
        echo ""
        echo "Inactive interfaces:"
        ibdev2netdev 2>/dev/null | grep "(Down)" | while read line; do
            echo -e "  ${RED}$line${NC}"
        done
    fi
else
    echo -e "${RED}✗ ibdev2netdev not available - cannot detect RoCE interfaces${NC}"
    echo -e "  Install with: ${GREEN}sudo apt-get install infiniband-diags${NC}"
fi
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6. Show interface details
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo -e "${YELLOW}6. RoCE Interface IP Configuration...${NC}"
if [ -n "$ACTIVE_ROCE_IF" ]; then
    echo "Details for ${ACTIVE_ROCE_IF}:"
    ip addr show "${ACTIVE_ROCE_IF}" 2>/dev/null | head -10
else
    echo "Looking for 169.254.x.x addresses (link-local for RoCE):"
    ip addr show 2>/dev/null | grep -B2 "169.254" | head -10
fi
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 7. Check IB port status
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo -e "${YELLOW}7. Checking InfiniBand/RoCE Port Status...${NC}"
if command -v ibstat > /dev/null 2>&1; then
    ibstat 2>&1
else
    echo -e "${YELLOW}⚠ Skipping (ibstat not installed)${NC}"
fi
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 8. Check current NCCL environment
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo -e "${YELLOW}8. Checking NCCL/UCX Environment Variables...${NC}"
echo "Current shell environment:"
[ -n "$NCCL_IB_DISABLE" ] && echo "  NCCL_IB_DISABLE=$NCCL_IB_DISABLE" || echo "  NCCL_IB_DISABLE=(not set)"
[ -n "$NCCL_SOCKET_IFNAME" ] && echo "  NCCL_SOCKET_IFNAME=$NCCL_SOCKET_IFNAME" || echo "  NCCL_SOCKET_IFNAME=(not set)"
[ -n "$NCCL_IB_HCA" ] && echo "  NCCL_IB_HCA=$NCCL_IB_HCA" || echo "  NCCL_IB_HCA=(not set)"
[ -n "$UCX_NET_DEVICES" ] && echo "  UCX_NET_DEVICES=$UCX_NET_DEVICES" || echo "  UCX_NET_DEVICES=(not set)"
[ -n "$OMPI_MCA_btl_tcp_if_include" ] && echo "  OMPI_MCA_btl_tcp_if_include=$OMPI_MCA_btl_tcp_if_include" || echo "  OMPI_MCA_btl_tcp_if_include=(not set)"
[ -n "$GLOO_SOCKET_IFNAME" ] && echo "  GLOO_SOCKET_IFNAME=$GLOO_SOCKET_IFNAME" || echo "  GLOO_SOCKET_IFNAME=(not set)"
[ -n "$TP_SOCKET_IFNAME" ] && echo "  TP_SOCKET_IFNAME=$TP_SOCKET_IFNAME" || echo "  TP_SOCKET_IFNAME=(not set)"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 9. Check NCCL environment in Ray container
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo -e "${YELLOW}9. Checking NCCL Configuration in Ray Container...${NC}"
if docker ps --format '{{.Names}}' | grep -q '^ray-head$'; then
    echo "NCCL/UCX/network environment in ray-head container:"
    docker exec ray-head bash -c 'env | grep -E "NCCL|UCX|GLOO|TP_SOCKET|OMPI" | sort' 2>&1 || echo "  (none found)"
else
    echo -e "${YELLOW}⚠ ray-head container not running${NC}"
fi
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 10. Summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}SUMMARY${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

HAS_HARDWARE=$(lspci | grep -i -E "mellanox|nvidia.*connectx" > /dev/null 2>&1 && echo "yes" || echo "no")
HAS_TOOLS=$(command -v ibdev2netdev > /dev/null 2>&1 && echo "yes" || echo "no")
HAS_DEVICES=$([ -d /dev/infiniband ] && echo "yes" || echo "no")

# Re-detect for summary (since we're in a new scope)
if command -v ibdev2netdev > /dev/null 2>&1; then
    ACTIVE_LINE=$(ibdev2netdev 2>/dev/null | awk '/\(Up\)/ {print;}' | grep 'enp1' | head -n1)
    [ -z "$ACTIVE_LINE" ] && ACTIVE_LINE=$(ibdev2netdev 2>/dev/null | awk '/\(Up\)/ {print;}' | head -n1)
    if [ -n "$ACTIVE_LINE" ]; then
        HAS_ACTIVE_ROCE="yes"
        DETECTED_IF=$(echo "$ACTIVE_LINE" | awk '{print $5}' | tr -d '()')
        DETECTED_HCA=$(echo "$ACTIVE_LINE" | awk '{print $1}')
        DETECTED_IP=$(ip -o addr show "${DETECTED_IF}" 2>/dev/null | grep "inet " | awk '{print $4}' | cut -d'/' -f1 | grep "^169\.254\." | head -1)
        [ -z "$DETECTED_IP" ] && DETECTED_IP=$(ip -o addr show "${DETECTED_IF}" 2>/dev/null | grep "inet " | awk '{print $4}' | cut -d'/' -f1 | head -1)
    else
        HAS_ACTIVE_ROCE="no"
    fi
else
    HAS_ACTIVE_ROCE="unknown"
fi

echo "ConnectX Hardware Present:    $HAS_HARDWARE"
echo "IB Diagnostic Tools:          $HAS_TOOLS"
echo "InfiniBand Devices:           $HAS_DEVICES"
echo "Active RoCE Interface:        $HAS_ACTIVE_ROCE"
if [ "$HAS_ACTIVE_ROCE" = "yes" ]; then
    echo "  Detected Interface:         $DETECTED_IF"
    echo "  Detected HCA:               $DETECTED_HCA"
    echo "  Detected IP:                ${DETECTED_IP:-none}"
fi
echo ""

if [ "$HAS_HARDWARE" = "yes" ] && [ "$HAS_ACTIVE_ROCE" = "yes" ]; then
    echo -e "${GREEN}✓ RoCE 200 Gb link appears to be available!${NC}"
    echo ""
    echo -e "${YELLOW}Detected Configuration:${NC}"
    echo "  Interface: $DETECTED_IF"
    echo "  HCA:       $DETECTED_HCA"
    echo "  IP:        ${DETECTED_IP:-<needs configuration>}"
    echo ""
    echo -e "${YELLOW}Verify Connectivity:${NC}"
    echo "  # Test RDMA bandwidth between two Spark nodes:"
    echo "  # On server: ib_write_bw -d $DETECTED_HCA"
    echo "  # On client: ib_write_bw -d $DETECTED_HCA <server-ip>"
    echo ""
    echo "  # Monitor traffic on RoCE interface:"
    echo "  sudo iftop -i $DETECTED_IF"
elif [ "$HAS_HARDWARE" = "yes" ]; then
    echo -e "${YELLOW}⚠ ConnectX hardware present but no active RoCE interface${NC}"
    echo ""
    echo "Possible issues:"
    echo "- Cable not connected between Spark nodes"
    echo "- Link not brought up (check: ip link show)"
    echo "- No IP address configured on RoCE interface"
    echo ""
    echo "To bring up the link:"
    echo "  1. Connect the 200 Gb cable between Spark nodes"
    echo "  2. Identify the interface: ibdev2netdev"
    echo "  3. Bring it up: sudo ip link set <interface> up"
    echo "  4. Link-local IPs should auto-configure (169.254.x.x)"
else
    echo -e "${RED}✗ No ConnectX hardware detected${NC}"
fi

echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}RECOMMENDED NCCL/UCX CONFIGURATION${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

if [ "$HAS_ACTIVE_ROCE" = "yes" ]; then
    # Get all active HCAs for NCCL_IB_HCA
    ALL_HCAS=$(ibdev2netdev 2>/dev/null | grep "(Up)" | awk '{print $1}' | sort | tr '\n' ',' | sed 's/,$//')

    echo "For your detected RoCE configuration, use these environment variables:"
    echo ""
    echo -e "${GREEN}# RoCE Interface Settings${NC}"
    echo "export NCCL_SOCKET_IFNAME=${DETECTED_IF}"
    echo "export UCX_NET_DEVICES=${DETECTED_IF}"
    echo "export OMPI_MCA_btl_tcp_if_include=${DETECTED_IF}"
    echo "export GLOO_SOCKET_IFNAME=${DETECTED_IF}"
    echo "export TP_SOCKET_IFNAME=${DETECTED_IF}"
    echo ""
    echo -e "${GREEN}# NCCL IB/RoCE Settings${NC}"
    echo "export NCCL_IB_DISABLE=0"
    echo "export NCCL_IB_HCA=${ALL_HCAS:-$DETECTED_HCA}"
    echo "export NCCL_NET_GDR_LEVEL=5"
    echo ""
    echo -e "${GREEN}# Debug Settings (optional, for troubleshooting)${NC}"
    echo "export NCCL_DEBUG=INFO"
    echo "export NCCL_DEBUG_SUBSYS=INIT,NET"
    echo ""
    echo -e "${GREEN}# HEAD_IP / WORKER_IP should be the RoCE IP:${NC}"
    if [ -n "$DETECTED_IP" ]; then
        echo "export HEAD_IP=${DETECTED_IP}  # On head node"
        echo "export WORKER_IP=<worker-roce-ip>  # On worker node"
    else
        echo "# Run: ip addr show ${DETECTED_IF}"
        echo "# Use the 169.254.x.x address from that interface"
    fi
else
    echo "Cannot provide specific recommendations - no active RoCE interface detected."
    echo ""
    echo "Generic settings (update interface names based on your ibdev2netdev output):"
    echo ""
    echo "export NCCL_SOCKET_IFNAME=<your-roce-interface>"
    echo "export UCX_NET_DEVICES=<your-roce-interface>"
    echo "export OMPI_MCA_btl_tcp_if_include=<your-roce-interface>"
    echo "export NCCL_IB_DISABLE=0"
    echo "export NCCL_IB_HCA=<your-roce-hca>"
fi
echo ""

exit 0
