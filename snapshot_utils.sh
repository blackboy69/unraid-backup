#!/bin/bash
# snapshot_utils.sh
# Contains functions for creating and rotating btrfs snapshots.
# This script is intended to be sourced by the main backup.sh script.
# It relies on several environment variables being set by the caller:
#   LOG_FILE: Path to the log file.
#   BTRFS_MOUNT_POINTS: Space-separated string of btrfs mount points where snapshots are managed.
#   SNAPSHOT_PREFIX: Prefix for snapshot names (e.g., "backup").
#   KEEP_DAILY, KEEP_WEEKLY, KEEP_MONTHLY, KEEP_YEARLY: Retention policy counts.

# Creates read-only btrfs snapshots for each specified BTRFS mount point.
# Snapshot names are formatted as SNAPSHOT_PREFIX@YYYY-MM-DD_HHMM.
# Globals:
#   LOG_FILE, BTRFS_MOUNT_POINTS, SNAPSHOT_PREFIX
# Returns:
#   0 if all snapshots were created successfully.
#   1 if any snapshot creation failed or prerequisites were not met.
take_snapshots() {
    echo "$(date) INFO: Starting btrfs snapshot creation process..." | tee -a "$LOG_FILE"
    local snapshot_timestamp
    snapshot_timestamp=$(date +%Y-%m-%d_%H%M) # Format: YYYY-MM-DD_HHMM
    local snapshot_name="${SNAPSHOT_PREFIX}@${snapshot_timestamp}"
    local snapshot_failed=0 # Flag to track failures.

    if [[ -z "$BTRFS_MOUNT_POINTS" ]]; then
        echo "$(date) ERROR: BTRFS_MOUNT_POINTS variable is not set. Cannot take snapshots." | tee -a "$LOG_FILE"
        return 1
    fi

    for mount_point in $BTRFS_MOUNT_POINTS; do
        # Validate that the mount point exists and is a btrfs filesystem.
        if ! findmnt -t btrfs -S "$mount_point" > /dev/null; then
            echo "$(date) ERROR: '$mount_point' is not a btrfs mount point or does not exist. Skipping snapshot for it." | tee -a "$LOG_FILE"
            snapshot_failed=1
            continue
        fi

        local snapshot_dir="${mount_point}/.snapshots" # Standardized directory for snapshots.
        # Ensure the .snapshots directory exists.
        if [[ ! -d "$snapshot_dir" ]]; then
            echo "$(date) INFO: Snapshot directory '$snapshot_dir' does not exist. Creating it..." | tee -a "$LOG_FILE"
            if ! sudo mkdir -p "$snapshot_dir" 2>&1 | tee -a "$LOG_FILE"; then
                echo "$(date) ERROR: Failed to create snapshot directory '$snapshot_dir' for mount point '$mount_point'. Skipping snapshot for it." | tee -a "$LOG_FILE"
                snapshot_failed=1
                continue
            fi
        fi

        local snapshot_dest_path="${snapshot_dir}/${snapshot_name}"
        echo "$(date) INFO: Creating read-only snapshot of '$mount_point' at '$snapshot_dest_path'..." | tee -a "$LOG_FILE"

        # Create a read-only snapshot of the root of the btrfs filesystem at mount_point.
        # If specific subvolumes within mount_point need to be snapshotted, BTRFS_MOUNT_POINTS
        # should list paths to those subvolumes directly.
        if ! sudo btrfs subvolume snapshot -r "${mount_point}" "${snapshot_dest_path}" 2>&1 | tee -a "$LOG_FILE"; then
            echo "$(date) ERROR: Failed to create snapshot for mount point '$mount_point'. See log for details." | tee -a "$LOG_FILE"
            snapshot_failed=1
        fi
    done

    if [[ $snapshot_failed -eq 0 ]]; then
        echo "$(date) INFO: All btrfs snapshots completed successfully." | tee -a "$LOG_FILE"
        return 0
    else
        echo "$(date) ERROR: One or more btrfs snapshot operations failed. Review logs." | tee -a "$LOG_FILE"
        return 1
    fi
}

# Rotates btrfs snapshots based on a defined retention policy (daily, weekly, monthly, yearly).
# It parses snapshot names (expected format: SNAPSHOT_PREFIX@YYYY-MM-DD_HHMM) to determine their age.
# Globals:
#   LOG_FILE, BTRFS_MOUNT_POINTS, SNAPSHOT_PREFIX,
#   KEEP_DAILY, KEEP_WEEKLY, KEEP_MONTHLY, KEEP_YEARLY
# Returns:
#   0 if all rotations completed successfully (or no snapshots to rotate).
#   1 if any snapshot deletion failed or critical prerequisites were not met.
rotate_snapshots() {
    echo "$(date) INFO: Starting btrfs snapshot rotation process..." | tee -a "$LOG_FILE"
    local rotation_failed=0 # Flag to track failures.

    if [[ -z "$BTRFS_MOUNT_POINTS" ]]; then
        echo "$(date) ERROR: BTRFS_MOUNT_POINTS variable is not set. Cannot rotate snapshots." | tee -a "$LOG_FILE"
        return 1
    fi

    for mount_point in $BTRFS_MOUNT_POINTS; do
        echo "$(date) INFO: Rotating snapshots for btrfs mount point '$mount_point'..." | tee -a "$LOG_FILE"
        local snapshot_dir="${mount_point}/.snapshots"
        if [[ ! -d "$snapshot_dir" ]]; then
            echo "$(date) WARNING: Snapshot directory '$snapshot_dir' does not exist for '$mount_point'. Skipping rotation for this mount." | tee -a "$LOG_FILE"
            continue
        fi

        # Get a list of snapshot basenames, sorted newest first (reverse sort).
        local snapshots_list
        snapshots_list=$(find "$snapshot_dir" -maxdepth 1 -name "${SNAPSHOT_PREFIX}@*" -type d -print0 | xargs -0 -I {} basename {} | sort -r)
        if [[ -z "$snapshots_list" ]]; then
            echo "$(date) INFO: No snapshots found matching prefix '$SNAPSHOT_PREFIX' in '$snapshot_dir'. Nothing to rotate." | tee -a "$LOG_FILE"
            continue
        fi

        local keep_daily_count=0
        local keep_weekly_count=0
        local keep_monthly_count=0
        local keep_yearly_count=0

        # Pre-calculate age and epoch for all snapshots to avoid redundant computations.
        declare -A snapshot_info # Associative array to store snapshot metadata.
        local current_epoch
        current_epoch=$(date +%s)

        for snapshot_basename in $snapshots_list; do
            local snapshot_datetime_str
            snapshot_datetime_str=$(echo "$snapshot_basename" | sed -n "s/${SNAPSHOT_PREFIX}@\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{4\}\).*/\1/p")
            if [[ -z "$snapshot_datetime_str" ]]; then
                echo "$(date) WARNING: Could not parse date from snapshot name '$snapshot_basename' in '$snapshot_dir'. Skipping this snapshot for rotation." | tee -a "$LOG_FILE"
                continue
            fi

            # Convert YYYY-MM-DD_HHMM to a format `date -d` understands (YYYY-MM-DD HH:MM).
            local parsable_datetime_str="${snapshot_datetime_str%_*} ${snapshot_datetime_str#*_}"
            parsable_datetime_str="${parsable_datetime_str/_/:}" # Ensure time part uses colon.

            local creation_epoch
            creation_epoch=$(date -d "$parsable_datetime_str" +%s 2>/dev/null)
            if [[ -z "$creation_epoch" ]]; then
                echo "$(date) WARNING: Could not convert snapshot datetime '$parsable_datetime_str' to epoch for '$snapshot_basename'. Skipping this snapshot." | tee -a "$LOG_FILE"
                continue
            fi

            local age_seconds=$((current_epoch - creation_epoch))
            local age_days=$((age_seconds / (60*60*24)))

            snapshot_info["${snapshot_basename}_epoch"]=$creation_epoch
            snapshot_info["${snapshot_basename}_age_days"]=$age_days
        done

        # --- Retention Logic ---
        # Mark snapshots for deletion. Start by assuming all might be deleted, then unmark those to keep.
        declare -A snapshots_to_delete

        # 1. Daily Retention: Keep the N newest daily snapshots.
        # Iterate newest first (current $snapshots_list order).
        for snapshot_basename in $snapshots_list; do
            local age_days=${snapshot_info["${snapshot_basename}_age_days"]}
            if [[ -z "$age_days" ]]; then continue; fi # Skip if info wasn't populated.

            if [[ "$age_days" -lt 7 && "$keep_daily_count" -lt "$KEEP_DAILY" ]]; then
                echo "$(date) INFO: Keeping daily snapshot (Daily rule): $snapshot_basename (Age: $age_days days) in $snapshot_dir" | tee -a "$LOG_FILE"
                keep_daily_count=$((keep_daily_count + 1))
                # This snapshot is kept, so it's not marked for deletion.
            else
                snapshots_to_delete["$snapshot_basename"]=1 # Mark for potential deletion.
            fi
        done

        # 2. Weekly, Monthly, Yearly Retention: For these, we prefer the OLDEST snapshot in a given period.
        # Iterate oldest first for these checks.
        local sorted_snapshots_for_periodic_retention
        sorted_snapshots_for_periodic_retention=$(echo "$snapshots_list" | tac) # tac reverses the list (oldest first).

        declare -A kept_periodic_slots # Tracks if a slot (e.g., week_number) has been filled.

        for snapshot_basename in $sorted_snapshots_for_periodic_retention; do
            # Only consider snapshots currently marked for deletion. If it's already kept (e.g., by daily rule), skip.
            if [[ ! -v snapshots_to_delete["$snapshot_basename"] ]]; then
                continue
            fi

            local creation_epoch=${snapshot_info["${snapshot_basename}_epoch"]}
            local age_days=${snapshot_info["${snapshot_basename}_age_days"]}
            if [[ -z "$age_days" || -z "$creation_epoch" ]]; then continue; fi

            # Yearly Retention
            if [[ "$KEEP_YEARLY" -gt 0 && "$age_days" -ge 365 ]]; then
                local year_of_snapshot # YYYY
                year_of_snapshot=$(date -d "@$creation_epoch" "+%Y")
                if [[ -z "${kept_periodic_slots["year_$year_of_snapshot"]}" && "$keep_yearly_count" -lt "$KEEP_YEARLY" ]]; then
                    echo "$(date) INFO: Keeping yearly snapshot (Yearly rule): $snapshot_basename (Year: $year_of_snapshot) in $snapshot_dir" | tee -a "$LOG_FILE"
                    unset snapshots_to_delete["$snapshot_basename"] # Keep this snapshot.
                    kept_periodic_slots["year_$year_of_snapshot"]=1
                    keep_yearly_count=$((keep_yearly_count + 1))
                    continue # Kept as yearly, no need to check other periodic rules for this one.
                fi
            fi

            # Monthly Retention
            if [[ "$KEEP_MONTHLY" -gt 0 && "$age_days" -ge 30 ]]; then
                local month_of_snapshot # YYYY-MM
                month_of_snapshot=$(date -d "@$creation_epoch" "+%Y-%m")
                if [[ -z "${kept_periodic_slots["month_$month_of_snapshot"]}" && "$keep_monthly_count" -lt "$KEEP_MONTHLY" ]]; then
                    echo "$(date) INFO: Keeping monthly snapshot (Monthly rule): $snapshot_basename (Month: $month_of_snapshot) in $snapshot_dir" | tee -a "$LOG_FILE"
                    unset snapshots_to_delete["$snapshot_basename"] # Keep this snapshot.
                    kept_periodic_slots["month_$month_of_snapshot"]=1
                    keep_monthly_count=$((keep_monthly_count + 1))
                    continue # Kept as monthly.
                fi
            fi

            # Weekly Retention
            if [[ "$KEEP_WEEKLY" -gt 0 && "$age_days" -ge 7 ]]; then
                local week_of_snapshot # YYYY-WW (ISO week)
                week_of_snapshot=$(date -d "@$creation_epoch" "+%G-%V")
                 if [[ -z "${kept_periodic_slots["week_$week_of_snapshot"]}" && "$keep_weekly_count" -lt "$KEEP_WEEKLY" ]]; then
                    echo "$(date) INFO: Keeping weekly snapshot (Weekly rule): $snapshot_basename (Week: $week_of_snapshot) in $snapshot_dir" | tee -a "$LOG_FILE"
                    unset snapshots_to_delete["$snapshot_basename"] # Keep this snapshot.
                    kept_periodic_slots["week_$week_of_snapshot"]=1
                    keep_weekly_count=$((keep_weekly_count + 1))
                    # No continue needed here as it's the last periodic check.
                fi
            fi
        done

        # 3. Delete snapshots that are still marked in snapshots_to_delete array.
        for snapshot_basename in "${!snapshots_to_delete[@]}"; do
            local full_snapshot_path="${snapshot_dir}/${snapshot_basename}"
            local age_days_for_log=${snapshot_info["${snapshot_basename}_age_days"]:-"N/A"} # For logging.
            echo "$(date) INFO: Deleting old snapshot: $full_snapshot_path (Age: ${age_days_for_log} days) from $mount_point" | tee -a "$LOG_FILE"
            if ! sudo btrfs subvolume delete "$full_snapshot_path" 2>&1 | tee -a "$LOG_FILE"; then
                echo "$(date) ERROR: Failed to delete snapshot '$full_snapshot_path' for mount point '$mount_point'. Check log." | tee -a "$LOG_FILE"
                rotation_failed=1
            fi
        done
    done

    if [[ "$rotation_failed" -eq 0 ]]; then
        echo "$(date) INFO: btrfs snapshot rotation completed successfully." | tee -a "$LOG_FILE"
        return 0
    else
        echo "$(date) ERROR: One or more btrfs snapshot rotation operations failed. Review logs." | tee -a "$LOG_FILE"
        return 1
    fi
}
