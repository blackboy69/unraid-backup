#!/bin/bash

echo "--- Hard Drive Temperatures ---"

# Get a list of potential hard drive devices
# This is a common pattern, but you might need to adjust for specific setups
DRIVES=$(ls -1 /dev/sd[a-z] /dev/hd[a-z] 2>/dev/null)

if [ -z "$DRIVES" ]; then
    echo "No standard hard drives (sdX or hdX) found."
    echo "You might need to manually specify your drive paths (e.g., /dev/nvme0n1)."
    exit 0
fi

for DRIVE in $DRIVES
do
    # Check if the drive is actually a block device and exists
    if [ -b "$DRIVE" ]; then
        sudo hddtemp -uf "$DRIVE"
    fi
done

echo "-----------------------------"
