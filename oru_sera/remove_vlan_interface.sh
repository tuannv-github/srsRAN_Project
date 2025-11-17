#!/bin/bash

# Script to remove VLAN interface ens12f0np0.564

IF_NAME="ens12f0np0"
VLAN_ID=564
VLAN_IF="${IF_NAME}.${VLAN_ID}"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (with sudo)."
    exit 1
fi

echo "Removing VLAN interface ${VLAN_IF}..."

# Check if VLAN interface exists
if ! ip link show ${VLAN_IF} &>/dev/null; then
    echo "VLAN interface ${VLAN_IF} does not exist."
    exit 0
fi

# Bring down the interface first
echo "Bringing down VLAN interface ${VLAN_IF}..."
ip link set ${VLAN_IF} down 2>/dev/null || true

# Remove the VLAN interface
echo "Removing VLAN interface ${VLAN_IF}..."
ip link delete ${VLAN_IF}
if [ $? -ne 0 ]; then
    echo "Failed to remove VLAN interface ${VLAN_IF}"
    exit 1
fi

echo "VLAN interface ${VLAN_IF} removed successfully!"

