#!/bin/bash

# Script to diagnose VFIO binding issues

PCI_ADDR="0000:bd:02.0"
SHORT_PCI="bd:02.0"

echo "=== VFIO Binding Diagnostic ==="
echo ""

echo "1. Checking PCI device information:"
lspci -nn -s ${SHORT_PCI}
echo ""

echo "2. Checking current driver binding:"
lspci -k -s ${SHORT_PCI} 2>/dev/null || echo "Need root privileges to check driver"
echo ""

echo "3. Checking if VFIO modules are loaded:"
if lsmod | grep -q "^vfio_pci"; then
    echo "  ✓ vfio_pci module is loaded"
    lsmod | grep vfio
else
    echo "  ✗ vfio_pci module is NOT loaded"
fi
echo ""

echo "4. Checking if VFIO modules exist:"
if modinfo vfio-pci &>/dev/null; then
    echo "  ✓ vfio-pci module is available"
else
    echo "  ✗ vfio-pci module is NOT available"
fi
echo ""

echo "5. Checking IOMMU status in kernel command line:"
if grep -q "iommu=" /proc/cmdline; then
    echo "  ✓ IOMMU parameters found in kernel command line:"
    grep -o "iommu=[^ ]*" /proc/cmdline
else
    echo "  ✗ No IOMMU parameters in kernel command line"
    echo "    IOMMU may not be enabled. Check BIOS/UEFI settings."
fi
echo ""

echo "6. Checking IOMMU groups (requires root):"
if [ "$EUID" -eq 0 ]; then
    if [ -d /sys/kernel/iommu_groups ]; then
        echo "  IOMMU groups directory exists"
        find /sys/kernel/iommu_groups -name "${PCI_ADDR}" 2>/dev/null | head -1
        if [ $? -eq 0 ]; then
            echo "  ✓ Device is in an IOMMU group"
        else
            echo "  ✗ Device is NOT in an IOMMU group"
        fi
    else
        echo "  ✗ IOMMU groups directory does not exist"
    fi
else
    echo "  (Need root to check IOMMU groups)"
fi
echo ""

echo "7. Checking if device is currently bound to a driver:"
if [ -L /sys/bus/pci/devices/${PCI_ADDR}/driver ]; then
    CURRENT_DRIVER=$(readlink /sys/bus/pci/devices/${PCI_ADDR}/driver | sed 's|.*/||')
    echo "  Current driver: ${CURRENT_DRIVER}"
    if [ "${CURRENT_DRIVER}" = "vfio-pci" ]; then
        echo "  ✓ Already bound to vfio-pci"
    else
        echo "  ⚠ Device needs to be unbound from ${CURRENT_DRIVER} first"
    fi
else
    echo "  Device is not bound to any driver"
fi
echo ""

echo "8. Checking VFIO device status:"
if [ -d /sys/bus/pci/drivers/vfio-pci ]; then
    echo "  ✓ vfio-pci driver directory exists"
    if [ -L /sys/bus/pci/devices/${PCI_ADDR}/driver ]; then
        if readlink /sys/bus/pci/devices/${PCI_ADDR}/driver | grep -q vfio-pci; then
            echo "  ✓ Device is bound to vfio-pci"
        fi
    fi
else
    echo "  ✗ vfio-pci driver directory does not exist (module not loaded)"
fi
echo ""

echo "=== Diagnostic Complete ==="


