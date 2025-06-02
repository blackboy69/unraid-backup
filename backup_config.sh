#!/bin/bash
# backup_config.sh
# Defines default global configuration variables for the backup system.
# These settings are intended to be sourced by the main backup.sh script.
# Values set in the .env file can override these defaults when loaded by backup.sh.

# --- Pushover API Details ---
# These tokens are required for sending notifications via Pushover.
# Replace with your actual tokens, or set them in the .env file.
PUSHOVER_APP_TOKEN="YOUR_PUSHOVER_APP_TOKEN"
PUSHOVER_USER_KEY="YOUR_PUSHOVER_USER_KEY"

# --- Rsync Exclusion Filters ---
# Patterns for files/folders to be excluded from rsync backups globally.
RSYNC_EXCLUDES=(
    "*.tmp"         # Temporary files
    "*.bak"         # Backup files
    "@eaDir"        # Synology thumbnail/metadata directory
    "#recycle"      # QNAP/Synology recycle bin directory
    ".Trash-*"      # Standard Linux/macOS trash folders
    ".DS_Store"     # macOS specific metadata files
    "Thumbs.db"     # Windows thumbnail cache files
    "*.part"        # Partially downloaded files
    ".syncignore"   # SyncThing ignore files
)

# --- Destination Details ---
# DEST_ROOT: The mount point of your mergerfs pool on the backup server.
DEST_ROOT="/mnt/merged_pool"
# DEST_SUBDIR: An optional subdirectory within DEST_ROOT where backups will be stored.
DEST_SUBDIR="nas_backups"
# FINAL_DEST: The full path to the backup destination directory.
FINAL_DEST="${DEST_ROOT}/${DEST_SUBDIR}"

# --- BTRFS Configuration ---
# BTRFS_MOUNT_POINTS: Space-separated list of mount points for individual BTRFS
# filesystems that form the backup storage. These are pooled by mergerfs.
# Snapshots will be taken on each of these filesystems.
# Example: "/mnt/btrfs_disk1 /mnt/btrfs_disk2 /mnt/btrfs_disk3"
BTRFS_MOUNT_POINTS="/btrfs_disk1 /btrfs_disk2 /btrfs_disk3"

# --- Snapshot Configuration ---
# SNAPSHOT_PREFIX: Prefix for btrfs snapshot names.
# The script expects snapshot names to follow the format: SNAPSHOT_PREFIX@YYYY-MM-DD_HHMM
SNAPSHOT_PREFIX="backup"

# Retention policy for snapshots on each btrfs filesystem:
# KEEP_DAILY: Number of daily snapshots to retain.
# KEEP_WEEKLY: Number of weekly snapshots to retain.
# KEEP_MONTHLY: Number of monthly snapshots to retain.
# KEEP_YEARLY: Number of yearly snapshots to retain.
# Set to 0 to disable retaining a specific tier of snapshots.
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=12
KEEP_YEARLY=0

# --- Script Logging ---
# LOG_FILE: Path to the main log file for the backup script.
LOG_FILE="/var/log/backup_pull.log"
