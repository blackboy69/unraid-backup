#!/bin/bash

# --- INSTALLATION INSTRUCTIONS FOR (Debian VM) ---
# This script (`backup.sh`) runs on your Debian VM.
# It depends on `mount_up.sh` being in the same directory or /usr/local/bin.
#
# 1. Update your system:
#    sudo apt update
#    sudo apt upgrade -y
#
# 2. Install necessary packages for both backup.sh and mount_up.sh:
#    (mergerfs is for pooling ZFS disks, cifs-utils for SMB mounts,
#     samba-client for smbclient, util-linux for findmnt)
#    sudo apt install -y rsync cifs-utils samba-client util-linux zfsutils-linux smartmontools jq curl mergerfs
#
# 3. Configure Sudoers:
#    The user running this script needs sudo NOPASSWD access for specific commands.
#    `mount_up.sh` is called with `sudo` by this script, and handles its own internal sudo needs.
#    a. Edit the sudoers file:
#       sudo visudo
#    b. Add the following line, replacing 'your_username' with the actual username running the script:
#       your_username ALL=(ALL) NOPASSWD: /usr/sbin/zpool, /usr/sbin/zfs, /usr/sbin/smartctl, /usr/bin/journalctl, /usr/local/bin/mount_up.sh
#
# 4. Set up individual ZFS Pools on your passed-through disks:
#    (Example for /dev/sdb - replace with your actual disk devices)
#    sudo zpool create -f pool_disk1 /dev/sdb
#    sudo zpool create -f pool_disk2 /dev/sdc
#    # ... repeat for all your individual disks ...
#    (ZFS pools will typically auto-mount under /pool_disk1, /pool_disk2 etc.)
#
# 5. Configure `mergerfs`:
#    (mergerfs package should already be installed from step 2)
#    Create a mount point for your merged pool:
#    sudo mkdir /mnt/merged_pool
#    Edit /etc/fstab to configure mergerfs to mount at boot. This combines your ZFS pools.
#    sudo nano /etc/fstab
#    Add a line like this (adjust ZFS pool mount points and mergerfs options as needed):
#    /pool_disk1:/pool_disk2:/pool_disk3 /mnt/merged_pool fuse.mergerfs defaults,allow_other,use_mfs,minfreespace=10G,fsname=mergerfs_pool 0 0
#    Save, exit, then mount: sudo mount -a
#
# 6. Place `backup.sh` (this script) and `mount_up.sh`:
#    Assumes scripts are in /usr/local/bin for cron job.
#    sudo cp backup.sh /usr/local/bin/backup.sh
#    sudo cp mount_up.sh /usr/local/bin/mount_up.sh # Ensure mount_up.sh is present
#    sudo chmod +x /usr/local/bin/backup.sh
#    sudo chmod +x /usr/local/bin/mount_up.sh
#
# 7. Create .env Configuration File for `mount_up.sh` and `backup.sh`:
#    This file stores sensitive details and configurations. Place it where `ENV_FILE` variable points.
#    Default for `ENV_FILE` is same directory as script, e.g. /usr/local/bin/.env
#    sudo nano /usr/local/bin/.env
#    Add content like the example below, adjusting to your setup:
#    ---
#    MOUNT_BASE_DIR="/mnt/smb_shares"
#    DEFAULT_MOUNT_OPTIONS="ro,iocharset=utf8,vers=3.0,uid=0,gid=0,forceuid,forcegid,file_mode=0644,dir_mode=0755"
#    SERVER_IP="YOUR_NAS_IP_ADDRESS"
#    SMB_USERNAME="your_smb_user"
#    SMB_CREDENTIALS_PATH="/root/.smb_credentials_backup"
#    # Optional: PUSHOVER_APP_TOKEN="your_app_token"
#    # Optional: PUSHOVER_USER_KEY="your_user_key"
#    ---
#    Set secure permissions: sudo chmod 600 /usr/local/bin/.env
#
# 8. Create SMB Credentials File (referenced in .env by SMB_CREDENTIALS_PATH):
#    Example path: /root/.smb_credentials_backup (must match SMB_CREDENTIALS_PATH in .env)
#    sudo nano /root/.smb_credentials_backup
#    Add:
#    ---
#    username=your_smb_user
#    password=YOUR_ACTUAL_SMB_PASSWORD
#    ---
#    Set secure permissions: sudo chmod 600 /root/.smb_credentials_backup
#
# 9. Configure `backup.sh` Variables:
#    Review the "--- START CONFIGURATION ---" section in this script.
#    Ensure `ENV_FILE` path is correct if you didn't place .env in /usr/local/bin.
#    `PUSHOVER_APP_TOKEN` and `PUSHOVER_USER_KEY` can be set in script or in .env.
#    `SOURCE_FOLDERS` is now dynamically determined and should not be set manually.
#
# 10. Schedule with Cron:
#     Run as root or the user configured in sudoers (see step 3).
#     sudo crontab -e
#     Add (e.g., daily at 2 AM):
#     0 2 * * * /usr/local/bin/backup.sh >> /var/log/backup_cron.log 2>&1
#
# --- END INSTALLATION INSTRUCTIONS ---
#
# --- SMB Mount Configuration (Handled by mount_up.sh) ---
# The script will now call mount_up.sh to handle SMB mounts.
# Ensure mount_up.sh is configured with a .env file in the same directory
# (e.g. /usr/local/bin/.env) containing:
#   MOUNT_BASE_DIR="/mnt/smb_mounts"
#   DEFAULT_MOUNT_OPTIONS="vers=3.0,ro,iocharset=utf8,uid=0,gid=0,forceuid,forcegid,file_mode=0644,dir_mode=0755"
#   SERVER_IP="YOUR_NAS_IP"
#   SMB_USERNAME="smb_backup_user"
#   SMB_CREDENTIALS_PATH="/root/.smbcredentials_backup" (or other secure path)
#
# The .smbcredentials_backup file should contain:
#   username=smb_backup_user
#   password=YOUR_SMB_PASSWORD
# And have permissions 600.
#
# mount_up.sh will discover shares from SERVER_IP and mount them under MOUNT_BASE_DIR.
# This script (backup.sh) will then dynamically find these mounts.
# ---

# --- START CONFIGURATION ---

# Path to the .env file. Assumes it's in the same directory as the script.
# If this script is /usr/local/bin/backup.sh, then .env is /usr/local/bin/.env
ENV_FILE="$(dirname "$0")/.env"

# Pushover API Details (GET THESE FROM YOUR PUSHOVER APP)
# These can also be moved to the .env file if preferred.
PUSHOVER_APP_TOKEN="YOUR_PUSHOVER_APP_TOKEN" # Replace with your Pushover application token
PUSHOVER_USER_KEY="YOUR_PUSHOVER_USER_KEY"   # Replace with your Pushover user key

# Source (NAS) Mounted Shares Details
# IMPORTANT: These paths will be dynamically determined after mount_up.sh runs.
# This variable will be populated by the script.
SOURCE_FOLDERS=""
# Example of how it might look after mount_up.sh:
# SOURCE_FOLDERS="/mnt/smb_mounts/YOUR_NAS_IP_media_movies/ /mnt/smb_mounts/YOUR_NAS_IP_media_tvshows/"

# Rsync Exclusion Filters (space-separated list of patterns to exclude within shares)
# Rsync will ignore these files/folders globally within any synced share.
# Note: The actual RSYNC_EXCLUDES array is defined further down and is the correct one.
# This empty one below was causing a shellcheck parsing error.
# RSYNC_EXCLUDES=(


# --- START CONFIGURATION ---

# Pushover API Details (GET THESE FROM YOUR PUSHOVER APP)
# IMPORTANT: Store these securely. If running via cron, consider adding them to
# /etc/environment or your user's .profile/.bashrc, or source a separate config file.
PUSHOVER_APP_TOKEN="YOUR_PUSHOVER_APP_TOKEN" # Replace with your Pushover application token
PUSHOVER_USER_KEY="YOUR_PUSHOVER_USER_KEY"   # Replace with your Pushover user key

# Example of how it might look after mount_up.sh:
# SOURCE_FOLDERS="/mnt/smb_mounts/YOUR_NAS_IP_media_movies/ /mnt/smb_mounts/YOUR_NAS_IP_media_tvshows/"

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

# Function to load environment variables from .env file
load_env() {
    echo "$(date) INFO: Loading environment variables from ${ENV_FILE}..." | tee -a "$LOG_FILE"
    if [[ ! -f "${ENV_FILE}" ]]; then
        echo "$(date) ERROR: .env file '${ENV_FILE}' not found." | tee -a "$LOG_FILE"
        # Attempt to find .env in /usr/local/bin as a fallback for cronjob execution
        if [[ -f "/usr/local/bin/.env" ]]; then
            ENV_FILE="/usr/local/bin/.env"
            echo "$(date) INFO: Found .env file at ${ENV_FILE}" | tee -a "$LOG_FILE"
        else
            echo "$(date) ERROR: .env file also not found in /usr/local/bin/. Exiting." | tee -a "$LOG_FILE"
            # exit 1 # Exiting can be problematic for shellcheck in some contexts; error message should suffice.
            return 1 # Indicate failure
        fi
    fi

    local env_permissions
    env_permissions=$(stat -c "%a" "${ENV_FILE}")
    # SC2155: Declare and assign separately. Applied.
    # The original if had a syntax error: if [[ "$env_permissions" != "600" ]]; {
    # Corrected to:
    if [[ "$env_permissions" != "600" ]]; then
        # In a cron job, this might be too strict if script dir is not user-owned.
        # For now, we'll warn but not exit, as critical creds are in SMB_CREDENTIALS_PATH
        echo "$(date) WARNING: .env file '${ENV_FILE}' has insecure permissions (${env_permissions}). Recommended: 600." | tee -a "$LOG_FILE"
    fi

    set -a # Automatically export all variables after this point
    # shellcheck source=./.env
    source "${ENV_FILE}"
    set +a # Stop automatically exporting variables

    # Verify essential variables for backup.sh (some are for mount_up.sh, loaded there)
    if [[ -z "${MOUNT_BASE_DIR}" || -z "${SERVER_IP}" ]]; then
        echo "$(date) ERROR: Missing one or more required variables in ${ENV_FILE} for backup.sh:" | tee -a "$LOG_FILE"
        echo "         MOUNT_BASE_DIR, SERVER_IP." | tee -a "$LOG_FILE"
        echo "         Please check your .env file." | tee -a "$LOG_FILE"
        # exit 1 # Exiting can be problematic.
        return 1 # Indicate failure
    fi
    echo "$(date) INFO: Environment variables loaded." | tee -a "$LOG_FILE"
    return 0 # Indicate success
}


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
    local hostname_cmd
    hostname_cmd=$(hostname) # Capture hostname once

    local check_period="24 hours ago" # How far back to check logs

    # Check dmesg for recent critical errors
    local dmesg_errors
    dmesg_errors=$(journalctl -k --since "$check_period" | grep -E "error|fail|critical" | grep -Ev "error_report|failed to stat" | head -n 5)
    if [[ -n "$dmesg_errors" ]]; then
        message+="Critical kernel errors found in dmesg. "
        error_found=1
    fi

    # Check ZFS pool status for errors
    local zfs_status_output
    zfs_status_output=$(sudo zpool status -x)
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
        local pool_devices
        pool_devices=$(sudo zpool status "$pool" | grep -E "sd[a-z]|nvme[0-9]" | awk '{print $1}')
        for device in $pool_devices; do
            local disk_path="/dev/$device"
            if [[ ! -e "$disk_path" ]]; then
                echo "$(date) WARNING: Disk path $disk_path not found for SMART check. Skipping." | tee -a "$LOG_FILE"
                continue
            fi

            local smart_health
            smart_health=$(sudo smartctl -H "$disk_path" | grep "SMART overall-health self-assessment test result:")
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
        # mount_up.sh should have already mounted these.
        # We still check if it's a valid directory, as a basic sanity check.
        if [[ ! -d "$src_folder_path" ]]; then
            echo "$(date) ERROR: Source directory '$src_folder_path' does not exist or is not a directory. Skipping." | tee -a "$LOG_FILE"
            rsync_failed=1
            continue
        fi

        # The share name is derived from the directory name created by mount_up.sh
        # e.g., /mnt/smb_mounts/192_168_1_10_media_movies -> 192_168_1_10_media_movies
        local mounted_share_basename
        mounted_share_basename=$(basename "${src_folder_path%/}")
        # We want to store it in DEST_SUBDIR like 'media_movies', not '192_168_1_10_media_movies'
        # We need to strip the SERVER_IP prefix that mount_up.sh adds.
        local server_ip_prefix="${SERVER_IP//./_}_"
        local original_share_name="${mounted_share_basename#"$server_ip_prefix"}" # SC2295 fix: Added quotes

        if [[ -z "$original_share_name" ]]; then # Safety check if stripping failed
            original_share_name="$mounted_share_basename" # Fallback to full name
            echo "$(date) WARNING: Could not strip SERVER_IP prefix from '$mounted_share_basename'. Using full name for destination." | tee -a "$LOG_FILE"
        fi

        local dest_path="${FINAL_DEST}/${original_share_name}/" # Backup each share into its own subdirectory

        echo "$(date) INFO: Syncing '$original_share_name' from '$src_folder_path' to '$dest_path'" | tee -a "$LOG_FILE" # SC2154 fix: Used original_share_name
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

        if ! eval "$rsync_command" 2>&1 | tee -a "$LOG_FILE"; then # SC2181 fix for eval
            echo "$(date) ERROR: Rsync failed for share '$original_share_name'. Check log for details." | tee -a "$LOG_FILE" # SC2154 fix (already applied but verify)
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
    local snapshot_timestamp
    snapshot_timestamp=$(date +%Y-%m-%d_%H%M)
    local snapshot_name="${SNAPSHOT_PREFIX}@${snapshot_timestamp}"
    local snapshot_failed=0

    for pool in $ZFS_POOLS; do
        echo "$(date) INFO: Taking snapshot of ZFS pool '$pool'..." | tee -a "$LOG_FILE"
        # We snapshot the root dataset of each ZFS pool, as mergerfs distributes files across them.
        if ! sudo zfs snapshot "${pool}@${snapshot_name}" 2>&1 | tee -a "$LOG_FILE"; then # SC2181 fix
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
        local snapshots_list
        snapshots_list=$(sudo zfs list -t snapshot -o name,creation -s creation -r "${pool}" | grep "${pool}@${SNAPSHOT_PREFIX}" | awk '{print $1}')

        local keep_daily_count=0
        local keep_weekly_count=0
        local keep_monthly_count=0
        local keep_yearly_count=0

        for snapshot in $snapshots_list; do
            local creation_epoch
            creation_epoch=$(sudo zfs get -Hp creation "$snapshot" | awk '{print $2}') # epoch time
            local current_epoch
            current_epoch=$(date +%s)
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
                # local week_num=$((age_days / 7)) # SC2034: week_num appears unused.
                local found_later_in_week=0
                # Check if there's any snapshot created later in the same week that we're keeping
                for later_snapshot in $snapshots_list; do
                    if [[ "$later_snapshot" == "$snapshot" ]]; then continue; fi # Skip self
                    local later_creation_epoch
                    later_creation_epoch=$(sudo zfs get -Hp creation "$later_snapshot" | awk '{print $2}')
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
                # local month_num=$((age_days / 30)) # SC2034: month_num appears unused.
                local found_later_in_month=0
                for later_snapshot in $snapshots_list; do
                    if [[ "$later_snapshot" == "$snapshot" ]]; then continue; fi
                    local later_creation_epoch
                    later_creation_epoch=$(sudo zfs get -Hp creation "$later_snapshot" | awk '{print $2}')
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
                # local year_num=$((age_days / 365)) # SC2034: year_num appears unused.
                local found_later_in_year=0
                for later_snapshot in $snapshots_list; do
                    if [[ "$later_snapshot" == "$snapshot" ]]; then break; fi
                    local later_creation_epoch
                    later_creation_epoch=$(sudo zfs get -Hp creation "$later_snapshot" | awk '{print $2}')
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
                if ! sudo zfs destroy "$snapshot" 2>&1 | tee -a "$LOG_FILE"; then # SC2181 fix
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
MOUNT_UP_SCRIPT="/usr/local/bin/mount_up.sh" # Path to mount_up.sh

# Cleanup function to be called on exit
cleanup_mounts() {
    echo "$(date) INFO: Running cleanup task: unmounting shares via mount_up.sh..." | tee -a "$LOG_FILE"
    # This will call mount_up.sh, which first unmounts all existing managed shares.
    # For a strict unmount-only, mount_up.sh would need an argument.
    # For now, this ensures they are unmounted before script exits, even if it then tries to remount.
    if [[ -x "$MOUNT_UP_SCRIPT" ]]; then
        # Ideally, mount_up.sh should have an --unmount-only flag.
        # Calling it as is will unmount then attempt to remount.
        # This is acceptable for now as it achieves unmounting.
        if ! sudo "$MOUNT_UP_SCRIPT" --unmount-only >> "$LOG_FILE" 2>&1; then # SC2181 fix
            echo "$(date) WARNING: mount_up.sh (for unmounting) exited with an error during cleanup." | tee -a "$LOG_FILE"
        else
            echo "$(date) INFO: mount_up.sh (for unmounting) completed during cleanup." | tee -a "$LOG_FILE"
        fi
    else
        echo "$(date) WARNING: $MOUNT_UP_SCRIPT not found or not executable. Cannot unmount shares automatically." | tee -a "$LOG_FILE"
    fi
}

# Set trap to run cleanup_mounts on EXIT, TERM, INT
trap cleanup_mounts EXIT TERM INT

echo "--- $(date) Starting Backup Job on $HOSTNAME_VAR ---" | tee -a "$LOG_FILE"

# Load environment variables from .env file
if ! load_env; then # SC2181 fix (applied to function call)
    SCRIPT_STATUS="FAILURE"
    NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: CRITICAL!"
    NOTIFICATION_MESSAGE="Failed to load .env file or essential variables. Backup script cannot continue. Check $LOG_FILE."
    NOTIFICATION_PRIORITY=2 # Highest priority
    # Attempt to send Pushover notification if tokens are available (might not be if .env failed)
    # This is a best-effort notification for critical failure.
    pushover_notify "$NOTIFICATION_TITLE" "$NOTIFICATION_MESSAGE" "$NOTIFICATION_PRIORITY"
    echo "$(date) CRITICAL: .env loading failed. Exiting." | tee -a "$LOG_FILE"
    exit 1 # Critical failure, cannot proceed
fi

# Step 0: Check logs and notify (High priority if errors found)
if ! check_logs; then
    SCRIPT_STATUS="FAILURE" # Set status but continue to try and unmount shares if any were mounted
    NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: ALERT!"
    NOTIFICATION_MESSAGE="Log check found errors before backup. Check logs on $HOSTNAME_VAR."
    NOTIFICATION_PRIORITY=1 # High priority
    # Notification will be sent at the end.
fi

# Step 1: Mount SMB shares using mount_up.sh
if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then
    echo "$(date) INFO: Calling mount_up.sh to mount SMB shares..." | tee -a "$LOG_FILE"
    if [[ -x "$MOUNT_UP_SCRIPT" ]]; then
        if ! sudo "$MOUNT_UP_SCRIPT" >> "$LOG_FILE" 2>&1; then # SC2181 fix
            SCRIPT_STATUS="FAILURE"
            NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: FAILED!"
            NOTIFICATION_MESSAGE="mount_up.sh script failed to mount shares. Check $LOG_FILE and mount_up.sh logs."
            NOTIFICATION_PRIORITY=1
            echo "$(date) ERROR: $MOUNT_UP_SCRIPT failed." | tee -a "$LOG_FILE"
        else
            echo "$(date) INFO: mount_up.sh completed successfully." | tee -a "$LOG_FILE"
            # Dynamically determine SOURCE_FOLDERS
            # mount_up.sh creates directories like /MOUNT_BASE_DIR/SERVER_IP_sharename
            # We need to find these and add a trailing slash for rsync
            formatted_server_ip="${SERVER_IP//./_}" # e.g., 192.168.1.10 -> 192_168_1_10

            # Ensure MOUNT_BASE_DIR does not have a trailing slash for robust find operation
            # Then use find to get all directories matching the pattern, and append a slash
            SOURCE_FOLDERS=$(find "${MOUNT_BASE_DIR%/}" -maxdepth 1 -type d -name "${formatted_server_ip}_*" -print0 | xargs -0 -I {} echo "{}/")

            if [[ -z "$SOURCE_FOLDERS" ]]; then
                SCRIPT_STATUS="FAILURE"
                NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: FAILED!"
                NOTIFICATION_MESSAGE="mount_up.sh ran, but no source folders found under ${MOUNT_BASE_DIR} for server ${SERVER_IP}."
                NOTIFICATION_PRIORITY=1
                echo "$(date) ERROR: No source folders found after running mount_up.sh. Check MOUNT_BASE_DIR and mount_up.sh logs." | tee -a "$LOG_FILE"
            else
                echo "$(date) INFO: Dynamically determined SOURCE_FOLDERS: ${SOURCE_FOLDERS}" | tee -a "$LOG_FILE"
            fi
        fi
    else
        SCRIPT_STATUS="FAILURE"
        NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: FAILED!"
        NOTIFICATION_MESSAGE="$MOUNT_UP_SCRIPT not found or not executable. Cannot mount shares."
        NOTIFICATION_PRIORITY=1
        echo "$(date) ERROR: $MOUNT_UP_SCRIPT not found or not executable." | tee -a "$LOG_FILE"
    fi
fi

# Step 2: Perform rsync backup
if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then # Only if mounts were successful
    if ! perform_rsync; then
        SCRIPT_STATUS="FAILURE"
        NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: FAILED!"
        NOTIFICATION_MESSAGE="Rsync failed. Check logs on $HOSTNAME_VAR."
        NOTIFICATION_PRIORITY=1
        # Pushover notification will be handled at the end
    fi
fi

# Only proceed with snapshots if rsync was successful
if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then
    # Step 3: Take snapshots
    if ! take_snapshots; then
        SCRIPT_STATUS="FAILURE"
        # Update notification vars, but send at the end
        NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: FAILED!"
        NOTIFICATION_MESSAGE="Snapshot creation failed. Check logs on $HOSTNAME_VAR."
        NOTIFICATION_PRIORITY=1
    fi
fi

# Always attempt rotation if ZFS_POOLS is set and script hasn't critically failed before this point
if [[ "$SCRIPT_STATUS" != "CRITICAL_ERROR_PREVENTING_ROTATION" && -n "$ZFS_POOLS" ]]; then
    # Step 4: Rotate snapshots
    if ! rotate_snapshots; then
        if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then # If backup was successful but rotation failed
            SCRIPT_STATUS="WARNING"
            NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: WARNING!"
            NOTIFICATION_MESSAGE="Backup successful, but snapshot rotation failed. Check logs on $HOSTNAME_VAR."
            NOTIFICATION_PRIORITY=0
        elif [[ "$SCRIPT_STATUS" == "FAILURE" ]]; then # If backup already failed, add to existing error message
            NOTIFICATION_MESSAGE+=" Snapshot rotation also failed."
            # Keep priority 1 if already a failure
        fi
        # If SCRIPT_STATUS was ALERT from log check, this warning will override it if logs were the only issue.
        # This is acceptable as rotation failure is a significant warning.
    fi
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Step 5: Notify final status via Pushover
# Consolidate notification sending to here.
# If SCRIPT_STATUS is still "SUCCESS", it means all critical steps succeeded.
if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then
    NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: SUCCESS"
    NOTIFICATION_MESSAGE="Backup job on $HOSTNAME_VAR completed successfully. Total Duration: ${DURATION} seconds."
    NOTIFICATION_PRIORITY=-1 # Quiet priority
    echo "--- $(date) Backup Job Finished successfully in ${DURATION} seconds ---" | tee -a "$LOG_FILE"
    pushover_notify "$NOTIFICATION_TITLE" "$NOTIFICATION_MESSAGE" "$NOTIFICATION_PRIORITY"
else
    # Append duration to whatever message was set
    NOTIFICATION_MESSAGE+=" Total Duration: ${DURATION} seconds."
    echo "--- $(date) Backup Job Finished with status: $SCRIPT_STATUS ---" | tee -a "$LOG_FILE"
    # Use previously set NOTIFICATION_TITLE, NOTIFICATION_MESSAGE, NOTIFICATION_PRIORITY
    pushover_notify "$NOTIFICATION_TITLE" "$NOTIFICATION_MESSAGE" "$NOTIFICATION_PRIORITY"
fi

# The trap will handle unmounting.
exit 0 # Script itself exits successfully; Pushover handles alerts.
