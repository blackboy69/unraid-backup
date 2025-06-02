# unraid-backup
Automated pull-based backup solution for your NAS SMB shares to a Debian Virtual Machine (VM) with ZFS and `mergerfs`, featuring robust snapshotting and Pushover notifications.

---

## Table of Contents

1.  [Overview](#1-overview)
2.  [Features](#2-features)
3.  [Architecture](#3-architecture)
4.  [Prerequisites](#4-prerequisites)
5.  [Installation & Setup](#5-installation--setup)
6.  [Configuration](#6-configuration)
7.  [Usage](#7-usage)
8.  [Logging & Notifications](#8-logging--notifications)
9.  [Recovery Guide](#9-recovery-guide)
10. [License](#10-license)

---

## 1. Overview

This project provides a robust, pull-based backup solution designed for home labs or small server environments. It leverages a dedicated **Debian Virtual Machine** (your backup server) to pull data from your **Network Attached Storage (NAS)** via mounted SMB shares. Data is stored on individual ZFS filesystems (one per disk) on the backup server, which are then unified into a single, large logical share using `mergerfs`. ZFS snapshots provide efficient versioning and data integrity detection, with automated rotation policies.

This setup prioritizes:
* **Data Integrity:** ZFS checksumming on the cold storage.
* **Capacity Utilization:** Maximizing usable space with individual disks.
* **Energy Efficiency:** Potential for the backup server to power down when not in use (if managed externally).
* **Clear Recovery Path:** Predictable recovery from single drive failures.

---

## 2. Features

* **Pull Model:** The backup server initiates the data pull from your NAS for enhanced security against ransomware.
* **SMB Share Backup:** Connects to and backs up specified SMB shares from your NAS (mounted via `mount_up.sh`).
* **`rsync` Efficiency:** Utilizes `rsync`'s efficient delta-transfer (`--no-whole-file`) for faster updates of large files.
* **ZFS Data Integrity:** Employs ZFS's native end-to-end checksumming to detect silent data corruption (bit rot) on individual cold storage drives.
* **ZFS Snapshots:** Creates immutable, point-in-time snapshots of your backup data for versioning and easy historical access.
* **Automated Snapshot Rotation:** Intelligently prunes old snapshots based on daily, weekly, monthly, and yearly retention policies.
* **Disk Health Monitoring:** Integrates SMART checks for physical drive health and ZFS pool status monitoring.
* **Pushover Notifications:** Provides silent (low-priority) notifications for successful backups and high-priority alerts for failures or warnings.
* **Detailed Logging:** Comprehensive logs of all backup operations for auditing and troubleshooting.

---

## 3. Architecture

* **Primary Server (e.g., your main PVE host):** Your main server running applications and hosting primary data.
* **Network Attached Storage (NAS):** Your primary data storage and source for backups.
* **Backup Server (Debian VM on dedicated hardware/VM host):**
    * Hosts a **Debian VM** (where `backup.sh` and `mount_up.sh` run).
    * Dedicated physical disks are **passed through** to this Debian VM.
    * Inside the Debian VM:
        * Each passed-through disk is configured as its **own independent ZFS pool**.
        * `mergerfs` pools these individual ZFS mount points into a **single, unified mount point**.
        * `mount_up.sh` script discovers and mounts SMB shares from your NAS.
        * `backup.sh` script then pulls data from these mounted shares to the `mergerfs` pool.
```
+----------------+       +----------------+       +-------------------------------------+
| Primary Server |       |      NAS       |       |              Backup Server          |
| (Main Host)    |       | (Unraid Server)|       |       (Debian VM on Host)           |
|                |       |                |       |                                     |
|  VMs           |------>|  SMB Shares    |------>|  Debian VM (Scripts Run Here)       |
| (Applications) |       | (Primary Data) |       |  +--------------------------------+ |
+----------------+       +----------------+       |  | `mount_up.sh` mounts shares to:| |
                                                  |  |  /mnt/smb_shares/ (example)    | |
                                                  |  |  + SERVER_IP_share1             | |
                                                  |  |  + SERVER_IP_share2             | |
                                                  |  +--------------------------------+ |
                                                  |                                     |
                                                  |  Passed-Through Disks:              |
                                                  |  /dev/sdb, /dev/sdc, /dev/sdd, ...  |
                                                  |  +--------------------------------+ |
                                                  |  |  ZFS pool_disk1 on /dev/sdb    | |
                                                  |  |  ZFS pool_disk2 on /dev/sdc    | |
                                                  |  |  ...                           | |
                                                  |  +--------------------------------+ |
                                                  |                                     |
                                                  |  mergerfs pools ZFS mounts to:      |
                                                  |  /mnt/merged_pool                   |
                                                  |                                     |
                                                  |  `backup.sh` rsyncs data from      |
                                                  |  mounted shares to /mnt/merged_pool |
                                                  |  ZFS Snapshots on individual pools  |
                                                  +-------------------------------------+


```

## 4. Prerequisites

### Backup Server (Debian VM)

* **Operating System:** Debian 11 (Bullseye) or newer. A minimal installation is recommended.
* **Disk Setup:** Ensure your physical disks are passed through correctly to the Debian VM from its host.
* **Networking:** Assign a static IP address to your Debian VM.
* **User Privileges:** The user running this script needs `sudo` privileges for `zfs`, `smartctl`, and `journalctl` commands without password prompts.

### NAS (Unraid Server)

* **SMB Service:** The SMB service must be enabled and running.
* **SMB User:** A dedicated user account (e.g., `smb_backup_user`) on Unraid with **read-only access** to the shares you intend to back up.
* **Shares Exported:** The specific shares you want to back up must be exported via SMB and accessible from your Backup Server VM.
* **Networking:** Assign a static IP address to your NAS.

### General

* **Pushover Account:** A Pushover user account and an application API token for notifications.

---

## 5. Installation & Setup

Follow these steps carefully on your **Backup Server (Debian VM)** to install and configure the backup system.

1.  **Update Your System:**
    ```bash
    sudo apt update
    sudo apt upgrade -y
    ```

2.  **Install Necessary Packages:**
    * `backup.sh` and `mount_up.sh` require several utilities.
    * `cifs-utils`: For mounting SMB shares.
    * `samba-client`: For `smbclient` (used by `mount_up.sh` to discover shares).
    * `util-linux`: For `findmnt` (used by `mount_up.sh`).
    * `rsync`: For transferring files.
    * `zfsutils-linux`: For ZFS support.
    * `smartmontools`: For disk health monitoring.
    * `jq`: For parsing JSON (used by helper functions, if any).
    * `curl`: For Pushover notifications.
    * `mergerfs`: For pooling ZFS disks.
    ```bash
    sudo apt install -y rsync cifs-utils samba-client util-linux zfsutils-linux smartmontools jq curl mergerfs
    ```

3.  **Configure Sudoers:**
    * The user running `backup.sh` needs `sudo` privileges for ZFS, SMART, journalctl, and crucially, for `/usr/local/bin/mount_up.sh` (which itself calls `mount`, `umount`, `mkdir`, `rmdir` with `sudo`).
    * Edit the `sudoers` file:
        ```bash
        sudo visudo
        ```
    * Add the following line, replacing `your_username` with the actual username that will run `backup.sh`:
        ```
        your_username ALL=(ALL) NOPASSWD: /usr/sbin/zpool, /usr/sbin/zfs, /usr/sbin/smartctl, /usr/bin/journalctl, /usr/local/bin/mount_up.sh
        ```

4.  **Set Up Individual ZFS Pools:**
    * For **each** physical disk passed through to your Debian VM, create its own independent ZFS pool.
    * **Identify your disks:** Use `lsblk -f` or `sudo fdisk -l` to identify your passed-through disks (e.g., `/dev/sdb`, `/dev/sdc`, `/dev/sdd`, `/dev/sde`, `/dev/sdf`).
    * For **each** disk, create a ZFS pool. Replace `YOUR_POOL_NAME` with a unique name (e.g., `pool_disk1`) and `/dev/sdX` with the correct device ID.
        ```bash
        sudo zpool create -f pool_disk1 /dev/sdb
        sudo zpool create -f pool_disk2 /dev/sdc
        # ... repeat for all your individual disks (e.g., pool_disk3 /dev/sdd, etc.) ...
        ```
    * *(ZFS pools will automatically mount under `/YOUR_POOL_NAME`, e.g., `/pool_disk1`, `/pool_disk2`.)*

6.  **Configure `mergerfs`:**
    * Create a mount point for your merged pool:
        ```bash
        sudo mkdir /mnt/merged_pool
        ```
    * Edit `/etc/fstab` to configure `mergerfs` to mount at boot. This line tells `mergerfs` to combine all your individual ZFS pool mount points into one `/mnt/merged_pool`.
        ```bash
        sudo nano /etc/fstab
        ```
    * Add a line like this (adjusting your ZFS pool mount points and `mergerfs` options):
        ```
        /pool_disk1:/pool_disk2:/pool_disk3:/pool_disk4:/pool_disk5 /mnt/merged_pool fuse.mergerfs defaults,allow_other,use_mfs,minfreespace=10G,fsname=mergerfs_pool 0 0
        ```
        * `defaults`: Standard mount options.
        * `allow_other`: Allows non-root users to access the merged filesystem.
        * `use_mfs`: (Most Free Space) A common `mergerfs` policy to write new files to the disk with the most free space.
        * `minfreespace=10G`: Prevents filling a disk completely, leaving 10GB free.
        * `fsname=mergerfs_pool`: Sets a custom name for the filesystem, useful for `df -h`.
    * Save and exit `nano`.
    * Mount the `mergerfs` pool:
        ```bash
        sudo mount -a
        ```
    * Verify it's mounted: `mount -l | grep mergerfs`

6.  **Place Scripts & Configure `mount_up.sh`:**
    *   `backup.sh` now works with several helper scripts:
        *   `backup_config.sh` (defines default configurations)
        *   `logging_utils.sh` (provides notification functions)
        *   `system_checks.sh` (provides health check functions)
        *   `rsync_operations.sh` (provides rsync backup function)
        *   `snapshot_utils.sh` (provides btrfs snapshot functions)
    *   All these helper scripts **must be located in the same directory** as `backup.sh`.
    *   A recommended location for `backup.sh` and its helpers is a dedicated directory, e.g., `/usr/local/bin/backup_scripts/`.
    *   `mount_up.sh` handles SMB share mounting. It can be placed in the same directory or a standard PATH directory (e.g., `/usr/local/bin/`). The `MOUNT_UP_SCRIPT` variable in `backup.sh` defaults to `/usr/local/bin/mount_up.sh`; adjust if needed.
    ```bash
    # Example: Create a dedicated directory and copy all scripts
    sudo mkdir -p /usr/local/bin/backup_scripts/
    # Assuming you have downloaded the repository or have all scripts (backup.sh and helpers) in your current directory:
    sudo cp backup.sh backup_config.sh logging_utils.sh system_checks.sh rsync_operations.sh snapshot_utils.sh /usr/local/bin/backup_scripts/

    # Place mount_up.sh (example: to /usr/local/bin/)
    sudo cp mount_up.sh /usr/local/bin/mount_up.sh

    # Make all scripts in the backup_scripts directory executable
    sudo chmod +x /usr/local/bin/backup_scripts/*.sh
    # Ensure mount_up.sh is executable
    sudo chmod +x /usr/local/bin/mount_up.sh
    ```

7.  **Create `.env` Configuration File:**
    *   This file stores environment-specific settings, sensitive data (like credential paths), and overrides for defaults set in `backup_config.sh`.
    *   It **must be located in the same directory as `backup.sh`** (e.g., `/usr/local/bin/backup_scripts/.env`). The `ENV_FILE` variable in `backup.sh` is configured to find it there.
        ```bash
        # Example: If backup.sh is in /usr/local/bin/backup_scripts/
        sudo nano /usr/local/bin/backup_scripts/.env
        ```
    *   Add content like the following, adjusting for your setup. This `.env` file provides settings for both `backup.sh` and the parameters needed by `mount_up.sh`.
        ```dotenv
        # .env configuration for backup.sh and mount_up.sh integration

        # --- Settings for mount_up.sh (and used by backup.sh to find shares) ---
        MOUNT_BASE_DIR="/mnt/smb_shares" # Base directory where NAS shares will be mounted by mount_up.sh
        SERVER_IP="YOUR_NAS_IP_ADDRESS" # IP address of your NAS

        # --- Settings primarily for mount_up.sh ---
        # These are standard for mount_up.sh; ensure they are appropriate for your setup.
        DEFAULT_MOUNT_OPTIONS="ro,iocharset=utf8,vers=3.0,uid=0,gid=0,forceuid,forcegid,file_mode=0644,dir_mode=0755" # Read-only is crucial for backup source
        SMB_USERNAME="smb_backup_user" # SMB username for your NAS (read-only access)
        SMB_CREDENTIALS_PATH="/root/.smb_credentials_backup" # Secure path to SMB credentials file

        # --- Overrides for backup_config.sh (for backup.sh) ---
        # Optional: Override Pushover tokens if not using defaults from backup_config.sh
        # PUSHOVER_APP_TOKEN="your_actual_app_token"
        # PUSHOVER_USER_KEY="your_actual_user_key"

        # Optional: Override storage layout, retention policies, or log file path from backup_config.sh
        # BTRFS_MOUNT_POINTS="/mnt/btrfs_driveX /mnt/btrfs_driveY"
        # DEST_ROOT="/media/backup_pool"
        # LOG_FILE="/var/log/custom_backup.log"
        # KEEP_DAILY=5
        # KEEP_WEEKLY=3
        ```
    *   Set strict permissions for the `.env` file:
        ```bash
        # Example: if .env is in /usr/local/bin/backup_scripts/
        sudo chmod 600 /usr/local/bin/backup_scripts/.env
        ```
    *   **Create SMB Credentials File:** As referenced by `SMB_CREDENTIALS_PATH` in `.env`. This file contains the actual username and password for the SMB share.
        ```bash
        # Example path from .env: /root/.smb_credentials_backup
        sudo nano /root/.smb_credentials_backup
        ```
        Add content like:
        ```
        username=smb_backup_user
        password=YOUR_ACTUAL_SMB_PASSWORD
        ```
        Set **strict permissions (CRITICAL FOR SECURITY!)**:
        ```bash
        sudo chmod 600 /root/.smb_credentials_backup
        ```

---

## 6. Configuration

Configuration for the backup system is managed through two main files located in the script directory (e.g. `/usr/local/bin/backup_scripts/`):
*   **`backup_config.sh`**: This script is sourced by `backup.sh` and defines the **default** values for all configuration variables (e.g., Pushover tokens, rsync exclusions, destination paths, BTRFS mount points, snapshot retention policies, log file path). You can review this file to see the defaults.
*   **`.env` File**: This file (e.g., `/usr/local/bin/backup_scripts/.env`) is for your **local overrides and sensitive data**.
    *   It's used to provide environment-specific details like `SERVER_IP`, `MOUNT_BASE_DIR` (which `backup.sh` uses to find shares mounted by `mount_up.sh`), and `SMB_CREDENTIALS_PATH`.
    *   Crucially, any variable set in `.env` will **override** the default value set in `backup_config.sh`. This is the recommended way to customize the backup behavior without modifying the core scripts. For example, set your actual `PUSHOVER_APP_TOKEN`, `BTRFS_MOUNT_POINTS`, `LOG_FILE`, or adjust snapshot retention policies here.

**Key Variables (Defaults in `backup_config.sh`, override in `.env`):**
*   `ENV_FILE`: Variable within `backup.sh` that points to your `.env` file (automatically `${SCRIPT_DIR}/.env`).
*   `SCRIPT_DIR`: Variable within `backup.sh` that stores the path to the directory containing the scripts.
*   `PUSHOVER_APP_TOKEN`, `PUSHOVER_USER_KEY`: For Pushover notifications.
*   `RSYNC_EXCLUDES`: Array of patterns for rsync exclusions.
*   `DEST_ROOT`, `DEST_SUBDIR`, `FINAL_DEST`: Define the backup destination.
*   `BTRFS_MOUNT_POINTS`: Space-separated list of your btrfs filesystem mount points.
*   `SNAPSHOT_PREFIX`, `KEEP_DAILY`, `KEEP_WEEKLY`, `KEEP_MONTHLY`, `KEEP_YEARLY`: Snapshot configuration.
*   `LOG_FILE`: Path to the main log file.
*   `MOUNT_UP_SCRIPT`: Path to `mount_up.sh` (defaults to `/usr/local/bin/mount_up.sh`).

**Dynamic Variables (set by `backup.sh` during runtime):**
*   `SOURCE_FOLDERS`: This variable is **dynamically populated** by `backup.sh` after `mount_up.sh` successfully mounts shares. **Do not set this manually.**

---

## 7. Usage

1.  **Place & Configure Scripts:**
    *   Ensure `backup.sh` and its helper scripts (`backup_config.sh`, etc.) are placed in your chosen script directory (e.g., `/usr/local/bin/backup_scripts/`) as per **Installation & Setup Step 6**.
    *   Create and configure your `.env` file in the same directory as `backup.sh` as per **Installation & Setup Step 7**, providing your specific paths, IPs, credentials path, and any desired overrides for `backup_config.sh`.
    *   Confirm `mount_up.sh` is correctly placed and executable.
    *   Make all scripts in your script directory executable:
        ```bash
        # Example if scripts are in /usr/local/bin/backup_scripts/
        sudo chmod +x /usr/local/bin/backup_scripts/*.sh
        # If mount_up.sh is separate and not covered by above:
        # sudo chmod +x /usr/local/bin/mount_up.sh
        ```

2.  **Test Run (Manually):**
    * It's highly recommended to run the script manually first to ensure configurations are correct, `mount_up.sh` mounts shares, and `backup.sh` proceeds as expected.
    ```bash
    # Example if backup.sh is in /usr/local/bin/backup_scripts/
    sudo /usr/local/bin/backup_scripts/backup.sh
    ```
    * Monitor the script's output on the console and check the detailed log file (its path is defined by the `LOG_FILE` variable, default is `/var/log/backup_pull.log`).
    * Check that `mount_up.sh` mounts shares correctly (its logs are captured by `backup.sh`).

3.  **Schedule with Cron:**
    * Once manual tests are successful, schedule `backup.sh` to run periodically using cron. Run as `root` or the user configured in `sudoers` (Installation Step 3).
    ```bash
    sudo crontab -e
    ```
    * Add a line pointing to your `backup.sh` script location. For example, if it's in `/usr/local/bin/backup_scripts/` and you want it to run daily at 2 AM:
        ```cron
        # Example if backup.sh is in /usr/local/bin/backup_scripts/
        0 2 * * * /usr/local/bin/backup_scripts/backup.sh >> /var/log/backup_cron.log 2>&1
        ```
        *(This redirects cron's own STDOUT/STDERR (if any) to `/var/log/backup_cron.log`, which is useful for debugging cron-specific execution problems. The `backup.sh` script itself logs extensively to its configured `LOG_FILE`.)*

---

## 8. Logging & Notifications

* **Log File:** All script activity, `rsync` output, and ZFS commands are logged to the file specified by `LOG_FILE` in the configuration (default: `/var/log/backup_pull.log`).
* **Pushover Notifications:**
    * **Success:** A quiet (priority `-1`) notification will be sent. You'll receive confirmation without a chime.
    * **Warning:** (e.g., snapshot rotation issues) A normal priority (`0`) notification will be sent.
    * **Failure:** (e.g., log errors, `rsync` failure, snapshot creation failure) A high priority (`1`) notification will be sent, including the hostname.

---

## 9. Recovery Guide

In case of a single drive failure on your Debian VM's cold storage:

1.  **Identify Failed Disk:**
    * Check your Pushover notifications for SMART or ZFS errors.
    * Log in to your Debian VM and run `sudo zpool status` to identify the specific failed ZFS pool and its corresponding physical device.
    * Physically locate and confirm the failed disk.
2.  **Replace Physical Disk:** Power down your Debian VM (and its host if needed), replace the failed 12 TB drive with a new, healthy 12 TB drive. Power on your VM.
3.  **Create New ZFS Pool:** Format the new disk as a new ZFS pool. **Use the exact same pool name** as the failed pool for simplicity and consistency (e.g., `pool_diskX`).
    ```bash
    sudo zpool create -f pool_diskX /dev/sdY # Replace pool_diskX with the old pool name, /dev/sdY with the new disk
    ```
4.  **Verify `mergerfs`:**
    * After creating the new ZFS pool, `mergerfs` should automatically incorporate it if your `/etc/fstab` entry for `mergerfs` uses the pool mount points correctly (e.g., `/pool_diskX`).
    * Verify with `mount -l | grep mergerfs` and `df -h /mnt/merged_pool`.
5.  **Re-run Backup Script:** Manually run the backup script:
    ```bash
    sudo /usr/local/bin/backup.sh
    ```
    * `mount_up.sh` will be called by `backup.sh` to ensure SMB shares are mounted.
    * `rsync` will then detect the missing files on the newly replaced disk's pool (now part of the `mergerfs` pool) and copy them back from your NAS. This process will effectively "restore" the lost data to the new disk.
6.  **Verify Data:** After the `rsync` completes, perform spot checks to ensure the restored data is accessible and intact.

---

## 10. License

This script is provided under the [MIT License](https://opensource.org/licenses/MIT).

MIT License

Copyright (c) [Current Year] [Your Name or Project Name]

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
