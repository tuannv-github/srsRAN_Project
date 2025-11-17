#!/bin/bash

# Script to create VLAN interface ens12f0np0.564 with VLAN 564 and MAC address
# This is for use when NOT using DPDK (regular socket-based Ethernet receiver)

IF_NAME="ens12f0np0"
VLAN_ID=564
VLAN_IF="${IF_NAME}.${VLAN_ID}"
MAC_ADDRESS="7a:a1:ab:00:f3:10"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (with sudo)."
    exit 1
fi

echo "Setting up VLAN interface ${VLAN_IF}..."

# Remove existing VLAN interface if it exists
if ip link show ${VLAN_IF} &>/dev/null; then
    echo "Removing existing VLAN interface ${VLAN_IF}..."
    ip link delete ${VLAN_IF} 2>/dev/null || true
fi

# Ensure parent interface is up
echo "Bringing up parent interface ${IF_NAME}..."
ip link set ${IF_NAME} up
if [ $? -ne 0 ]; then
    echo "Failed to bring up parent interface ${IF_NAME}"
    exit 1
fi

# Create VLAN interface
echo "Creating VLAN interface ${VLAN_IF} with VLAN ID ${VLAN_ID}..."
ip link add link ${IF_NAME} name ${VLAN_IF} type vlan id ${VLAN_ID}
if [ $? -ne 0 ]; then
    echo "Failed to create VLAN interface ${VLAN_IF}"
    exit 1
fi

# Set MAC address
echo "Setting MAC address ${MAC_ADDRESS} on ${VLAN_IF}..."
ip link set ${VLAN_IF} address ${MAC_ADDRESS}
if [ $? -ne 0 ]; then
    echo "Failed to set MAC address on ${VLAN_IF}"
    # Clean up on failure
    ip link delete ${VLAN_IF} 2>/dev/null || true
    exit 1
fi

# Bring up the VLAN interface
echo "Bringing up VLAN interface ${VLAN_IF}..."
ip link set ${VLAN_IF} up
if [ $? -ne 0 ]; then
    echo "Failed to bring up VLAN interface ${VLAN_IF}"
    exit 1
fi

# Verify configuration
echo ""
echo "VLAN interface configuration:"
ip link show ${VLAN_IF}
echo ""
echo "Interface status:"
ip addr show ${VLAN_IF}

echo ""
echo "VLAN interface ${VLAN_IF} configured successfully!"
echo "  - VLAN ID: ${VLAN_ID}"
echo "  - MAC address: ${MAC_ADDRESS}"

