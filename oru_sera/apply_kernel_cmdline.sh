#!/bin/bash

# Script to apply kernel command line parameters from cmdline file to GRUB

CMDLINE_FILE="/home/fcp/srsRAN_Project/oru_sera/cmdline"
GRUB_FILE="/etc/default/grub"
BACKUP_FILE="/etc/default/grub.backup.$(date +%Y%m%d_%H%M%S)"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (with sudo)."
    exit 1
fi

# Check if cmdline file exists
if [ ! -f "$CMDLINE_FILE" ]; then
    echo "Error: $CMDLINE_FILE not found"
    exit 1
fi

# Extract the GRUB_CMDLINE_LINUX_DEFAULT value
NEW_CMDLINE=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$CMDLINE_FILE" | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/')

if [ -z "$NEW_CMDLINE" ]; then
    echo "Error: Could not extract GRUB_CMDLINE_LINUX_DEFAULT from $CMDLINE_FILE"
    exit 1
fi

echo "=== Applying Kernel Command Line Parameters ==="
echo ""

# Backup existing GRUB file
if [ -f "$GRUB_FILE" ]; then
    echo "1. Backing up existing GRUB configuration..."
    cp "$GRUB_FILE" "$BACKUP_FILE"
    echo "   Backup saved to: $BACKUP_FILE"
else
    echo "1. Creating new GRUB configuration file..."
fi
echo ""

# Update or add GRUB_CMDLINE_LINUX_DEFAULT
echo "2. Updating GRUB_CMDLINE_LINUX_DEFAULT..."
if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" "$GRUB_FILE" 2>/dev/null; then
    # Replace existing line
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW_CMDLINE\"|" "$GRUB_FILE"
    echo "   Updated existing GRUB_CMDLINE_LINUX_DEFAULT"
else
    # Add new line
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW_CMDLINE\"" >> "$GRUB_FILE"
    echo "   Added GRUB_CMDLINE_LINUX_DEFAULT"
fi
echo ""

# Show the updated line
echo "3. Updated GRUB_CMDLINE_LINUX_DEFAULT:"
grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$GRUB_FILE"
echo ""

# Update GRUB
echo "4. Updating GRUB configuration..."
if command -v update-grub &> /dev/null; then
    update-grub
elif command -v grub2-mkconfig &> /dev/null; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
else
    echo "   Warning: Could not find update-grub or grub2-mkconfig"
    echo "   Please manually run: update-grub (or grub2-mkconfig -o /boot/grub2/grub.cfg)"
fi
echo ""

echo "=== Configuration Applied ==="
echo ""
echo "IMPORTANT: Reboot the system for changes to take effect:"
echo "  sudo reboot"
echo ""
echo "After reboot, verify with:"
echo "  cat /proc/cmdline | grep isolcpus"


