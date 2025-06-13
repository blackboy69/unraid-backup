#!/bin/bash
# This script mounts all shares from a NAS using smbclient and mounts them to /mnt/NAS/<share_name>
# don't use this. rclone handles this better.
pushd .
cd "${0%/*}"
source .env

# grab the shares from the NAS
SHARES=$(smbclient -L nas -N  --user=$SMB_USERNAME --password=$SMB_PASSWORD -g | grep Disk | cut -f 2 -d '|')
FAIL=0
# loop through each share and mount it
for SHARE in $SHARES; do
    MOUNT_POINT="/mnt/NAS/$SHARE"
    
    # Create the mount point if it doesn't exist
    sudo mkdir -p "$MOUNT_POINT"
    
    # Mount the share
    #sudo umount "$MOUNT_POINT" # Unmount if already mounted
    status=$(ls $MOUNT_POINT 2>&1)

    if [[ $status =~ .*Stale.* ]] then
            sudo umount "$MOUNT_POINT" # Unmount if already mounted            
            echo "UN-Mounted $SHARE at $MOUNT_POINT successfully."
            #sudo mount --verbose -t cifs -o rw,vers=3.11,noserverino,username=$SMB_USERNAME,password=$SMB_PASSWORD "//$SERVER/$SHARE" "$MOUNT_POINT"
    fi
    if [[ -z $(ls $MOUNT_POINT) ]]; then
        sudo mount --verbose -t cifs -o rw,vers=3.11,noserverino,username=$SMB_USERNAME,password=$SMB_PASSWORD "//$SERVER/$SHARE" "$MOUNT_POINT"
    
        if [ $? -eq 0 ]; then
            echo "Mounted $SHARE at $MOUNT_POINT successfully."
        else
            echo "Failed to mount $SHARE at $MOUNT_POINT."
            FAIL=1
        fi
    else
        echo "Mount point $MOUNT_POINT already exists, skipping mount for $SHARE."
    fi
done

popd 
# Exit with the failure status if any mount failed
exit $FAIL

