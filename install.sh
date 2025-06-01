#!/bin/bash

# Welcome message
echo "Welcome to the NAS Backup and MergerFS setup script."
echo "This script will automate some installation steps and guide you through manual configurations."
echo "You will be prompted to press Enter to continue at various stages."
read -p "Press Enter to continue..."

# Update and upgrade the system
echo "INFO: Updating and upgrading the system..."
sudo apt update && sudo apt upgrade -y
echo "INFO: System update and upgrade complete."
read -p "Press Enter to continue..."

# Install necessary packages
echo "INFO: Installing necessary packages..."
sudo apt install -y rsync cifs-utils samba-client util-linux zfsutils-linux smartmontools jq curl mergerfs
echo "INFO: Necessary packages installed."
read -p "Press Enter to continue..."

# Instructions for manual sudoers configuration
echo "MANUAL STEP: Configure sudoers for ZFS commands without password."
echo "1. Run 'sudo visudo'."
echo "2. Add the following line to the end of the file (replace 'your_username' with your actual username):"
echo "   your_username ALL=(ALL) NOPASSWD: /usr/sbin/zfs, /usr/sbin/zpool"
echo "3. Save and exit the editor."
read -p "Press Enter after completing the sudoers configuration..."

# Instructions for manual ZFS pool setup
echo "MANUAL STEP: Setup ZFS pools for each of your data disks."
echo "1. Identify your disk devices (e.g., /dev/sdb, /dev/sdc). You can use 'lsblk' or 'fdisk -l'."
echo "   WARNING: Ensure you select the correct disks. Data on these disks might be affected."
echo "2. For each disk, create a ZFS pool. Replace 'pool_name' with a unique name for the pool (e.g., data_disk1) and '/dev/sdx' with the disk identifier."
echo "   Example: sudo zpool create -o ashift=12 -O compression=lz4 -O xattr=sa -O acltype=posixacl -O relatime=on pool_name /dev/sdx"
echo "   It is recommended to use GPT partitions (e.g. /dev/sdx1) instead of full device paths."
echo "3. Verify the pools are created: sudo zpool status"
read -p "Press Enter after completing the ZFS pool setup..."

# Create mergerfs mount point
echo "INFO: Creating MergerFS mount point at /mnt/merged_pool..."
sudo mkdir -p /mnt/merged_pool
echo "INFO: MergerFS mount point created."
read -p "Press Enter to continue..."

# Instructions for manual /etc/fstab configuration for mergerfs
echo "MANUAL STEP: Configure /etc/fstab for MergerFS."
echo "1. Open /etc/fstab for editing: sudo nano /etc/fstab"
echo "2. Add a line similar to the following, replacing '/mnt/zfs_pool1:/mnt/zfs_pool2' with the actual mount points of your ZFS pools:"
echo "   /mnt/zfs_pool*:/mnt/another_pool* /mnt/merged_pool fuse.mergerfs defaults,allow_other,use_ino,cache.files=auto-full,dropcacheonclose=true,category.create=mfs,minfreespace=10G,fsname=mergerfsPool 0 0"
echo "   Refer to the MergerFS documentation for optimal options for your use case."
echo "3. Save and exit the editor."
echo "4. Mount all filesystems: sudo mount -a"
echo "5. Verify the merged pool is mounted: df -h"
read -p "Press Enter after completing the /etc/fstab configuration..."

# Copy mount_up.sh and backup.sh to /usr/local/bin/
echo "INFO: Checking for mount_up.sh and backup.sh in the current directory..."
if [[ -f "./mount_up.sh" && -f "./backup.sh" ]]; then
    echo "INFO: Found mount_up.sh and backup.sh."
    sudo cp ./mount_up.sh /usr/local/bin/mount_up.sh
    sudo cp ./backup.sh /usr/local/bin/backup.sh
    sudo chmod +x /usr/local/bin/mount_up.sh
    sudo chmod +x /usr/local/bin/backup.sh
    echo "INFO: Copied mount_up.sh and backup.sh to /usr/local/bin/ and made them executable."
else
    echo "ERROR: mount_up.sh or backup.sh not found in the current directory. Please place them here before running this part of the script."
    echo "Skipping copying of mount_up.sh and backup.sh."
fi
read -p "Press Enter to continue..."

# Instructions for creating the .env file
echo "MANUAL STEP: Create and configure the .env file for backup.sh."
echo "1. Create the file: sudo nano /usr/local/bin/.env"
echo "2. Add the necessary environment variables. For example:"
echo "   PUSHOVER_USER_KEY=\"your_pushover_user_key\""
echo "   PUSHOVER_APP_TOKEN=\"your_pushover_app_token\""
echo "   ZFS_POOLS_TO_MONITOR=(\"pool_name1\" \"pool_name2\")"
echo "   REMOTE_USER=\"your_remote_smb_user\""
echo "   REMOTE_HOST=\"remote_smb_server_ip_or_hostname\""
echo "   REMOTE_SHARE=\"RemoteSMBNASShareName\""
echo "   LOCAL_MOUNT_POINT=\"/mnt/remote_backup_share\""
echo "   SMB_CREDENTIALS_FILE=\"/root/.smb_credentials_backup\""
echo "   LOG_FILE=\"/var/log/backup.log\""
echo "   PATH_TO_MOUNT_UP_SCRIPT=\"/usr/local/bin/mount_up.sh\""
echo "   # Add any other variables your backup.sh script might need"
echo "3. Save and exit the editor."
echo "4. Set appropriate permissions: sudo chmod 600 /usr/local/bin/.env"
read -p "Press Enter after creating and configuring the .env file..."

# Instructions for creating the SMB credentials file
echo "MANUAL STEP: Create the SMB credentials file."
echo "1. Create the file (e.g., /root/.smb_credentials_backup). The path should match SMB_CREDENTIALS_FILE in your .env"
echo "   Example: sudo nano /root/.smb_credentials_backup"
echo "2. Add the following content, replacing with your actual credentials:"
echo "   username=your_smb_username"
echo "   password=your_smb_password"
echo "   domain=your_smb_domain_or_workgroup (if applicable, otherwise remove this line)"
echo "3. Save and exit the editor."
echo "4. Set appropriate permissions: sudo chmod 600 /root/.smb_credentials_backup"
read -p "Press Enter after creating the SMB credentials file..."

# Instructions for configuring backup.sh variables
echo "INFO: Reminder to configure variables."
echo "If you haven't already, ensure all necessary variables are correctly set either in /usr/local/bin/.env or directly within /usr/local/bin/backup.sh."
echo "This includes Pushover tokens, ZFS pool names, remote share details, etc."
read -p "Press Enter to continue..."

# Instructions for setting up the cron job
echo "MANUAL STEP: Set up the cron job for backup.sh."
echo "1. Open the cron table for the root user: sudo crontab -e"
echo "2. Add a line to schedule the backup script. For example, to run daily at 2 AM:"
echo "   0 2 * * * /usr/local/bin/backup.sh"
echo "3. Save and exit the editor."
echo "INFO: The cron job will ensure your backup script runs automatically."
read -p "Press Enter after setting up the cron job..."

# Completion message
echo "INFO: Installation and setup script complete!"
echo "Please ensure you have completed all manual steps correctly."
echo "You may need to reboot for all changes to take effect properly."

exit 0
