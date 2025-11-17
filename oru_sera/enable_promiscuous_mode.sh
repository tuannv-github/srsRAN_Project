#!/bin/bash

# Script to enable promiscuous mode for network interface

IF_NAME="ens12f0"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (with sudo)."
    exit 1
fi

# Check if interface exists
if ! ip link show ${IF_NAME} &>/dev/null; then
    echo "Error: Interface ${IF_NAME} does not exist."
    exit 1
fi

echo "Enabling promiscuous mode for interface ${IF_NAME}..."

# Enable promiscuous mode
ip link set ${IF_NAME} promisc on
if [ $? -ne 0 ]; then
    echo "Failed to enable promiscuous mode for ${IF_NAME}"
    exit 1
fi

# Verify promiscuous mode is enabled
if ip link show ${IF_NAME} | grep -q "PROMISC"; then
    echo "Promiscuous mode enabled successfully for ${IF_NAME}"
    echo "Current interface status:"
    ip link show ${IF_NAME} | grep -E "(state|PROMISC)"
else
    echo "Warning: Promiscuous mode may not be enabled. Check interface status:"
    ip link show ${IF_NAME}
fi

