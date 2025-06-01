#!/bin/bash

# --- INSTALLATION INSTRUCTIONS FOR (Debian VM) ---
# This script runs on your Debian VM.
#
# 1. Update your system:
#    sudo apt update
#    sudo apt upgrade -y
#
# 2. Install necessary packages:
#    sudo apt install -y rsync cifs-utils zfsutils-linux smartmontools jq curl
#    (cifs-utils is needed for fstab SMB mounts)
#
# 3. Configure Secure SMB Credentials File for fstab:
#    a. Create a file for SMB credentials (e.g., for root user):
#       sudo nano /root/.smbcredentials
#    b. Add the following two lines (replace with your NAS SMB username and password):
#       username=smb_backup_user
#       password=YOUR_SMB_PASSWORD
#    c. Set strict permissions (CRITICAL FOR SECURITY!):
#       sudo chmod 600 /root/.smbcredentials
#       (If running as a non-root user, adjust path to ~/.smbcredentials and permissions accordingly)
#
# 4. Configure Sudoers for ZFS and SMART commands (if running script as non-root):
#    a. Edit the sudoers file:
#       sudo visudo
#    b. Add the following line, replacing 'your_username' with the actual username running the script:
#       your_username ALL=(ALL) NOPASSWD: /usr/sbin/zpool, /usr/sbin/zfs, /usr/sbin/smartctl, /usr/bin/journalctl
#       (Note: mount/umount commands are not needed in sudoers here as fstab handles them)
#
# 5. Set up individual ZFS Pools on your passed-through disks:
#    (Example for /dev/sdb)
#    sudo zpool create -f YOUR_POOL_NAME /dev/sdb
#    (e.g., sudo zpool create -f pool_disk1 /dev/sdb)
#    (Repeat for pool_disk2, pool_disk3, etc., replacing /dev/sdX with the correct device ID)
#    (ZFS pools will typically auto-mount under /YOUR_POOL_NAME, e.g., /pool_disk1)
#
# 6. Install and configure mergerfs:
#    sudo apt install -y mergerfs
#    Create a mount point for your merged pool:
#    sudo mkdir /mnt/merged_pool
#    Edit /etc/fstab to configure mergerfs to mount at boot:
#    sudo nano /etc/fstab
#    Add a line like this (adjusting your ZFS pool mount points and your mergerfs options):
#    /pool_disk1:/pool_disk2:/pool_disk3:/pool_disk4:/pool_disk5 /mnt/merged_pool fuse.mergerfs defaults,allow_other,use_mfs,minfreespace=10G,fsname=mergerfs_pool 0 0
#    (Save and exit nano. Then mount it: sudo mount -a)
#
# 7. Configure SMB Shares to Mount Automatically via fstab:
#    a. Create base directory for NAS mounts:
#       sudo mkdir /mnt/nas_smb_mounts
#    b. Create subdirectories for each specific share you want to mount:
#       sudo mkdir /mnt/nas_smb_mounts/media_movies
#       sudo mkdir /mnt/nas_smb_mounts/media_tvshows
#       sudo mkdir /mnt/nas_smb_mounts/proxmox_vzdumps
#    c. Edit /etc/fstab:
#       sudo nano /etc/fstab
#    d. Add lines for each SMB share, using your NAS IP, share name, local mount point, and credentials file:
#       //YOUR_NAS_IP/media_movies /mnt/nas_smb_mounts/media_movies cifs credentials=/root/.smbcredentials,ro,iocharset=utf8,vers=3.0,uid=0,gid=0,forceuid,forcegid,file_mode=0644,dir_mode=0755 0 0
#       //YOUR_NAS_IP/media_tvshows /mnt/nas_smb_mounts/media_tvshows cifs credentials=/root/.smbcredentials,ro,iocharset=utf8,vers=3.0,uid=0,gid=0,forceuid,forcegid,file_mode=0644,dir_mode=0755 0 0
#       //YOUR_NAS_IP/proxmox_vzdumps /mnt/nas_smb_mounts/proxmox_vzdumps cifs credentials=/root/.smbcredentials,ro,iocharset=utf8,vers=3.0,uid=0,gid=0,forceuid,forcegid,file_mode=0644,dir_mode=0755 0 0
#       (Adjust mount options as needed. 'uid=0,gid=0' means root ownership on mount. 'file_mode=0644,dir_mode=0755' set permissions. 'ro' for read-only. 'vers=3.0' for SMB3.)
#    e. Save and exit nano.
#    f. Test mounting: sudo mount -a (Check for errors, then verify with 'mount -l | grep cifs')
#
# 8. Place this script on Debian VM:
#    sudo nano /usr/local/bin/backup_pull.sh
#    (Paste the script content below)
#
# 9. Make the script executable:
#    sudo chmod +x /usr/local/bin/backup_pull.sh
#
# 10. Configure your Pushover API tokens and other variables in the CONFIGURATION section below.
#
# 11. Schedule the script with cron (recommended to run as root or a user with sudo privileges):
#     sudo crontab -e
#     Add a line (e.g., daily at 2 AM):
#     0 2 * * * /usr/local/bin/backup_pull.sh >> /var/log/backup_pull_cron.log 2>&1
#
# --- END INSTALLATION INSTRUCTIONS ---


# --- START CONFIGURATION ---

# Pushover API Details (GET THESE FROM YOUR PUSHOVER APP)
# IMPORTANT: Store these securely. If running via cron, consider adding them to
# /etc/environment or your user's .profile/.bashrc, or source a separate config file.
PUSHOVER_APP_TOKEN="YOUR_PUSHOVER_APP_TOKEN" # Replace with your Pushover application token
PUSHOVER_USER_KEY="YOUR_PUSHOVER_USER_KEY"   # Replace with your Pushover user key

# Source (NAS) Mounted Shares Details
# IMPORTANT: These paths MUST exactly match the local mount points configured in /etc/fstab.
# Ensure they end with a trailing slash (e.g., "/mnt/nas_smb_mounts/media_movies/" )
SOURCE_FOLDERS="
/mnt/nas_smb_mounts/media_movies/
/mnt/nas_smb_mounts/media_tvshows/
/mnt/nas_smb_mounts/proxmox_vzdumps/
"

# Rsync Exclusion Filters (space-separated list of patterns to exclude within shares)
# Rsync will ignore these files/folders globally within any synced share.
RSYNC_EXCLUDES=(
    "*.tmp"
    "*.bak"
    "@eaDir"        # Synology Thumbnail directory (common on NAS)
    "#recycle"      # QNAP/Synology Recycle Bin (common on NAS)
    ".Trash-*"      # Linux/macOS Trash folders
    ".DS_Store"     # macOS desktop service store
    "Thumbs.db"     # Windows thumbnail cache
    "*.part"        # Partial download files
    ".syncignore"   # SyncThing ignore files
)

# Destination (Debian VM) Details
# This is the mount point of your mergerfs pool on destiation.
DEST_ROOT="/mnt/merged_pool"
# Optional: Subdirectory within DEST_ROOT where NAS backups will land.
# This helps organize data on your destiation vm. E.g., /mnt/merged_pool/nas_backups/
DEST_SUBDIR="nas_backups"
FINAL_DEST="${DEST_ROOT}/${DEST_SUBDIR}"

# ZFS Pool Names on destiation (space-separated list of your individual ZFS pool names)
# IMPORTANT: These are the exact names you used with 'zpool create'.
# Example: "pool_disk1 pool_disk2 pool_disk3 pool_disk4 pool_disk5"
ZFS_POOLS="pool_disk1 pool_disk2 pool_disk3 pool_disk4 pool_disk5"

# Snapshot Rotation Policy
# Snapshots will be named like "backup@YYYY-MM-DD_HHMM"
SNAPSHOT_PREFIX="backup" 
# Retention policy for snapshots per pool:
# e.g., KEEP_DAILY=7 means keep the last 7 daily snapshots
# Set to 0 to disable keeping that tier of snapshots.
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=12
KEEP_YEARLY=0

# Script Logging
LOG_FILE="/var/log/backup_pull.log" # Log file for this script's output

# --- END CONFIGURATION ---


# --- Helper Functions ---

# Function to send Pushover notification
pushover_notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-0}" # Default priority 0 (normal)
    local url="https://api.pushover.net/1/messages.json"

    if [[ -z "$PUSHOVER_APP_TOKEN" || -z "$PUSHOVER_USER_KEY" ]]; then
        echo "$(date) ERROR: Pushover API tokens not set. Cannot send notification." | tee -a "$LOG_FILE"
        return 1
    fi

    curl -s \
        -F "token=$PUSHOVER_APP_TOKEN" \
        -F "user=$PUSHOVER_USER_KEY" \
        -F "title=$title" \
        -F "message=$message" \
        -F "priority=$priority" \
        "$url" > /dev/null

    if [[ $? -ne 0 ]]; then
        echo "$(date) ERROR: Failed to send Pushover notification." | tee -a "$LOG_FILE"
        return 1
    fi
}

# Function to check system and ZFS logs for errors
check_logs() {
    echo "$(date) INFO: Checking system and ZFS logs for errors..." | tee -a "$LOG_FILE"
    local error_found=0
    local message="" # Start message empty
    local hostname_cmd=$(hostname) # Capture hostname once

    local check_period="24 hours ago" # How far back to check logs

    # Check dmesg for recent critical errors
    local dmesg_errors=$(journalctl -k --since "$check_period" | grep -E "error|fail|critical" | grep -Ev "error_report|failed to stat" | head -n 5)
    if [[ -n "$dmesg_errors" ]]; then
        message+="Critical kernel errors found in dmesg. "
        error_found=1
    fi

    # Check ZFS pool status for errors
    local zfs_status_output=$(sudo zpool status -x)
    if [[ -n "$zfs_status_output" ]]; then
        if echo "$zfs_status_output" | grep -Eq "DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED|corrupt|checksum"; then
            message+="ZFS pool errors found! Status: $(zpool status -x | head -n 3). "
            error_found=1
        fi
    fi

    # Check SMART status of all disks
    local smart_errors_detected=0
    for pool in $ZFS_POOLS; do
        # Get list of underlying devices for the ZFS pool
        local pool_devices=$(sudo zpool status "$pool" | grep -E "sd[a-z]|nvme[0-9]" | awk '{print $1}') 
        for device in $pool_devices; do
            local disk_path="/dev/$device"
            if [[ ! -e "$disk_path" ]]; then
                echo "$(date) WARNING: Disk path $disk_path not found for SMART check. Skipping." | tee -a "$LOG_FILE"
                continue
            fi
            
            local smart_health=$(sudo smartctl -H "$disk_path" | grep "SMART overall-health self-assessment test result:")
            if [[ "$smart_health" == *"FAILED"* ]]; then
                message+="SMART error on $disk_path ($pool)! "
                smart_errors_detected=1
            fi
        done
    done
    if [[ $smart_errors_detected -eq 1 ]]; then
        error_found=1
    fi

    if [[ $error_found -eq 1 ]]; then
        echo "$(date) ERROR: Log check found issues. Notifying Pushover." | tee -a "$LOG_FILE"
        pushover_notify "$hostname_cmd Backup Status: ALERT!" "$message" 1 # High priority
        return 1 # Indicate error
    else
        echo "$(date) INFO: Log check completed. No critical errors found." | tee -a "$LOG_FILE"
        return 0 # Indicate success
    fi
}

# Function to perform rsync backup
perform_rsync() {
    echo "$(date) INFO: Starting rsync backup from NAS SMB shares..." | tee -a "$LOG_FILE"
    local rsync_failed=0

    # Ensure destination subdirectory exists
    mkdir -p "$FINAL_DEST"

    # Build rsync exclude arguments
    local rsync_exclude_args=""
    for exclude_pattern in "${RSYNC_EXCLUDES[@]}"; do
        rsync_exclude_args+="--exclude='${exclude_pattern}' "
    done

    # Iterate through each source folder (which are now mounted SMB shares)
    if [[ -z "$SOURCE_FOLDERS" ]]; then
        echo "$(date) ERROR: No source folders specified in configuration. Rsync skipped." | tee -a "$LOG_FILE"
        return 1
    fi

    for src_folder_path in $SOURCE_FOLDERS; do
        # Check if the fstab mounted share is actually mounted
        if ! mountpoint -q "$src_folder_path"; then
            echo "$(date) ERROR: Source '$src_folder_path' is not mounted. Skipping this source." | tee -a "$LOG_FILE"
            rsync_failed=1 # Mark as failed for this source
            continue # Go to next source folder
        fi

        local share_name=$(basename "${src_folder_path%/}") # Get share name, remove trailing slash first
        local dest_path="${FINAL_DEST}/${share_name}/" # Backup each share into its own subdirectory

        echo "$(date) INFO: Syncing '$share_name' from '$src_folder_path' to '$dest_path'" | tee -a "$LOG_FILE"
        mkdir -p "$dest_path" # Ensure destination for this specific share exists

        # rsync command for SMB mounted shares
        # -a: archive mode (preserves permissions, timestamps, owner, group, symlinks etc. -- as much as SMB allows)
        # -v: verbose
        # -h: human-readable numbers
        # --delete: deletes files on destination that no longer exist on source
        # --progress: show progress during transfer
        # --no-whole-file: (Crucial for delta transfers over network mounts) Forces rsync to use its delta algorithm.
        #                  Without this, it might download entire files if destination is on a local mount.
        rsync_command="rsync -avh --delete --progress --no-whole-file ${rsync_exclude_args} \"${src_folder_path}\" \"${dest_path}\""
        echo "$(date) DEBUG: Running command: $rsync_command" | tee -a "$LOG_FILE"

        eval "$rsync_command" 2>&1 | tee -a "$LOG_FILE" # Use eval for quotes in exclude args
        if [[ $? -ne 0 ]]; then
            echo "$(date) ERROR: Rsync failed for share '$share_name'. Check log for details." | tee -a "$LOG_FILE"
            rsync_failed=1 # Mark as failed for this share
            # Do NOT break here, try to backup other shares even if one fails
        fi
    done

    if [[ "$rsync_failed" -eq 0 ]]; then
        echo "$(date) INFO: Rsync backup completed successfully for all shares." | tee -a "$LOG_FILE"
        return 0
    else
        echo "$(date) ERROR: One or more Rsync backups failed for shares. Check log for details." | tee -a "$LOG_FILE"
        return 1
    fi
}

# Function to take snapshots of individual ZFS pools
take_snapshots() {
    echo "$(date) INFO: Starting ZFS snapshot process..." | tee -a "$LOG_FILE"
    local snapshot_timestamp=$(date +%Y-%m-%d_%H%M)
    local snapshot_name="${SNAPSHOT_PREFIX}@${snapshot_timestamp}"
    local snapshot_failed=0

    for pool in $ZFS_POOLS; do
        echo "$(date) INFO: Taking snapshot of ZFS pool '$pool'..." | tee -a "$LOG_FILE"
        # We snapshot the root dataset of each ZFS pool, as mergerfs distributes files across them.
        sudo zfs snapshot "${pool}@${snapshot_name}" 2>&1 | tee -a "$LOG_FILE"
        if [[ $? -ne 0 ]]; then
            echo "$(date) ERROR: Failed to take snapshot for pool '$pool'. Check log for details." | tee -a "$LOG_FILE"
            snapshot_failed=1
        fi
    done

    if [[ $snapshot_failed -eq 0 ]]; then
        echo "$(date) INFO: ZFS snapshots completed successfully." | tee -a "$LOG_FILE"
        return 0
    else
        echo "$(date) ERROR: One or more ZFS snapshots failed. Check log for details." | tee -a "$LOG_FILE"
        return 1
    fi
}

# Function for ZFS snapshot rotation
rotate_snapshots() {
    echo "$(date) INFO: Starting ZFS snapshot rotation process..." | tee -a "$LOG_FILE"
    local rotation_failed=0

    for pool in $ZFS_POOLS; do
        echo "$(date) INFO: Rotating snapshots for ZFS pool '$pool' based on retention policy." | tee -a "$LOG_FILE"
        # Get list of snapshots for this pool with our prefix, sorted by creation date
        local snapshots_list=$(sudo zfs list -t snapshot -o name,creation -s creation -r "${pool}" | grep "${pool}@${SNAPSHOT_PREFIX}" | awk '{print $1}')

        local keep_daily_count=0
        local keep_weekly_count=0
        local keep_monthly_count=0
        local keep_yearly_count=0

        for snapshot in $snapshots_list; do
            local creation_epoch=$(sudo zfs get -Hp creation "$snapshot" | awk '{print $2}') # epoch time
            local current_epoch=$(date +%s)
            local age_seconds=$((current_epoch - creation_epoch))
            local age_days=$((age_seconds / (60*60*24)))

            local keep_this_snapshot=0

            # Keep daily snapshots (most recent)
            if [[ "$age_days" -lt 7 && "$keep_daily_count" -lt "$KEEP_DAILY" ]]; then
                keep_this_snapshot=1; keep_daily_count=$((keep_daily_count+1))
            fi

            # Keep weekly snapshots (1 per week, after daily limit)
            # This is a simplified approximation for "first of the week" (or "oldest in week")
            if [[ "$age_days" -ge 7 && "$keep_weekly_count" -lt "$KEEP_WEEKLY" ]]; then
                local week_num=$((age_days / 7))
                local found_later_in_week=0
                # Check if there's any snapshot created later in the same week that we're keeping
                for later_snapshot in $snapshots_list; do
                    if [[ "$later_snapshot" == "$snapshot" ]]; then continue; fi # Skip self
                    local later_creation_epoch=$(sudo zfs get -Hp creation "$later_snapshot" | awk '{print $2}')
                    local later_age_days=$(((current_epoch - later_creation_epoch) / (60*60*24)))
                    if [[ "$later_age_days" -lt "$age_days" && "$later_age_days" -ge $((age_days - 7)) ]]; then
                        found_later_in_week=1; break;
                    fi
                done
                if [[ "$found_later_in_week" -eq 0 ]]; then
                    keep_this_snapshot=1; keep_weekly_count=$((keep_weekly_count+1))
                fi
            fi

            # Keep monthly snapshots (1 per month, after weekly limit)
            # Find the oldest snapshot within each month range (roughly)
            if [[ "$age_days" -ge 30 && "$keep_monthly_count" -lt "$KEEP_MONTHLY" ]]; then
                local month_num=$((age_days / 30))
                local found_later_in_month=0
                for later_snapshot in $snapshots_list; do
                    if [[ "$later_snapshot" == "$snapshot" ]]; then continue; fi
                    local later_creation_epoch=$(sudo zfs get -Hp creation "$later_snapshot" | awk '{print $2}')
                    local later_age_days=$(((current_epoch - later_creation_epoch) / (60*60*24)))
                    if [[ "$later_age_days" -lt "$age_days" && "$later_age_days" -ge $((age_days - 30)) ]]; then
                        found_later_in_month=1; break;
                    fi
                done
                if [[ "$found_later_in_month" -eq 0 ]]; then
                    keep_this_snapshot=1; keep_monthly_count=$((keep_monthly_count+1))
                fi
            fi

            # Keep yearly snapshots
            if [[ "$age_days" -ge 365 && "$keep_yearly_count" -lt "$KEEP_YEARLY" ]]; then
                local year_num=$((age_days / 365))
                local found_later_in_year=0
                for later_snapshot in $snapshots_list; do
                    if [[ "$later_snapshot" == "$snapshot" ]]; then break; fi
                    local later_creation_epoch=$(sudo zfs get -Hp creation "$later_snapshot" | awk '{print $2}')
                    local later_age_days=$(((current_epoch - later_creation_epoch) / (60*60*24)))
                    if [[ "$later_age_days" -lt "$age_days" && "$later_age_days" -ge $((age_days - 365)) ]]; then
                        found_later_in_year=1; break;
                    fi
                done
                if [[ "$found_later_in_year" -eq 0 ]]; then
                    keep_this_snapshot=1; keep_yearly_count=$((keep_yearly_count+1))
                fi
            fi

            # If not explicitly marked to keep by any policy, delete it
            if [[ "$keep_this_snapshot" -eq 0 ]]; then
                echo "$(date) INFO: Deleting old snapshot: $snapshot (Age: ${age_days} days)" | tee -a "$LOG_FILE"
                sudo zfs destroy "$snapshot" 2>&1 | tee -a "$LOG_FILE"
                if [[ $? -ne 0 ]]; then
                    echo "$(date) ERROR: Failed to delete snapshot '$snapshot' for pool '$pool'. Check log." | tee -a "$LOG_FILE"
                    rotation_failed=1
                fi
            else
                echo "$(date) INFO: Keeping snapshot: $snapshot (Age: ${age_days} days)" | tee -a "$LOG_FILE"
            fi
        done
    done

    if [[ "$rotation_failed" -eq 0 ]]; then
        echo "$(date) INFO: Snapshot rotation completed successfully." | tee -a "$LOG_FILE"
        return 0
    else
        echo "$(date) ERROR: One or more snapshot rotations failed. Check log for details." | tee -a "$LOG_FILE"
        return 1
    fi
}


# --- Main Script Execution Logic ---

START_TIME=$(date +%s)
HOSTNAME_VAR=$(hostname) # Use a different variable name to avoid conflict with `hostname` command or function
SCRIPT_STATUS="SUCCESS"

echo "--- $(date) Starting Backup Job on $HOSTNAME_VAR ---" | tee -a "$LOG_FILE"

# Step 0: Check logs and notify (High priority if errors found)
if ! check_logs; then
    SCRIPT_STATUS="FAILURE"
    NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: ALERT!"
    NOTIFICATION_MESSAGE="Log check found errors before backup. Check logs on $HOSTNAME_VAR."
    NOTIFICATION_PRIORITY=1 # High priority
    pushover_notify "$NOTIFICATION_TITLE" "$NOTIFICATION_MESSAGE" "$NOTIFICATION_PRIORITY"
fi

# No need to mount/unmount shares dynamically, as they are managed by fstab.
# We assume they are mounted correctly. If not, rsync will fail.

# Step 1: Perform rsync backup
if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then
    if ! perform_rsync; then
        SCRIPT_STATUS="FAILURE"
        NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: FAILED!"
        NOTIFICATION_MESSAGE="Rsync failed. Check logs on $HOSTNAME_VAR."
        NOTIFICATION_PRIORITY=1 # High priority
        pushover_notify "$NOTIFICATION_TITLE" "$NOTIFICATION_MESSAGE" "$NOTIFICATION_PRIORITY"
    fi
fi

# Only proceed with snapshots if rsync was successful
if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then
    # Step 2: Take snapshots
    if ! take_snapshots; then
        SCRIPT_STATUS="FAILURE"
        NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: FAILED!"
        NOTIFICATION_MESSAGE="Snapshot creation failed. Check logs on $HOSTNAME_VAR."
        NOTIFICATION_PRIORITY=1 # High priority
        pushover_notify "$NOTIFICATION_TITLE" "$NOTIFICATION_MESSAGE" "$NOTIFICATION_PRIORITY"
    fi
fi

# Always attempt rotation if snapshots were attempted (even if creation failed)
# This prevents snapshots from piling up. Only if ZFS_POOLS is not empty.
if [[ -n "$ZFS_POOLS" ]]; then # Only try rotation if ZFS_POOLS variable is set
    # Step 3: Rotate snapshots
    if ! rotate_snapshots; then
        # Rotation failure doesn't mean overall backup failure, but it's an important alert
        if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then # If backup was successful but rotation failed
            SCRIPT_STATUS="WARNING"
            NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: WARNING!"
            NOTIFICATION_MESSAGE="Backup successful, but snapshot rotation failed. Check logs on $HOSTNAME_VAR."
            NOTIFICATION_PRIORITY=0 # Normal priority
            pushover_notify "$NOTIFICATION_TITLE" "$NOTIFICATION_MESSAGE" "$NOTIFICATION_PRIORITY"
        else # If backup already failed, add to existing error message
            NOTIFICATION_MESSAGE+=" Snapshot rotation also failed."
        fi
    fi
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Step 4: Notify final status via Pushover (only on failure/warning)
if [[ "$SCRIPT_STATUS" != "SUCCESS" ]]; then
    NOTIFICATION_MESSAGE+=" Total Duration: ${DURATION} seconds."
    echo "--- $(date) Backup Job Finished with status: $SCRIPT_STATUS ---" | tee -a "$LOG_FILE"
    pushover_notify "$NOTIFICATION_TITLE" "$NOTIFICATION_MESSAGE" "$NOTIFICATION_PRIORITY"
else
    # Quiet success notification
    NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: SUCCESS"
    NOTIFICATION_MESSAGE="Backup job on $HOSTNAME_VAR completed successfully. Total Duration: ${DURATION} seconds."
    NOTIFICATION_PRIORITY=-1 # Quiet priority (no sound)
    
    echo "--- $(date) Backup Job Finished successfully in ${DURATION} seconds ---" | tee -a "$LOG_FILE"
    pushover_notify "$NOTIFICATION_TITLE" "$NOTIFICATION_MESSAGE" "$NOTIFICATION_PRIORITY"
fi

exit 0 # Script itself exits successfully regardless of backup outcome, Pushover handles alerts
