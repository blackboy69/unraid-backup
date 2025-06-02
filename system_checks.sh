#!/bin/bash
# system_checks.sh
# Contains functions for checking system health, including btrfs filesystem status and SMART disk health.
# This script is intended to be sourced by the main backup.sh script.
# It relies on LOG_FILE, BTRFS_MOUNT_POINTS, PUSHOVER_APP_TOKEN, PUSHOVER_USER_KEY,
# and HOSTNAME_VAR being set and available in the environment.
# The pushover_notify function (from logging_utils.sh) must also be available.

# Checks system logs, btrfs filesystem integrity, and SMART status of disks.
# Sends a Pushover alert if critical errors are found.
# Globals:
#   LOG_FILE: Path to the log file.
#   BTRFS_MOUNT_POINTS: Space-separated string of btrfs mount points to check.
#   HOSTNAME_VAR: Hostname of the machine, used in notification messages.
#   PUSHOVER_APP_TOKEN, PUSHOVER_USER_KEY: For sending notifications.
#   pushover_notify: Function to send notifications.
# Returns:
#   0 if no critical errors are found.
#   1 if errors are detected (and a notification is sent).
check_logs() {
    echo "$(date) INFO: Checking system and btrfs logs for errors on $HOSTNAME_VAR..." | tee -a "$LOG_FILE"
    local error_found=0
    local message="" # Accumulates error messages for notification.

    local check_period="24 hours ago" # Defines how far back journalctl should check logs.

    # Check dmesg (kernel ring buffer) for recent critical errors via journalctl.
    # Excludes some common non-critical error messages.
    local dmesg_errors
    dmesg_errors=$(journalctl -k --since "$check_period" | grep -E "error|fail|critical" | grep -Ev "error_report|failed to stat|failed to map" | head -n 5)
    if [[ -n "$dmesg_errors" ]]; then
        message+="Critical kernel errors found in dmesg on $HOSTNAME_VAR. Review journalctl. "
        error_found=1
    fi

    # Check btrfs filesystem status for errors.
    local btrfs_errors_detected=0
    if [[ -z "$BTRFS_MOUNT_POINTS" ]]; then
        echo "$(date) WARNING: BTRFS_MOUNT_POINTS variable is not set. Skipping btrfs filesystem checks." | tee -a "$LOG_FILE"
    else
        for mount_point in $BTRFS_MOUNT_POINTS; do
            if ! findmnt -t btrfs -S "$mount_point" > /dev/null; then
                echo "$(date) WARNING: '$mount_point' on $HOSTNAME_VAR is not a btrfs mount point or does not exist. Skipping btrfs check for it." | tee -a "$LOG_FILE"
                continue
            fi
            echo "$(date) INFO: Checking btrfs filesystem at '$mount_point' on $HOSTNAME_VAR..." | tee -a "$LOG_FILE"

            local btrfs_dev_stats
            btrfs_dev_stats=$(sudo btrfs device stats "$mount_point" 2>&1)
            # Check for non-zero error counts in device stats.
            if echo "$btrfs_dev_stats" | grep -E "\[[1-9][0-9]*\s+(read|write|flush|corruption|generation)\s+errs\]"; then
                message+="Btrfs device errors detected on '$mount_point' on $HOSTNAME_VAR. Details: $(echo "$btrfs_dev_stats" | grep -E "errs\]"). "
                btrfs_errors_detected=1
            elif echo "$btrfs_dev_stats" | grep -q "ERROR:"; then # Check for generic errors from the command itself.
                 message+="Error running 'btrfs device stats $mount_point' on $HOSTNAME_VAR. Output: ${btrfs_dev_stats}. "
                 btrfs_errors_detected=1
            fi
            # Consider adding 'sudo btrfs scrub status $mount_point' if scrubs are run regularly.
        done
    fi
    if [[ $btrfs_errors_detected -eq 1 ]]; then
        error_found=1
    fi

    # Check SMART status of all physical disks underlying the btrfs filesystems.
    local smart_errors_detected=0
    if [[ -z "$BTRFS_MOUNT_POINTS" ]]; then
        : # BTRFS_MOUNT_POINTS warning already issued.
    else
        for mount_point in $BTRFS_MOUNT_POINTS; do
            if ! findmnt -t btrfs -S "$mount_point" > /dev/null; then
                continue # Warning already issued.
            fi

            # Get list of underlying block devices for the btrfs filesystem.
            local btrfs_devices
            btrfs_devices=$(sudo btrfs filesystem show "$mount_point" | grep -oP 'path\s+\K/dev/\S+' | sort -u)

            if [[ -z "$btrfs_devices" ]]; then
                echo "$(date) WARNING: Could not determine devices for btrfs mount '$mount_point' on $HOSTNAME_VAR. Skipping SMART check for it." | tee -a "$LOG_FILE"
                continue
            fi

            for disk_path in $btrfs_devices; do
                if [[ ! -b "$disk_path" ]]; then # Check if it's a block device
                    echo "$(date) WARNING: Path $disk_path (from btrfs fs at $mount_point on $HOSTNAME_VAR) is not a block device. Skipping SMART check." | tee -a "$LOG_FILE"
                    continue
                fi

                echo "$(date) INFO: Checking SMART health for $disk_path (part of $mount_point on $HOSTNAME_VAR)..." | tee -a "$LOG_FILE"
                local smart_health
                smart_health=$(sudo smartctl -H "$disk_path" 2>&1) # Capture stderr as well.
                if echo "$smart_health" | grep -q "SMART overall-health self-assessment test result: FAILED"; then
                    message+="SMART health FAILED on $disk_path (part of $mount_point on $HOSTNAME_VAR)! "
                    smart_errors_detected=1
                elif echo "$smart_health" | grep -Eq "Unavailable|SMART command failed|Unknown USB bridge"; then
                     message+="SMART check failed or unavailable for $disk_path (part of $mount_point on $HOSTNAME_VAR). Review manually. "
                     smart_errors_detected=1 # Treat as an error needing investigation.
                fi
            done
        done
    fi
    if [[ $smart_errors_detected -eq 1 ]]; then
        error_found=1
    fi

    # If any errors were found, send a high-priority Pushover notification.
    if [[ $error_found -eq 1 ]]; then
        echo "$(date) ERROR: System health checks found issues on $HOSTNAME_VAR. Notifying Pushover." | tee -a "$LOG_FILE"
        pushover_notify "$HOSTNAME_VAR Backup Status: SYSTEM ALERT!" "$message" 1 # High priority
        return 1
    else
        echo "$(date) INFO: System health checks completed on $HOSTNAME_VAR. No critical errors found." | tee -a "$LOG_FILE"
        return 0
    fi
}
