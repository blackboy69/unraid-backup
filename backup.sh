#!/bin/bash
# backup.sh - Main backup orchestration script.
# This script coordinates the backup process, including:
# - Loading configuration (defaults and from .env).
# - Mounting SMB shares from a NAS (via mount_up.sh).
# - Performing rsync backups from the shares to local btrfs filesystems.
# - Creating and rotating btrfs snapshots on these filesystems.
# - Checking system and btrfs logs for errors.
# - Sending status notifications via Pushover.
#
# It relies on several helper scripts in the same directory:
# - backup_config.sh: Defines default configuration variables.
# - logging_utils.sh: Provides pushover_notify function.
# - system_checks.sh: Provides check_logs function.
# - rsync_operations.sh: Provides perform_rsync function.
# - snapshot_utils.sh: Provides take_snapshots and rotate_snapshots functions.

# --- INSTALLATION INSTRUCTIONS FOR (Debian VM) ---
# This script (`backup.sh`) runs on your Debian VM.
# It depends on `mount_up.sh` being in the same directory or /usr/local/bin.
# Helper scripts (backup_config.sh, etc.) must be in the same directory as backup.sh.
#
# 1. Update your system:
#    sudo apt update
#    sudo apt upgrade -y
#
# 2. Install necessary packages for both backup.sh and mount_up.sh:
#    (mergerfs is for pooling btrfs disks, cifs-utils for SMB mounts,
#     samba-client for smbclient, util-linux for findmnt)
#    sudo apt install -y rsync cifs-utils samba-client util-linux btrfs-progs smartmontools jq curl mergerfs
#
# 3. Configure Sudoers:
#    The user running this script needs sudo NOPASSWD access for specific commands.
#    `mount_up.sh` is called with `sudo` by this script, and handles its own internal sudo needs.
#    a. Edit the sudoers file:
#       sudo visudo
#    b. Add the following line, replacing 'your_username' with the actual username running the script:
#       your_username ALL=(ALL) NOPASSWD: /sbin/btrfs, /usr/sbin/smartctl, /usr/bin/journalctl, /usr/local/bin/mount_up.sh
#
# 4. Set up individual btrfs filesystems on your passed-through disks:
#    (Example for /dev/sdb - replace with your actual disk devices)
#    sudo mkfs.btrfs -L btrfs_disk1 /dev/sdb
#    sudo mkfs.btrfs -L btrfs_disk2 /dev/sdc
#    # ... repeat for all your individual disks ...
#    # Create mount points for each btrfs filesystem
#    sudo mkdir /btrfs_disk1 /btrfs_disk2 # These paths must match BTRFS_MOUNT_POINTS in backup_config.sh or .env
#    # Mount them (or add to /etc/fstab for auto-mounting using LABELs is recommended)
#    sudo mount /dev/sdb /btrfs_disk1
#    sudo mount /dev/sdc /btrfs_disk2
#    # Example /etc/fstab entries:
#    # LABEL=btrfs_disk1 /btrfs_disk1 btrfs defaults 0 0
#    # LABEL=btrfs_disk2 /btrfs_disk2 btrfs defaults 0 0
#    # After fstab changes: sudo systemctl daemon-reload && sudo mount -a
#    # Ensure a .snapshots directory exists in the root of each btrfs filesystem for snapshot storage
#    # The snapshot_utils.sh script will attempt to create these if they don't exist.
#    # sudo mkdir /btrfs_disk1/.snapshots /btrfs_disk2/.snapshots
#
# 5. Configure `mergerfs`:
#    (mergerfs package should already be installed from step 2)
#    Create a mount point for your merged pool (must match DEST_ROOT in backup_config.sh or .env):
#    sudo mkdir /mnt/merged_pool
#    Edit /etc/fstab to configure mergerfs to mount at boot. This combines your btrfs filesystems.
#    sudo nano /etc/fstab
#    Add a line like this (adjust btrfs filesystem mount points and mergerfs options as needed):
#    /btrfs_disk1:/btrfs_disk2:/btrfs_disk3 /mnt/merged_pool fuse.mergerfs defaults,allow_other,use_mfs,minfreespace=10G,fsname=mergerfs_pool 0 0
#    Save, exit, then mount: sudo mount -a
#
# 6. Place Scripts:
#    Place `backup.sh` and all helper scripts (e.g., `backup_config.sh`, `logging_utils.sh`, etc.)
#    in a directory like /usr/local/bin/backup_scripts/
#    Place `mount_up.sh` in /usr/local/bin/ or ensure it's in the system PATH.
#    sudo mkdir -p /usr/local/bin/backup_scripts
#    sudo cp backup.sh backup_config.sh logging_utils.sh system_checks.sh rsync_operations.sh snapshot_utils.sh /usr/local/bin/backup_scripts/
#    sudo cp mount_up.sh /usr/local/bin/mount_up.sh # Or your preferred location for mount_up.sh
#    sudo chmod +x /usr/local/bin/backup_scripts/*.sh
#    sudo chmod +x /usr/local/bin/mount_up.sh
#
# 7. Create .env Configuration File:
#    This file stores sensitive details and local overrides for `backup_config.sh`.
#    Place it in the same directory as `backup.sh` (e.g., /usr/local/bin/backup_scripts/.env).
#    sudo nano /usr/local/bin/backup_scripts/.env
#    Add content like the example below, adjusting to your setup:
#    ---
#    MOUNT_BASE_DIR="/mnt/smb_shares"
#    DEFAULT_MOUNT_OPTIONS="ro,iocharset=utf8,vers=3.0,uid=0,gid=0,forceuid,forcegid,file_mode=0644,dir_mode=0755"
#    SERVER_IP="YOUR_NAS_IP_ADDRESS"
#    SMB_USERNAME="your_smb_user"
#    SMB_CREDENTIALS_PATH="/root/.smb_credentials_backup" # Secure path for SMB credentials
#    # Optional: Override Pushover tokens from backup_config.sh
#    # PUSHOVER_APP_TOKEN="your_actual_app_token"
#    # PUSHOVER_USER_KEY="your_actual_user_key"
#    # Optional: Override BTRFS_MOUNT_POINTS, DEST_ROOT, etc.
#    # BTRFS_MOUNT_POINTS="/mnt/mydisk1 /mnt/mydisk2"
#    ---
#    Set secure permissions: sudo chmod 600 /usr/local/bin/backup_scripts/.env
#
# 8. Create SMB Credentials File (referenced in .env by SMB_CREDENTIALS_PATH):
#    Example path: /root/.smb_credentials_backup
#    sudo nano /root/.smb_credentials_backup
#    Add:
#    ---
#    username=your_smb_user
#    password=YOUR_ACTUAL_SMB_PASSWORD
#    ---
#    Set secure permissions: sudo chmod 600 /root/.smb_credentials_backup
#
# 9. Configure Variables:
#    Review `backup_config.sh` for default settings.
#    Override any necessary settings in the `.env` file as per step 7.
#    `SOURCE_FOLDERS` is dynamically determined by this script and should not be set manually.
#
# 10. Schedule with Cron:
#     Run as root or the user configured in sudoers (see step 3).
#     Example: sudo crontab -e
#     Add (e.g., daily at 2 AM, assuming scripts in /usr/local/bin/backup_scripts/):
#     0 2 * * * /usr/local/bin/backup_scripts/backup.sh >> /var/log/backup_cron.log 2>&1
#
# --- END INSTALLATION INSTRUCTIONS ---

# --- Source Helper Scripts ---
# SCRIPT_DIR will be the directory where backup.sh and its helper scripts are located.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source default configurations first. These can be overridden by .env.
source "${SCRIPT_DIR}/backup_config.sh"

# Source utility functions from helper scripts.
source "${SCRIPT_DIR}/logging_utils.sh"
source "${SCRIPT_DIR}/system_checks.sh"
source "${SCRIPT_DIR}/rsync_operations.sh"
source "${SCRIPT_DIR}/snapshot_utils.sh"

# --- Path to .env file ---
# ENV_FILE path is relative to the script's location.
ENV_FILE="${SCRIPT_DIR}/.env"

# --- Dynamic & Global Variables ---
# SOURCE_FOLDERS: Populated after mount_up.sh runs, listing mounted SMB shares.
SOURCE_FOLDERS=""
# HOSTNAME_VAR: Current hostname, used in notifications. Exported for system_checks.sh.
HOSTNAME_VAR=$(hostname)
export HOSTNAME_VAR

# --- Core Helper Functions (defined in backup.sh) ---

# Loads variables from the .env file.
# Variables in .env can override those set in backup_config.sh.
# Ensures essential variables for script operation are present.
# Globals:
#   ENV_FILE: Path to the .env file.
#   LOG_FILE: Path for logging (must be defined in backup_config.sh or .env).
#   MOUNT_BASE_DIR, SERVER_IP: (from .env) checked for presence.
# Returns:
#   0 if .env loaded successfully (or not found but optional) and essentials are present.
#   1 if .env is required but not found, or essential variables are missing.
load_env() {
    echo "$(date) INFO: Attempting to load environment variables from ${ENV_FILE}..." | tee -a "$LOG_FILE"
    if [[ ! -f "${ENV_FILE}" ]]; then
        echo "$(date) INFO: .env file '${ENV_FILE}' not found. Using defaults from backup_config.sh and script." | tee -a "$LOG_FILE"
        # If .env is strictly required, one might exit here. For now, it's optional.
    else
        local env_permissions
        env_permissions=$(stat -c "%a" "${ENV_FILE}")
        if [[ "$env_permissions" != "600" ]]; then
            echo "$(date) WARNING: .env file '${ENV_FILE}' has insecure permissions (${env_permissions}). Recommended: 600." | tee -a "$LOG_FILE"
        fi

        # Source the .env file. `set -a` exports all variables defined within it.
        set -a
        # shellcheck source=./.env # Path is dynamic, shellcheck may not find it.
        source "${ENV_FILE}"
        set +a
        echo "$(date) INFO: Successfully loaded variables from ${ENV_FILE}." | tee -a "$LOG_FILE"
    fi

    # Verify essential variables are now set (either from backup_config.sh or .env).
    if [[ -z "${MOUNT_BASE_DIR}" || -z "${SERVER_IP}" || -z "${LOG_FILE}" ]]; then
        echo "$(date) ERROR: Essential variables (MOUNT_BASE_DIR, SERVER_IP, LOG_FILE) are missing after checking backup_config.sh and .env. Script cannot continue." | tee -a "${LOG_FILE:-/tmp/backup_early_error.log}"
        return 1 # Indicate critical failure.
    fi

    # Re-derive FINAL_DEST in case DEST_ROOT or DEST_SUBDIR were overridden by .env
    FINAL_DEST="${DEST_ROOT}/${DEST_SUBDIR}"

    echo "$(date) INFO: Environment variables initialized. LOG_FILE is $LOG_FILE." | tee -a "$LOG_FILE"
    return 0
}

# --- Main Script Execution Logic ---

# Record start time for duration calculation.
START_TIME=$(date +%s)
# Initialize script status. This will be updated based on outcomes of operations.
SCRIPT_STATUS="SUCCESS"
# Path to the mount_up.sh script.
MOUNT_UP_SCRIPT="/usr/local/bin/mount_up.sh" # Adjust if mount_up.sh is elsewhere.

# Cleanup function to unmount shares on script exit (normal or error).
# Triggered by EXIT, TERM, INT signals.
cleanup_mounts() {
    echo "$(date) INFO: Running cleanup task: attempting to unmount shares via mount_up.sh..." | tee -a "$LOG_FILE"
    if [[ -x "$MOUNT_UP_SCRIPT" ]]; then
        # Call mount_up.sh with --unmount-only flag (assuming mount_up.sh supports this).
        # If mount_up.sh doesn't support --unmount-only, it might try to remount,
        # which is generally acceptable for cleanup as it ensures unmounting first.
        if ! sudo "$MOUNT_UP_SCRIPT" --unmount-only >> "$LOG_FILE" 2>&1; then
            echo "$(date) WARNING: mount_up.sh (for unmounting) exited with an error during cleanup. Check logs." | tee -a "$LOG_FILE"
        else
            echo "$(date) INFO: mount_up.sh (for unmounting) completed during cleanup." | tee -a "$LOG_FILE"
        fi
    else
        echo "$(date) WARNING: $MOUNT_UP_SCRIPT not found or not executable. Cannot unmount shares automatically." | tee -a "$LOG_FILE"
    fi
}
trap cleanup_mounts EXIT TERM INT

# --- Backup Process Start ---
echo "--- $(date) Starting Backup Job on $HOSTNAME_VAR ---" | tee -a "$LOG_FILE"

# Step 1: Load environment variables from .env, potentially overriding defaults from backup_config.sh.
# This must happen before any operation that relies on these variables, especially LOG_FILE.
if ! load_env; then
    SCRIPT_STATUS="FAILURE" # load_env already logged critical error.
    # Attempt to send a Pushover notification if PUSHOVER tokens were somehow set before load_env failed for other reasons.
    # This is a best-effort notification for critical failure.
    if [[ -n "$PUSHOVER_APP_TOKEN" && -n "$PUSHOVER_USER_KEY" ]]; then
         pushover_notify "$HOSTNAME_VAR Backup Status: CRITICAL FAILURE!" "Failed to load .env file or essential variables. Backup script cannot continue. Check ${LOG_FILE:-/tmp/backup_early_error.log}." 2
    fi
    echo "$(date) CRITICAL: Environment loading failed. Exiting." | tee -a "${LOG_FILE:-/tmp/backup_early_error.log}"
    exit 1 # Critical failure, cannot proceed.
fi

# Step 2: Check system logs and hardware health before starting backup operations.
if ! check_logs; then # check_logs sends its own notification on failure.
    SCRIPT_STATUS="FAILURE" # Mark script as failed but continue to attempt other steps like unmounting.
    NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: SYSTEM ALERT before Backup"
    NOTIFICATION_MESSAGE="System health check found errors before backup operations started. Backup attempt will continue if possible, but check logs on $HOSTNAME_VAR."
    NOTIFICATION_PRIORITY=1
    # Note: A comprehensive notification will be sent at the end. This just sets the stage.
fi

# Step 3: Mount SMB shares using mount_up.sh. Only proceed if previous steps were successful enough.
if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then
    echo "$(date) INFO: Calling mount_up.sh to mount SMB shares..." | tee -a "$LOG_FILE"
    if [[ -x "$MOUNT_UP_SCRIPT" ]]; then
        # mount_up.sh should handle its own logging. Output is also captured here.
        if ! sudo "$MOUNT_UP_SCRIPT" >> "$LOG_FILE" 2>&1; then
            SCRIPT_STATUS="FAILURE"
            NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: MOUNT FAILED!"
            NOTIFICATION_MESSAGE="mount_up.sh script failed to mount SMB shares. Check $LOG_FILE and mount_up.sh logs for details."
            NOTIFICATION_PRIORITY=1
            echo "$(date) ERROR: $MOUNT_UP_SCRIPT failed to mount shares." | tee -a "$LOG_FILE"
        else
            echo "$(date) INFO: mount_up.sh completed successfully. Discovering mounted shares..." | tee -a "$LOG_FILE"
            # Dynamically determine SOURCE_FOLDERS from mounted shares.
            # Assumes mount_up.sh creates directories like /MOUNT_BASE_DIR/SERVER_IP_sharename/
            local formatted_server_ip="${SERVER_IP//./_}" # Convert SERVER_IP to filesystem-safe format.

            # Find directories matching the pattern and append a trailing slash for rsync.
            # Ensure MOUNT_BASE_DIR does not have a trailing slash for robust find.
            SOURCE_FOLDERS=$(find "${MOUNT_BASE_DIR%/}" -maxdepth 1 -type d -name "${formatted_server_ip}_*" -print0 | xargs -0 -I {} echo "{}/")

            if [[ -z "$SOURCE_FOLDERS" ]]; then
                SCRIPT_STATUS="FAILURE"
                NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: MOUNT WARNING!"
                NOTIFICATION_MESSAGE="mount_up.sh ran, but no source folders (SMB shares) were found under ${MOUNT_BASE_DIR} for server ${SERVER_IP}. Rsync will be skipped."
                NOTIFICATION_PRIORITY=1 # Treat as failure if no sources found.
                echo "$(date) ERROR: No source folders found after running mount_up.sh. Check MOUNT_BASE_DIR ('$MOUNT_BASE_DIR') and mount_up.sh logs." | tee -a "$LOG_FILE"
            else
                echo "$(date) INFO: Dynamically determined SOURCE_FOLDERS for rsync: ${SOURCE_FOLDERS}" | tee -a "$LOG_FILE"
            fi
        fi
    else
        SCRIPT_STATUS="FAILURE"
        NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: SCRIPT MISSING!"
        NOTIFICATION_MESSAGE="$MOUNT_UP_SCRIPT not found or not executable at '$MOUNT_UP_SCRIPT'. Cannot mount SMB shares."
        NOTIFICATION_PRIORITY=1
        echo "$(date) ERROR: $MOUNT_UP_SCRIPT not found or not executable." | tee -a "$LOG_FILE"
    fi
fi

# Step 4: Perform rsync backup. Only if mounts were (or seemed) successful.
if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then
    if ! perform_rsync; then # perform_rsync logs its own errors.
        SCRIPT_STATUS="FAILURE"
        NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: RSYNC FAILED!"
        NOTIFICATION_MESSAGE="Rsync operation failed during backup. Check logs on $HOSTNAME_VAR for details of failed shares."
        NOTIFICATION_PRIORITY=1
    fi
fi

# Step 5: Take btrfs snapshots. Only if rsync was successful.
if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then
    if ! take_snapshots; then # take_snapshots logs its own errors.
        SCRIPT_STATUS="FAILURE"
        NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: SNAPSHOT FAILED!"
        NOTIFICATION_MESSAGE="btrfs snapshot creation failed after rsync. Check logs on $HOSTNAME_VAR."
        NOTIFICATION_PRIORITY=1
    fi
fi

# Step 6: Rotate btrfs snapshots.
# This runs even if the backup part (rsync/snapshot) failed, to ensure old snapshots are still pruned.
# However, it doesn't run if there was a critical configuration error earlier.
if [[ "$SCRIPT_STATUS" != "CRITICAL_ERROR_PREVENTING_ROTATION" && -n "$BTRFS_MOUNT_POINTS" ]]; then # Check BTRFS_MOUNT_POINTS exists
    if ! rotate_snapshots; then # rotate_snapshots logs its own errors.
        # If backup was successful but only rotation failed, it's a warning.
        if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then
            SCRIPT_STATUS="WARNING"
            NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: ROTATION WARNING!"
            NOTIFICATION_MESSAGE="Backup (rsync and snapshot creation) was successful, but snapshot rotation failed. Check logs on $HOSTNAME_VAR."
            NOTIFICATION_PRIORITY=0 # Normal priority for rotation warning if backup itself was fine.
        elif [[ "$SCRIPT_STATUS" == "FAILURE" ]]; then
            # If backup already failed, append to the existing failure message.
            NOTIFICATION_MESSAGE+=" Additionally, snapshot rotation also failed."
            # Keep high priority from the earlier failure.
        fi
    fi
else
    if [[ -z "$BTRFS_MOUNT_POINTS" ]]; then
         echo "$(date) INFO: BTRFS_MOUNT_POINTS is not set or empty. Skipping snapshot rotation." | tee -a "$LOG_FILE"
    fi
fi

# --- Final Reporting ---
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Send final Pushover notification based on SCRIPT_STATUS.
if [[ "$SCRIPT_STATUS" == "SUCCESS" ]]; then
    NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: SUCCESS"
    NOTIFICATION_MESSAGE="Backup job on $HOSTNAME_VAR completed successfully. Total Duration: ${DURATION} seconds."
    NOTIFICATION_PRIORITY=-1 # Quiet notification for success.
    echo "--- $(date) Backup Job Finished successfully in ${DURATION} seconds ---" | tee -a "$LOG_FILE"
    pushover_notify "$NOTIFICATION_TITLE" "$NOTIFICATION_MESSAGE" "$NOTIFICATION_PRIORITY"
else
    # If SCRIPT_STATUS is WARNING or FAILURE, use the title/message/priority set during the step that failed/warned.
    # Append duration to the existing message.
    NOTIFICATION_MESSAGE+=" Total Duration: ${DURATION} seconds."
    echo "--- $(date) Backup Job Finished with status: $SCRIPT_STATUS in ${DURATION} seconds ---" | tee -a "$LOG_FILE"
    # Ensure default message if none was set (should not happen if logic is correct).
    if [[ -z "$NOTIFICATION_TITLE" ]]; then
        NOTIFICATION_TITLE="$HOSTNAME_VAR Backup Status: $SCRIPT_STATUS"
    fi
    if [[ -z "$NOTIFICATION_PRIORITY" ]]; then
        NOTIFICATION_PRIORITY=1 # Default to high priority for any non-success.
    fi
    pushover_notify "$NOTIFICATION_TITLE" "$NOTIFICATION_MESSAGE" "$NOTIFICATION_PRIORITY"
fi

# The 'trap cleanup_mounts' will handle unmounting shares.
# Exit with 0 if successful or warning, 1 if failure, to allow cron to report issues if not using Pushover.
if [[ "$SCRIPT_STATUS" == "FAILURE" ]]; then
    exit 1
else
    exit 0
fi
