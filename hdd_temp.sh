#!/bin/bash

echo "--- Hard Drive Temperatures ---"
# Get a list of potential hard drive devices
# This is a common pattern, but you might need to adjust for specific setups
DRIVES=$(ls -1 /dev/sd[a-z])

if [ -z "$DRIVES" ]; then
    echo "No standard hard drives (sdX or hdX) found."
    echo "You might need to manually specify your drive paths (e.g., /dev/nvme0n1)."
    exit 0
fi


echo
date
for DRIVE in $DRIVES
do
    sudo hddtemp -uf "$DRIVE"    
done

echo "--------------------------------------------------------------------"