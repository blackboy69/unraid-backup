#!/bin/bash

# A script to create daily Btrfs snapshots and rotate old ones.
# This version correctly handles retention for ALL snapshots in the
# destination directory, regardless of their naming convention, by
# reading the creation timestamp from Btrfs metadata.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Usage Function ---
usage() {
    echo "Usage: $0 -r <count> -p </path/to/filesystem1> [-p </path/to/filesystem2> ...]"
    echo "  -r <count>     (Required) Number of snapshots to retain."
    echo "  -p <path>      (Required) Path to a Btrfs mount point/subvolume to snapshot. Can be specified multiple times."
    exit 1
}

# --- Configuration & Argument Parsing ---
RETENTION_DAYS=""
TARGET_PATHS=()
TODAY=$(date +%F) # Format: YYYY-MM-DD

while getopts ":r:p:" opt; do
    case ${opt} in
        r) RETENTION_DAYS="$OPTARG";;
        p) TARGET_PATHS+=("$OPTARG");;
        \?) echo "Invalid Option: -$OPTARG" >&2; usage;;
        :) echo "Invalid Option: -$OPTARG requires an argument." >&2; usage;;
    esac
done
shift $((OPTIND -1))

# --- Validate Inputs ---
if [[ -z "$RETENTION_DAYS" ]] || [[ ${#TARGET_PATHS[@]} -eq 0 ]]; then
    echo "Error: Both a retention count (-r) and at least one path (-p) are required." >&2
    usage
fi
if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || [[ "$RETENTION_DAYS" -eq 0 ]]; then
    echo "Error: Retention count must be a positive integer." >&2
    usage
fi

# --- Main Logic ---
echo "--- Starting Btrfs Snapshot Script ---"
echo "Date: $TODAY"
echo "Retention Policy: Keep latest $RETENTION_DAYS snapshots."
echo "----------------------------------------"

for BTRFS_PATH in "${TARGET_PATHS[@]}"; do
    CLEAN_PATH="${BTRFS_PATH%/}"

    if ! sudo btrfs filesystem show "$CLEAN_PATH" &>/dev/null; then
        echo "ERROR: '$CLEAN_PATH' is not a Btrfs filesystem/subvolume. Skipping."
        continue
    fi
    
    SNAP_DIR="$CLEAN_PATH/.snapshots"
    mkdir -p "$SNAP_DIR"
    SNAP_PATH="$SNAP_DIR/$TODAY"

    echo "Processing: $CLEAN_PATH"

    # --- Create Snapshot ---
    if [ -d "$SNAP_PATH" ]; then
        echo "  -> Snapshot for $TODAY already exists."
    else
        echo "  -> Creating snapshot of '$CLEAN_PATH' at '$SNAP_PATH'"
        sudo btrfs subvolume snapshot -r "$CLEAN_PATH" "$SNAP_PATH"
    fi

    # --- Rotate Old Snapshots (Name-Independent Method) ---
    echo "  -> Checking retention policy for ALL snapshots in '$SNAP_DIR'..."
    
    # Create a temporary array to store "timestamp /path/to/snapshot" lines
    declare -a snapshots_with_time=()
    
    # Find all directories in .snapshots and check if they are btrfs subvolumes
    for item in "$SNAP_DIR"/*; do
        if [ -d "$item" ]; then
            # Use 'btrfs subvolume show' which is the authoritative source for creation time
            if creation_line=$(sudo btrfs subvolume show "$item" | grep 'Creation time:'); then
                # Extract the date string (e.g., 2025-07-28 22:10:30 -0700)
                creation_date_str=$(echo "$creation_line" | sed 's/Creation time:[ \t]*//')
                # Convert to a UNIX timestamp for reliable sorting
                creation_timestamp=$(date -d "$creation_date_str" +%s)
                snapshots_with_time+=("$creation_timestamp $item")
            fi
        fi
    done
    
    # Sort the array numerically by timestamp and extract just the path
    SORTED_SNAPSHOTS=($(printf '%s\n' "${snapshots_with_time[@]}" | sort -n | awk '{print $2}'))
    NUM_SNAPSHOTS=${#SORTED_SNAPSHOTS[@]}
    echo "  -> Found $NUM_SNAPSHOTS total snapshot(s) regardless of name."

    if [ "$NUM_SNAPSHOTS" -gt "$RETENTION_DAYS" ]; then
        NUM_TO_DELETE=$((NUM_SNAPSHOTS - RETENTION_DAYS))
        echo "  -> Exceeds retention of $RETENTION_DAYS. Deleting $NUM_TO_DELETE oldest snapshot(s)."

        for ((i=0; i<NUM_TO_DELETE; i++)); do
            echo "    -> Deleting ${SORTED_SNAPSHOTS[i]}"
            sudo btrfs subvolume delete "${SORTED_SNAPSHOTS[i]}"
        done
    else
        echo "  -> Retention policy met. No old snapshots to delete."
    fi
    echo "----------------------------------------"
done

echo "--- Snapshot script finished. ---"