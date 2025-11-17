#!/bin/bash

IF_NAME="ens12f0"
MAC_ADDRESS="7a:a1:ab:00:f3:10"
VLAN_ID=564

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (with sudo)."
    exit 1
fi


# Remove old VFs
echo "Removing old VFs"
sudo echo 0 > /sys/class/net/$IF_NAME/device/sriov_numvfs
if [ $? -ne 0 ]; then
    echo "Failed to remove old VFs"
    exit 1
fi

# Create new VF
echo "Creating new VF"
sudo echo 1 > /sys/class/net/$IF_NAME/device/sriov_numvfs
if [ $? -ne 0 ]; then
    echo "Failed to create new VF"
    exit 1
fi

# Wait for VF to be ready (VF initialization can take a moment)
echo "Waiting for VF to be ready..."
sleep 2

# Retry setting MAC address with a few attempts
echo "Setting the MAC address for the VF"
sudo ip link set $IF_NAME vf 0 mac $MAC_ADDRESS 2>/dev/null
if [ $? -ne 0 ]; then
    echo "Failed to set the MAC address for the VF"
    exit 1
fi

echo "Disabling spoof checking"
sudo ip link set $IF_NAME vf 0 spoofchk off
if [ $? -ne 0 ]; then
    echo "Failed to disable spoof checking"
    exit 1
fi

# # Configure VLAN 564 on VF
# echo "Configuring VLAN $VLAN_ID on VF"
# sudo ip link set $IF_NAME vf 0 vlan $VLAN_ID
# if [ $? -ne 0 ]; then
#     echo "Failed to configure VLAN $VLAN_ID on VF"
#     exit 1
# fi

echo "VLAN $VLAN_ID configured successfully on VF"

PCI_ADDRESS=""
# Get PCI address of Intel Ethernet Virtual Function 700 Series (rev 02)
PCI_ADDRESS=$(lspci -D | grep 'Ethernet Virtual Function 700 Series (rev 02)' | awk '{print $1}' | head -n1)
if [ -z "$PCI_ADDRESS" ]; then
    echo "Failed to find PCI address for Intel Ethernet Virtual Function 700 Series (rev 02)"
    exit 1
fi
echo "Found PCI address for VF: $PCI_ADDRESS"

sudo dpdk-devbind.py --bind=vfio-pci $PCI_ADDRESS
if [ $? -ne 0 ]; then
    echo "Failed to bind VF to DPDK driver vfio-pci"
    exit 1
fi

echo "Interface setup completed successfully"