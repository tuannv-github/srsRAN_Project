#!/bin/bash

# Script to disable promiscuous mode for network interface

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

echo "Disabling promiscuous mode for interface ${IF_NAME}..."

# Disable promiscuous mode
ip link set ${IF_NAME} promisc off
if [ $? -ne 0 ]; then
    echo "Failed to disable promiscuous mode for ${IF_NAME}"
    exit 1
fi

# Verify promiscuous mode is disabled
if ! ip link show ${IF_NAME} | grep -q "PROMISC"; then
    echo "Promiscuous mode disabled successfully for ${IF_NAME}"
    echo "Current interface status:"
    ip link show ${IF_NAME} | grep -E "(state|PROMISC)"
else
    echo "Warning: Promiscuous mode may still be enabled. Check interface status:"
    ip link show ${IF_NAME}
fi

