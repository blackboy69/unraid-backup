#!/bin/bash
#
# mount_up.sh
#
# This script is designed to "mount up" your SMB shares for unattended operations.
# It's like a digital cowboy, clearing out old camp (unmounting stale shares)
# before leading the new herd (mounting current shares) to their watering holes.
# All sensitive configuration is wrangled from an external .env file,
# keeping passwords off the open range.
#

# --- Configuration ---
# Path to the .env file containing all environment variables.
# This file should be in the same directory as the script.
ENV_FILE="./.env"

# IMPORTANT: The following variables will be loaded from the .env file.
# They are commented out here as placeholders.
# MOUNT_BASE_DIR=""
# DEFAULT_MOUNT_OPTIONS=""
# SERVER_IP=""
# SMB_USERNAME=""
# SMB_CREDENTIALS_PATH="" # New variable for the credentials file
# --- End Configuration ---

# Function to log messages with timestamp
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to load environment variables from .env file
load_env() {
    log_message "Loading environment variables from ${ENV_FILE}..."
    if [[ ! -f "${ENV_FILE}" ]]; then
        log_message "Error: .env file '${ENV_FILE}' not found."
        log_message "Please create it with the necessary variables (refer to the example .env)."
        exit 1
    fi

    # Check .env file permissions (should be 600 for sensitive info, though credentials are now external)
    local env_permissions
    env_permissions=$(stat -c "%a" "${ENV_FILE}")
    if [[ "$env_permissions" != "600" ]]; then
        log_message "Warning: .env file '${ENV_FILE}' has insecure permissions (${env_permissions})."
        log_message "It should be 600 (rw-------). Please fix with: chmod 600 ${ENV_FILE}"
        # For unattended critical operations, it's safer to exit on insecure permissions
        exit 1
    fi

    # Source the .env file to load variables into the current script's environment
    set -a # Automatically export all variables after this point
    # shellcheck source=./.env
    source "${ENV_FILE}"
    set +a # Stop automatically exporting variables

    # Verify essential variables are loaded
    if [[ -z "${MOUNT_BASE_DIR}" || -z "${DEFAULT_MOUNT_OPTIONS}" || -z "${SERVER_IP}" || -z "${SMB_USERNAME}" || -z "${SMB_CREDENTIALS_PATH}" ]]; then
        log_message "Error: Missing one or more required variables in ${ENV_FILE}:"
        log_message "  MOUNT_BASE_DIR, DEFAULT_MOUNT_OPTIONS, SERVER_IP, SMB_USERNAME, SMB_CREDENTIALS_PATH."
        log_message "Please check your .env file."
        exit 1
    fi

    # Verify credentials file existence and permissions
    if [[ ! -f "${SMB_CREDENTIALS_PATH}" ]]; then
        log_message "Error: SMB Credentials file '${SMB_CREDENTIALS_PATH}' not found."
        log_message "Please create it with 'username=...' and 'password=...' and ensure it has 600 permissions."
        exit 1
    fi
    local cred_permissions
    cred_permissions=$(stat -c "%a" "${SMB_CREDENTIALS_PATH}")
    if [[ "$cred_permissions" != "600" ]]; then
        log_message "Error: SMB Credentials file '${SMB_CREDENTIALS_PATH}' has insecure permissions (${cred_permissions})."
        log_message "It MUST be 600 (rw-------). Please fix with: sudo chmod 600 ${SMB_CREDENTIALS_PATH}"
        exit 1
    fi
    log_message "Environment variables and credentials file loaded."
}

# Function to discover SMB shares
discover_smb_shares() {
    local server_ip="$1"
    log_message "Discovering SMB shares on ${server_ip}..."

    # smbclient might still need a username even if password is not passed directly
    # -U %username: tells smbclient to use the username from its configuration/env if available.
    # We use the SMB_USERNAME from .env for this.
    # If anonymous, can pass -N (no password) to smbclient, but with a username, it will likely prompt
    # unless password is in a configured smb.conf or credentials file it knows about.
    # For robust unattended discovery, sticking to -N (no password prompt) for discovery.
    smbclient -L "${server_ip}" -N 2>/dev/null | \
    awk '/^\s*Disk\s*$/ { p = 1; next } p && /^\s*Sharename\s*Type\s*Comment/ { next } p && /^\s*--------/ { next } p && /^\s*IPC\$/ { p = 0; next } p && /^\s*ADMIN\$/ { p = 0; next } p && /^\s*NetBIOS/ { p = 0; next } p && /^\s*Workgroup/ { p = 0; next } p && /^\s*$/ { p = 0; next } p && /^\s*([a-zA-Z0-9_-]+)\s+Disk\s+/ { print $1 }'
}

# Function to mount an SMB share
mount_smb_share() {
    local server_ip="$1"
    local share_name="$2"
    local mount_point="$3"
    # Note: Username from .env (SMB_USERNAME) is still used for clarity,
    # but password is now entirely from the credentials file.

    log_message "Attempting to mount //${server_ip}/${share_name} to ${mount_point} using credentials from ${SMB_CREDENTIALS_PATH}..."

    # Create mount point if it doesn't exist
    if [ ! -d "${mount_point}" ]; then
        log_message "Creating mount point directory: ${mount_point}"
        if ! sudo mkdir -p "${mount_point}"; then
            log_message "Error: Could not create mount point ${mount_point}."
            return 1
        fi
    fi

    local mount_options="${DEFAULT_MOUNT_OPTIONS}"
    # Use credentials file directly
    mount_options+=",credentials=${SMB_CREDENTIALS_PATH}"

    # Attempt to mount the share
    if sudo mount -t cifs -o "${mount_options}" "//${server_ip}/${share_name}" "${mount_point}"; then
        log_message "Successfully mounted //${server_ip}/${share_name} to ${mount_point}"
        return 0
    else
        log_message "Error: Failed to mount //${server_ip}/${share_name} to ${mount_point}. Check server connectivity, share name, or credentials file content/permissions."
        return 1
    fi
}

# Function to unmount an SMB share
unmount_smb_share() {
    local mount_point="$1"
    if mountpoint -q "${mount_point}"; then # Check if it's actually mounted
        log_message "Attempting to unmount ${mount_point}..."
        if sudo umount "${mount_point}"; then
            log_message "Successfully unmounted ${mount_point}"
            # Attempt to remove the directory if it's empty and within our base dir
            if [[ "${mount_point}" == "${MOUNT_BASE_DIR}/"* ]]; then
                if rmdir "${mount_point}" 2>/dev/null; then
                    log_message "Removed empty mount point directory: ${mount_point}"
                fi
            fi
            return 0
        else
            log_message "Error: Failed to unmount ${mount_point}."
            return 1
        fi
    else
        log_message "Mount point ${mount_point} is not mounted, skipping unmount."
        return 0 # Not mounted, so considered successful in terms of target state
    fi
}

# Function to unmount all shares previously managed by this script
unmount_all_existing_smb_shares() {
    log_message "Clearing out all existing SMB mounts under ${MOUNT_BASE_DIR}..."

    # Find all CIFS mounts under MOUNT_BASE_DIR
    local existing_mounts
    existing_mounts=$(findmnt -l -t cifs -n -o TARGET -r | grep "^${MOUNT_BASE_DIR}/")

    if [[ -z "${existing_mounts}" ]]; then
        log_message "No existing SMB mounts found under ${MOUNT_BASE_DIR} to unmount."
        return 0
    fi

    log_message "Found existing mounts: $(echo "${existing_mounts}" | tr '\n' ' ')"
    for mount_point in ${existing_mounts}; do
        unmount_smb_share "${mount_point}"
    done
    log_message "Finished clearing existing mounts."
}

# Check for necessary commands
check_prerequisites() {
    local missing_commands=()
    command -v smbclient >/dev/null || missing_commands+=("smbclient (samba-client)")
    command -v mount.cifs >/dev/null || missing_commands+=("mount.cifs (cifs-utils)") # mount.cifs is provided by cifs-utils
    command -v findmnt >/dev/null || missing_commands+=("findmnt (util-linux)") # for robust mount point detection

    if [ ${#missing_commands[@]} -gt 0 ]; then
        log_message "Error: The following commands are missing. Please install the corresponding packages."
        log_message "Missing: ${missing_commands[*]}"
        log_message "On Debian/Ubuntu, you might need to run:"
        log_message "  sudo apt-get update"
        log_message "  sudo apt-get install samba-client cifs-utils util-linux"
        exit 1
    fi
}

# Main script logic
main() {
    log_message "Starting SMB Mount Manager script."

    # Check for --unmount-only flag first
    if [[ "$1" == "--unmount-only" ]]; then
        log_message "Running in --unmount-only mode."
        # Load environment variables necessary for unmounting
        # Determine script directory to find .env relative to script
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
        ENV_FILE="${script_dir}/.env" # Assume .env is in the same directory as the script

        if [[ ! -f "${ENV_FILE}" ]]; then # Fallback if script_dir logic fails (e.g. direct execution)
             ENV_FILE="./.env"
        fi

        # A simplified load_env for unmounting, only MOUNT_BASE_DIR is strictly needed
        if [[ -f "${ENV_FILE}" ]]; then
            set -a
            # shellcheck source=./.env
            source "${ENV_FILE}"
            set +a
            if [[ -z "${MOUNT_BASE_DIR}" ]]; then
                log_message "Error: MOUNT_BASE_DIR not found in ${ENV_FILE}. Cannot unmount."
                exit 1
            fi
            log_message "Environment loaded for unmount. MOUNT_BASE_DIR: ${MOUNT_BASE_DIR}"
        else
            log_message "Error: .env file '${ENV_FILE}' not found. Cannot determine MOUNT_BASE_DIR for unmounting."
            exit 1
        fi

        unmount_all_existing_smb_shares
        log_message "Unmount-only mode finished."
        exit 0
    fi

    check_prerequisites
    load_env # Load all variables from .env file (this also checks for .env existence and permissions)

    # Ensure the base mount directory exists
    if [ ! -d "${MOUNT_BASE_DIR}" ]; then
        log_message "Base mount directory ${MOUNT_BASE_DIR} does not exist, creating it."
        if ! sudo mkdir -p "${MOUNT_BASE_DIR}"; then
            log_message "Error: Could not create base mount directory ${MOUNT_BASE_DIR}. Exiting."
            exit 1
        fi
    fi

    # Phase 1: Unmount all existing shares that were managed by this script
    # This is always done to ensure a clean state before attempting new mounts.
    unmount_all_existing_smb_shares

    # Phase 2: Discover and mount current shares
    local discovered_shares_output
    discovered_shares_output=$(discover_smb_shares "${SERVER_IP}")
    mapfile -t discovered_shares < <(echo "${discovered_shares_output}")
    local current_run_mounted_paths=() # Keep track of what we successfully mount in THIS run

    if [ ${#discovered_shares[@]} -eq 0 ]; then
        log_message "No SMB shares found on ${SERVER_IP} or an error occurred during discovery."
        log_message "No shares will be mounted in this run."
        # This is not an error state, could be normal if no shares are available.
        # unmount_all_existing_smb_shares already ran.
        log_message "SMB mount management run complete. No shares to mount."
        exit 0
    fi

    log_message "Discovered shares: ${discovered_shares[*]}"

    log_message "Attempting to mount current discovered shares..."
    for share in "${discovered_shares[@]}"; do
        if [[ -z "$share" ]]; then continue; fi # Skip empty lines if any from mapfile
        # Sanitize share name for directory creation (replace non-alphanumeric with underscore)
        local sanitized_share_name
        sanitized_share_name=${share//[^a-zA-Z0-9_-]/_}
        local mount_point="${MOUNT_BASE_DIR}/${SERVER_IP//./_}_${sanitized_share_name}"

        if mount_smb_share "${SERVER_IP}" "${share}" "${mount_point}" "${SMB_USERNAME}"; then
            current_run_mounted_paths+=("${mount_point}")
        fi
    done

    log_message "SMB mount management run complete."
    if [ ${#current_run_mounted_paths[@]} -gt 0 ]; then
        log_message "Successfully mounted shares in this run:"
        for mp in "${current_run_mounted_paths[@]}"; do
            log_message "- ${mp}"
        done
        log_message "These shares will remain mounted until manually unmounted or this script runs again (or unmount-only is called)."
    else
        log_message "No new shares were successfully mounted in this run (despite shares being discovered)."
    fi

    log_message "Script finished."
}

# Call the main function
main "$@"
