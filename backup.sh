#!/bin/bash
pushd .
cd "${0%/*}"
echo "Sleeping 30 seconds to allow system to settle down after boot..."
sleep 30 # give the system a bit of time to settle down after boot
# --- CRITICAL: Set Environment Variables for Cron ---
# These are essential because cron's environment is minimal.
# Ensure 'byron' is your actual username.
export HOME="/home/byron"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin"

#cancel any pending shutdowns
ssh vm_shutdown_user@hotbox "sudo shutdown -c"

# only run one copy
if [ "$(pgrep -fc "backup.sh")" -gt 1 ]; then
    echo "$(date) INFO: Another instance of the script is already running. Exiting." && ps -x |grep backup.sh && exit 0  
fi

# only run one rclone copy
if [ "$(pgrep -fc "rclone")" -gt 1 ]; then
    echo "$(date) INFO: multiple instances of rclone running. Exiting." && ps -x |grep rclone && exit 0  
fi

source .env
source notify.sh

# This script does not need to be modified when  disks are added or removed on the server or coldstorage!
# You do need to setup rclone and add disks to the local union
 
# fdisk -l # to list all disk
# lsblk # to list all disks and partitions
# lsblk -f # to list all disks and partitions with filesystem info

# mkfs.btrfs -L BARACUDA_22T_ZXA0D04T /dev/sdg1
# mkfs.btrfs -L BARACUDA_22T_ZXA064CP /dev/sdf1
# mkfs.btrfs -L MDD_BARACUDA_18T_000523Q3 /dev/sdc1

# 1. Change the label of a mounted Btrfs filesystem:
# sudo btrfs filesystem label <mountpoint> <newlabel>
# sudo btrfs filesystem label /dev/sdd1 HGST_12T_8DHV0V6H
# sudo btrfs filesystem label /dev/sde1 HGST_12T_8DJHBLZY
# sudo btrfs filesystem label /dev/sdc1 MDD_BARACUDA_18T_000523Q3
# sudo btrfs filesystem label /dev/sdf1 BARACUDA_22T_ZXA064CP

# 2. Create a new Btrfs subvolume:
# vi /etc/fstab to add new disks
# 
# rclone config # to setup rclone
#
# config snapper onthe new disk
# sudo snapper -c disk1 create-config /mnt/disk1
#sudo snapper -c disk1 create-config /mnt/disk3
#sudo snapper -c disk4 create-config /mnt/disk4
#sudo snapper -c disk3 create-config /mnt/disk3
# # some snapper commands;           from : https://wiki.archlinux.org/title/Snapper
#   vi /etc/snapper/configs/disk1
#   snapper list-configs
# READY TO GO! source disks will be disvovered automatically from unraid. (NAS or NAS-ssh)
#
# to add

# these two give the best performance really!
#SOURCE="NAS:" #this is NOT slower, uses SMB is fast af but for some reason time stamps are not working correctly
SHUTDOWN_AFTER_COPY="true" # set to "true" if you want to shutdown the hotbox after the copy is done

#DESTINATION="local:" # strange this is faster....
DESTINATION="/mnt/backup" #mergefs is somehow slower than rclone?
             
SYNC_VERB="sync"  # sync will delete files on the destination but with  --backup-dir  it keeps a backup of the deleted files
# SYNC_SOURCE="NAS-ssh:/mnt/user/" # careful with this one, easy to delete files
# doing a copy using differen tfile ssytems makie sextra data go over the wire.

SYNC_SOURCE="NAS-ssh:/mnt/user"
COPY_SOURCES=(
    #NAS-ssh:/mnt/user/
    # this is for performance, so we can copy from multiple disks/nvme at once
    # REMEMBER it exits when there is only 1 running to go to the copy becase this one has transfers=1
    NAS-ssh:/mnt/cache
    NAS-ssh:/mnt/spool
    NAS-ssh:/mnt/disk1
    NAS-ssh:/mnt/disk2 
    NAS-ssh:/mnt/disk3 
    NAS-ssh:/mnt/disk4 
    NAS-ssh:/mnt/disk5
    )

EXCLUDED_FILES=(
    'domains/**'
    'system/**'
    'appdata/**'
    'scratch/**'
    '.snapshots/**'
    'torrents/**'
    '@revisions/**'
    )
# Options for concurrent rclone copy operations
# --multi-thread-streams=0 gives better utilization of disk IO. We're IOPs limited.
COPY_OPTS="--multi-thread-streams=0 --buffer-size=1G --transfers=1 --metadata --verbose --human-readable --check-first --fast-list"
SYNC_OPTS="--multi-thread-streams=0 --buffer-size=2G --transfers=2 --metadata --verbose --human-readable --check-first --fast-list"

#--backup-dir=/mnt/backup/@revisions/$(date +%Y-%m-%d) --order-by=size,mixed "


# snapper handles snapshots
# timestamp="$(date +%Y%m%d_%H%M)" # Using snapshot_name like your original
# for disk_path in $(ls -d /mnt/disk*); do
#   sudo btrfs subvolume snapshot -r $disk_path $disk_path/@snapshots/$timestamp || {
#     echo "$(date) ERROR: Failed to create initial snapshot for $disk_path"
#     #  notify "Snapshot Failure" "Failed to create initial snapshot for $disk_path" 1
#     exit 1
#   }
# done
#
# #sudo rclone copy --progress --verbose --human-readable  --check-first --fast-list --exclude=MEDIA2/** --exclude=torrents/** --exclude=scratch/** nas-ssh:/mnt/disk1 /mnt/backup 
# rclone copy --progress --verbose --human-readable --check-first --fast-list --exclude scratch/** --exclude torrents/** --exclude .snapshots/** NAS-ssh:/mnt/disk1 local:
# rclone copy --progress --verbose --human-readable --check-first --fast-list --exclude scratch/** --exclude torrents/** --exclude .snapshots/** NAS-ssh:/mnt/disk2 local:
# rclone copy --progress --verbose --human-readable --check-first --fast-list --exclude scratch/** --exclude torrents/** --exclude .snapshots/** NAS-ssh:/mnt/disk3 local:
# rclone copy --progress --verbose --human-readable --check-first --fast-list --exclude scratch/** --exclude torrents/** --exclude .snapshots/** NAS-ssh:/mnt/disk4 local:
# rclone copy --progress --verbose --human-readable --check-first --fast-list --exclude scratch/** --exclude torrents/** --exclude .snapshots/** NAS-ssh:/mnt/disk5 local:



MAX_SNAPSHOTS=3 # Keep this many snapshots per subvolume
SCRIPT_SUCCESS=0 # 0 = no success yet, 1 = at least one rclone success

EXCLUDES=""
for pattern in "${EXCLUDED_FILES[@]}"; do
    EXCLUDES+=" --exclude ${pattern}"
done

# --- Pre-Check: Is Destination Mounted? ---
if ! mountpoint -q "$DESTINATION"; then
    echo "$(date) ERROR: $DESTINATION (mergerfs) is not mounted! Exiting." && notify "Backup Failure" "ERROR: $DESTINATION is not mounted! Exiting." 1 
    exit 1
fi
echo "$(date) INFO: $DESTINATION is mounted. Proceeding with rclone." 

# Arrays to track PIDs and their logs
declare -A pids_status # Stores PID as key, "running" or exit code as value
declare -A pids_log    # Stores PID as key, log file path as value

# Get the initial used space IN BYTES.
# `df --output=used -B1` is more reliable than `cut`. `tail -n 1` gets the value.
du_start_bytes=$(df --output=used -B1 /mnt/backup | tail -n 1)

# Function to notify completion with success or failure
notify_complete() {
    
    # Get the final used space in bytes.
    du_end_bytes=$(df --output=used -B1 /mnt/backup | tail -n 1)
    
    # Calculate the difference in bytes.
    bytes_copied=$((du_end_bytes - du_start_bytes))

    # Pass the byte count to `numfmt` and store the formatted result.
    gbytes_copied=$(echo "$bytes_copied" | numfmt --to=iec --suffix=B --format="%.2f")
   
    notify "Backup Success" "INFO: rclone $1 Success. ${gbytes_copied} delta." 0
    
    if [[ $SHUTDOWN_AFTER_COPY == "true" ]]; then
        echo "$(date) INFO: Shutdown after copy is enabled. Scheduling shutdown."
        ssh vm_shutdown_user@hotbox "sudo shutdown -h +10" # Shutdown the hotbox after 10 minutes
    fi
 
    return 0
}   

# --- Start concurrent rclone copy operations ---
echo "$(date) INFO: Starting concurrent rclone copy operations..."

# Create a named pipe for consolidated logging, renamed from CONSOLIDATED_LOG_PIPE to LOG_FILE
LOG_FILE="/tmp/rclone_consolidated.log" # This is the main log file for all output
rm ${LOG_FILE} # Clear previous log file if it exists
mkfifo "${LOG_FILE}"


# Start a background process to read from the consolidated log pipe and display output
cat "${LOG_FILE}" &
CAT_PID=$!


# Array to hold individual log files for tailing into the main LOG_FILE
individual_log_files=()

i=0 # Initialize disk counter
for rclone_source in "${COPY_SOURCES[@]}"; do
    junk=$((i++))
    DISK_LOG_FILE="/tmp/rclone_${i}_copy.log" # Temporary log file for each disk
    individual_log_files+=("${DISK_LOG_FILE}")

    # Clear previous log file
    > "${DISK_LOG_FILE}"

    echo "  Running copy for disk ${i} (logging to ${DISK_LOG_FILE})..."
    
    echo "   /usr/bin/rclone copy ${COPY_OPTS} ${EXCLUDES} ${rclone_source} $DESTINATION " > "${DISK_LOG_FILE}" 
    /usr/bin/rclone copy ${COPY_OPTS} ${EXCLUDES} \
        ${rclone_source} $DESTINATION > "${DISK_LOG_FILE}" &
    
    pid=$!
    pids_status[$pid]="running"
    pids_log[$pid]="${DISK_LOG_FILE}"
done

# Start a background process to tail all individual logs into the main LOG_FILE
tail -f "${individual_log_files[@]}" > "${LOG_FILE}" &
TAIL_PID=$!

# --- Monitor progress and wait for all PIDs ---
echo "---"
echo "$(date) INFO: Monitoring rclone copy processes (output interleaved below)..."
echo "---"

copy_fail=0 # Using your original variable name for failure count

# Loop until all processes have completed
while true; do
    # Break loop if no processes are being tracked
    if [[ ${#pids_status[@]} -le 0 ]]; then
        break
    fi

    # Wait for any child process to terminate, or return immediately if none are ready
    wait -n || true 
    
    # Iterate over currently tracked PIDs to find which one finished
    for pid_check in "${!pids_status[@]}"; do
        if [[ "${pids_status[$pid_check]}" == "running" ]]; then
            # Check if the process has terminated
            # `kill -0` checks if process exists and is runnable. If it fails, process is gone.
            if ! kill -0 "$pid_check" 2>/dev/null; then
                # Get exit status without blocking if already terminated
                wait "$pid_check"
                exit_status=$?
                
                if [ "$exit_status" -ne 0 ]; then
                    copy_fail=$((copy_fail + 1))
                    echo "$(date) ERROR: rclone copy process (PID: $pid_check, Disk: $(basename "${pids_log[$pid_check]}" .log)_copy) failed with exit code $exit_status."
                else
                    echo "$(date) INFO: rclone copy process (PID: $pid_check, Disk: $(basename "${pids_log[$pid_check]}" .log)_copy) completed successfully."
                fi
                # Remove from active PIDs
                unset pids_status[$pid_check]
            fi
        fi
    done
done
#hacky, yes, simple yes, works, yes
killall rclone
# --- Cleanup after concurrent copies ---
# Kill the background tail process for individual logs (cat process stays active for sync)
kill "$TAIL_PID" 2>/dev/null
# Individual logs are left for potential debugging, can be removed here if desired:
#rm "${individual_log_files[@]}"

echo "---"
if (( copy_fail > 0 )); then
    echo "$(date) FATAL: $copy_fail rclone copy operations failed. Check the individual log files in /tmp/ for details."
    notify "Backup Failure" "ERROR: rclone copy failed $copy_fail times. " 1
    # Ensure the main LOG_FILE is properly closed/killed if exiting here
    kill "$CAT_PID" 2>/dev/null
    # rm "${LOG_FILE}"
    exit 1
else
    echo "$(date) INFO: All rclone copy processes finished successfully."
fi
# --- Final Cleanup ---
# # Remove the consolidated named pipe
rm "${LOG_FILE}"

# Kill the background cat process for the main LOG_FILE
kill "$CAT_PID" 2>/dev/null

# need to setup a remote named NAS using rclone config first :)
# this should ensure random ordering more or less
# --order-by=size,mixed,25 # does a weird thing where transfers way more than needed, so removed it
sync_command="/usr/bin/rclone ${SYNC_VERB} ${SYNC_OPTS} ${EXCLUDES} ${SYNC_SOURCE} ${DESTINATION}"
echo $sync_command # Output the sync command to console for debugging
sleep 2
echo "$(date) INFO: Starting rclone sync operation..."  # Output to console and main log
# Direct sync command output to the same consolidated LOG_FILE
RESULT=$(eval "$sync_command")
sync_exit_code=$?
if $RESULT; then
    echo "$(date) INFO: rclone success for $SYNC_SOURCE -> $DESTINATION"   # Also log success to file
    

    # Execute the snapshot script.
    # We capture the exit code to determine if it succeeded.
    # The output is not captured in a variable, but you could redirect it to a log file.
    eval ./snapshot.sh $(printf -- '-p %s ' /mnt/disk*/) -r "$MAX_SNAPSHOTS"
    exit_code=$?

    # Check the exit code to see if the script was successful
    if [ $exit_code -ne 0 ]; then
        echo "$(date): ERROR: Btrfs snapshot script failed with exit code: $exit_code"
        notify "Btrfs Snapshot Failure" "ERROR: The script failed with exit code $exit_code. Check logs for details."
    else
        echo "$(date): INFO: Btrfs snapshot script completed successfully."
        notify_complete sync && exit 0
    fi
    
else
    echo "$(date) ERROR: rclone failed for  $SYNC_SOURCE -> $DESTINATION (Code: $sync_exit_code)"   # Log error to file
    notify "Backup Failure" "ERROR: rclone sync failed. (Code: $sync_exit_code)" 1
fi

# Remove the consolidated named pipe

popd
echo "$(date) INFO: Backup script finished."