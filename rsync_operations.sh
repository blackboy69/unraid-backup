#!/bin/bash
# rsync_operations.sh
# Contains the function to perform rsync backup operations.
# This script is intended to be sourced by the main backup.sh script.
# It relies on several environment variables being set by the caller:
#   LOG_FILE: Path to the log file.
#   FINAL_DEST: The root directory on the backup server where data will be synced.
#   RSYNC_EXCLUDES: Bash array of patterns to exclude from sync.
#   SOURCE_FOLDERS: Space-separated string of source directories (mounted SMB shares) to sync from.
#   SERVER_IP: IP address of the source NAS server (used to derive original share names).

# Performs the rsync operation from mounted SMB shares to the local backup destination.
# Iterates through each mounted share defined in SOURCE_FOLDERS.
# Globals:
#   LOG_FILE, FINAL_DEST, RSYNC_EXCLUDES, SOURCE_FOLDERS, SERVER_IP
# Returns:
#   0 if all rsync operations were successful.
#   1 if any rsync operation failed or critical prerequisites were not met.
perform_rsync() {
    echo "$(date) INFO: Starting rsync backup from NAS SMB shares to $FINAL_DEST..." | tee -a "$LOG_FILE"
    local rsync_failed=0 # Flag to track if any rsync operation fails.

    # Ensure the main backup destination directory exists.
    if ! mkdir -p "$FINAL_DEST"; then
        echo "$(date) ERROR: Failed to create main backup destination directory '$FINAL_DEST'. Rsync operations skipped." | tee -a "$LOG_FILE"
        return 1
    fi

    # Build rsync exclude arguments from the RSYNC_EXCLUDES array.
    local rsync_exclude_args_built=""
    if [[ ${#RSYNC_EXCLUDES[@]} -gt 0 ]]; then
        for exclude_pattern in "${RSYNC_EXCLUDES[@]}"; do
            rsync_exclude_args_built+="--exclude='${exclude_pattern}' "
        done
    fi

    # Check if SOURCE_FOLDERS is set. This is dynamically populated by backup.sh.
    if [[ -z "$SOURCE_FOLDERS" ]]; then
        echo "$(date) ERROR: SOURCE_FOLDERS variable is not set or empty. No shares to process for rsync." | tee -a "$LOG_FILE"
        return 1
    fi

    # SERVER_IP is crucial for correctly determining the original share name.
    if [[ -z "$SERVER_IP" ]]; then
        echo "$(date) ERROR: SERVER_IP variable is not set. Cannot reliably determine original share names for destination paths. Rsync operations skipped." | tee -a "$LOG_FILE"
        return 1
    fi

    # Convert SOURCE_FOLDERS string (potentially containing multiple paths) into a bash array.
    # This helps handle paths that might contain spaces, though typically SMB mount points don't.
    local source_folders_array=($SOURCE_FOLDERS)

    for src_folder_path_raw in "${source_folders_array[@]}"; do
        # Ensure source path has a trailing slash for rsync to copy contents, not the folder itself.
        local src_folder_path="${src_folder_path_raw%/}/"

        if [[ ! -d "$src_folder_path" ]]; then
            echo "$(date) ERROR: Source directory '$src_folder_path' does not exist or is not a directory. Skipping." | tee -a "$LOG_FILE"
            rsync_failed=1
            continue # Skip to the next source folder.
        fi

        # Derive the original share name to use as the subdirectory name in FINAL_DEST.
        # mounted_share_basename is like '192_168_1_10_media_movies'
        local mounted_share_basename
        mounted_share_basename=$(basename "${src_folder_path%/}")

        # server_ip_prefix is like '192_168_1_10_'
        local server_ip_prefix="${SERVER_IP//./_}_"
        # original_share_name becomes 'media_movies'
        local original_share_name="${mounted_share_basename#"$server_ip_prefix"}"

        # Fallback if prefix stripping failed (e.g., SERVER_IP was incorrect or share name unusual)
        if [[ -z "$original_share_name" || "$original_share_name" == "$mounted_share_basename" ]]; then
            original_share_name="$mounted_share_basename" # Use the full basename as a fallback.
            echo "$(date) WARNING: Could not reliably strip SERVER_IP prefix from '$mounted_share_basename'. Using full name for destination: '$original_share_name'." | tee -a "$LOG_FILE"
        fi

        local dest_share_path="${FINAL_DEST}/${original_share_name}/"
        echo "$(date) INFO: Syncing share '$original_share_name': from '$src_folder_path' to '$dest_share_path'" | tee -a "$LOG_FILE"

        # Ensure the specific destination directory for this share exists.
        if ! mkdir -p "$dest_share_path"; then
            echo "$(date) ERROR: Failed to create destination directory for share '$dest_share_path'. Skipping sync for this share." | tee -a "$LOG_FILE"
            rsync_failed=1
            continue # Skip to the next source folder.
        fi

        # Construct and execute the rsync command.
        # -a: archive mode (recursive, preserves symlinks, permissions, times, group, owner)
        # -v: verbose
        # -h: human-readable numbers
        # --delete: deletes extraneous files from destination dirs
        # --progress: shows progress during transfer
        # --no-whole-file: forces rsync to use its delta algorithm, crucial for network mounts.
        # Using eval for rsync_command to correctly interpret exclude arguments with spaces/quotes.
        local rsync_command
        rsync_command="rsync -avh --delete --progress --no-whole-file ${rsync_exclude_args_built} \"${src_folder_path}\" \"${dest_share_path}\""
        echo "$(date) DEBUG: Running rsync command: $rsync_command" | tee -a "$LOG_FILE"

        if ! eval "$rsync_command" 2>&1 | tee -a "$LOG_FILE"; then
            echo "$(date) ERROR: Rsync failed for share '$original_share_name' (from '$src_folder_path' to '$dest_share_path'). Check log for details." | tee -a "$LOG_FILE"
            rsync_failed=1 # Mark as failed for this share, but continue with other shares.
        fi
    done

    if [[ "$rsync_failed" -eq 0 ]]; then
        echo "$(date) INFO: All Rsync operations completed successfully." | tee -a "$LOG_FILE"
        return 0
    else
        echo "$(date) ERROR: One or more Rsync operations failed. Review logs for details." | tee -a "$LOG_FILE"
        return 1
    fi
}
