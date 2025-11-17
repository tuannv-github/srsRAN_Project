#!/bin/bash

# Script to fix VFIO binding issues

PCI_ADDR="0000:bd:02.0"
SHORT_PCI="bd:02.0"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (with sudo)."
    exit 1
fi

echo "=== Fixing VFIO Binding for ${PCI_ADDR} ==="
echo ""

# Step 1: Check if IOMMU is enabled
echo "1. Checking IOMMU status..."
if ! grep -q "iommu=" /proc/cmdline; then
    echo "  ⚠ WARNING: No IOMMU parameters found in kernel command line"
    echo "  IOMMU may not be enabled. You may need to:"
    echo "    - Enable IOMMU/VT-d in BIOS/UEFI"
    echo "    - Add 'intel_iommu=on' or 'iommu=pt' to kernel boot parameters"
    echo "    - Reboot the system"
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Step 2: Load VFIO modules
echo "2. Loading VFIO modules..."
if ! lsmod | grep -q "^vfio_pci"; then
    echo "  Loading vfio-pci module..."
    modprobe vfio-pci
    if [ $? -ne 0 ]; then
        echo "  ✗ Failed to load vfio-pci module"
        exit 1
    fi
    echo "  ✓ vfio-pci module loaded"
else
    echo "  ✓ vfio-pci module already loaded"
fi

# Also ensure vfio and vfio_iommu_type1 are loaded
modprobe vfio
modprobe vfio_iommu_type1
echo ""

# Step 3: Unbind from current driver if needed
echo "3. Checking current driver binding..."
if [ -L /sys/bus/pci/devices/${PCI_ADDR}/driver ]; then
    CURRENT_DRIVER=$(readlink /sys/bus/pci/devices/${PCI_ADDR}/driver | sed 's|.*/||')
    echo "  Current driver: ${CURRENT_DRIVER}"
    
    if [ "${CURRENT_DRIVER}" = "vfio-pci" ]; then
        echo "  ✓ Already bound to vfio-pci"
        exit 0
    fi
    
    echo "  Unbinding from ${CURRENT_DRIVER}..."
    echo ${PCI_ADDR} > /sys/bus/pci/devices/${PCI_ADDR}/driver/unbind
    if [ $? -ne 0 ]; then
        echo "  ✗ Failed to unbind from ${CURRENT_DRIVER}"
        echo "  Try manually: echo ${PCI_ADDR} > /sys/bus/pci/devices/${PCI_ADDR}/driver/unbind"
        exit 1
    fi
    echo "  ✓ Unbound from ${CURRENT_DRIVER}"
    sleep 1
else
    echo "  Device is not bound to any driver"
fi
echo ""

# Step 4: Bind to vfio-pci
echo "4. Binding to vfio-pci..."
echo ${PCI_ADDR} > /sys/bus/pci/drivers/vfio-pci/bind
if [ $? -ne 0 ]; then
    echo "  ✗ Failed to bind to vfio-pci"
    echo ""
    echo "  Common causes:"
    echo "    - IOMMU not enabled (check BIOS and kernel parameters)"
    echo "    - Device not in an IOMMU group"
    echo "    - VFIO modules not properly loaded"
    echo ""
    echo "  Try using dpdk-devbind.py:"
    echo "    ./dpdk-devbind.py --bind vfio-pci ${SHORT_PCI}"
    exit 1
fi

# Verify binding
sleep 1
if [ -L /sys/bus/pci/devices/${PCI_ADDR}/driver ]; then
    BOUND_DRIVER=$(readlink /sys/bus/pci/devices/${PCI_ADDR}/driver | sed 's|.*/||')
    if [ "${BOUND_DRIVER}" = "vfio-pci" ]; then
        echo "  ✓ Successfully bound to vfio-pci"
    else
        echo "  ⚠ Bound to unexpected driver: ${BOUND_DRIVER}"
    fi
else
    echo "  ⚠ Warning: Driver binding verification failed"
fi
echo ""

# Step 5: Verify with lspci
echo "5. Verifying with lspci:"
lspci -k -s ${SHORT_PCI}
echo ""

echo "=== VFIO Binding Complete ==="

