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
* **SMB Share Backup:** Connects to and backs up specified SMB shares from your NAS (mounted via `fstab`).
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
    * Hosts a **Debian VM** (where this script runs).
    * Dedicated physical disks are **passed through** to this Debian VM.
    * Inside the Debian VM:
        * Each passed-through disk is configured as its **own independent ZFS pool**.
        * `mergerfs` pools these individual ZFS mount points into a **single, unified mount point**.
        * Samba shares from your NAS are mounted via `fstab`.
        * `rsync` pulls data from the mounted SMB shares to the `mergerfs` pool.
```
+----------------+       +----------------+       +-------------------------------------+
| Primary Server |       |      NAS       |       |              Backup Server          |
| (Main Host)    |       | (Unraid Server)|       |       (Debian VM on Host)           |
|                |       |                |       |                                     |
|  VMs           |------>|  SMB Shares    |------>|  Debian VM (This Script Runs Here)  |
| (Applications) |       | (Primary Data) |       |  +--------------------------------+ |
+----------------+       +----------------+       |  |  /mnt/nas_smb_mounts/          | |
                                                  |  |-- media_movies (fstab mount)   | |
                                                  |  |-- media_tvshows (fstab mount)  | |
                                                  |  |-- data_backups (fstab mount)   | |
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
                                                  |  rsync pulls data from mounted SMB  |
                                                  |  shares to /mnt/merged_pool/backup  |
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
    ```bash
    sudo apt install -y rsync cifs-utils zfsutils-linux smartmontools jq curl mergerfs
    ```

3.  **Configure Secure SMB Credentials File for `fstab`:**
    * Create a file for SMB credentials (e.g., for `root` user, for security):
        ```bash
        sudo nano /root/.smbcredentials
        ```
    * Add the following two lines (replace with your NAS SMB username and password):
        ```
        username=smb_backup_user
        password=YOUR_SMB_PASSWORD
        ```
    * Set **strict permissions (CRITICAL FOR SECURITY!)**:
        ```bash
        sudo chmod 600 /root/.smbcredentials
        ```
        *(If running the script as a non-root user, adjust the path to `~/.smbcredentials` and ensure the user can read it.)*

4.  **Configure Sudoers (if running script as non-root):**
    * Edit the `sudoers` file:
        ```bash
        sudo visudo
        ```
    * Add the following line, replacing `your_username` with the actual username running the script:
        ```
        your_username ALL=(ALL) NOPASSWD: /usr/sbin/zpool, /usr/sbin/zfs, /usr/sbin/smartctl, /usr/bin/journalctl
        ```
        *(Note: `mount`/`umount` commands are not needed in `sudoers` here as `fstab` handles them.)*

5.  **Set Up Individual ZFS Pools:**
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

7.  **Configure SMB Shares to Mount Automatically via `fstab`:**
    * Create a base directory for your NAS mounts on your Debian VM:
        ```bash
        sudo mkdir /mnt/nas_smb_mounts
        ```
    * Create subdirectories for each specific NAS share you want to mount (e.g., `media_movies`, `media_tvshows`, `proxmox_vzdumps`):
        ```bash
        sudo mkdir /mnt/nas_smb_mounts/media_movies
        sudo mkdir /mnt/nas_smb_mounts/media_tvshows
        sudo mkdir /mnt/nas_smb_mounts/proxmox_vzdumps
        ```
    * Edit `/etc/fstab` to add entries for each SMB share:
        ```bash
        sudo nano /etc/fstab
        ```
    * Add lines for each SMB share. Replace `YOUR_NAS_IP`, share names (e.g., `media_movies`), and local mount points.
        ```
        //YOUR_NAS_IP/media_movies /mnt/nas_smb_mounts/media_movies cifs credentials=/root/.smbcredentials,ro,iocharset=utf8,vers=3.0,uid=0,gid=0,forceuid,forcegid,file_mode=0644,dir_mode=0755 0 0
        //YOUR_NAS_IP/media_tvshows /mnt/nas_smb_mounts/media_tvshows cifs credentials=/root/.smbcredentials,ro,iocharset=utf8,vers=3.0,uid=0,gid=0,forceuid,forcegid,file_mode=0644,dir_mode=0755 0 0
        //YOUR_NAS_IP/proxmox_vzdumps /mnt/nas_smb_mounts/proxmox_vzdumps cifs credentials=/root/.smbcredentials,ro,iocharset=utf8,vers=3.0,uid=0,gid=0,forceuid,forcegid,file_mode=0644,dir_mode=0755 0 0
        ```
        * `credentials=/root/.smbcredentials`: Points to your secure credentials file.
        * `ro`: Mounts the share as read-only (critical for security).
        * `iocharset=utf8`: Handles character encoding.
        * `vers=3.0`: Forces SMB3 protocol (recommended for performance and security).
        * `uid=0,gid=0`: Mounts the share owned by root (user 0) and group root (group 0). Adjust `uid` and `gid` if your script runs as a different user or you want different ownership.
        * `file_mode=0644,dir_mode=0755`: Sets default permissions for files and directories on the mounted share.
    * Save and exit `nano`.
    * Test mounting all `fstab` entries: `sudo mount -a`
    * Verify they are mounted: `mount -l | grep cifs`

---

## 6. Configuration

All configuration variables are located at the top of the script, starting with `--- START CONFIGURATION ---`. **Edit these variables within the script file (`/usr/local/bin/backup_pull.sh`)** to match your environment.

* **`PUSHOVER_APP_TOKEN` / `PUSHOVER_USER_KEY`:** Your Pushover API credentials.
* **`SMB_NAS_PASSWORD_FILE`:** Path to your secure SMB credentials file (e.g., `/root/.smbcredentials`).
* **`SOURCE_FOLDERS`:** **Crucially, this is a space-separated list of your local SMB mount points on your Debian VM** (e.g., `/mnt/nas_smb_mounts/media_movies/`). Ensure trailing slashes are present for `rsync`.
* **`RSYNC_EXCLUDES`:** An array of `rsync` patterns to exclude files or directories globally.
* **`DEST_ROOT`:** The mount point of your `mergerfs` pool (e.g., `/mnt/merged_pool`).
* **`DEST_SUBDIR`:** An optional subdirectory within `DEST_ROOT` for your backups (e.g., `nas_backups`).
* **`ZFS_POOLS`:** A space-separated list of the *names* of your individual ZFS pools on your Debian VM (e.g., `pool_disk1 pool_disk2`).
* **`SNAPSHOT_PREFIX`:** The prefix for your ZFS snapshot names (e.g., `backup`).
* **`KEEP_DAILY`, `KEEP_WEEKLY`, `KEEP_MONTHLY`, `KEEP_YEARLY`:** Your snapshot retention policy. Set to `0` to disable a specific tier of snapshots.
* **`LOG_FILE`:** The path to the script's log file (e.g., `/var/log/backup_pull.log`).

---

## 7. Usage

1.  **Place the Script:** Save the script content as `/usr/local/bin/backup_pull.sh` on your Debian VM.
2.  **Make Executable:**
    ```bash
    sudo chmod +x /usr/local/bin/backup_pull.sh
    ```
3.  **Test Run (Manually):**
    ```bash
    sudo /usr/local/bin/backup_pull.sh
    ```
    Monitor the output and the log file: `tail -f /var/log/backup_pull.log`.
4.  **Schedule with Cron:**
    * Schedule the script to run periodically (e.g., daily at 2 AM) from `root`'s crontab (or the user configured in `sudoers`).
    ```bash
    sudo crontab -e
    ```
    * Add this line:
        ```cron
        0 2 * * * /usr/local/bin/backup_pull.sh >> /var/log/backup_pull_cron.log 2>&1
        ```
        *(This redirects cron's output to `/var/log/backup_pull_cron.log` for debugging cron execution issues, in addition to the script's internal `LOG_FILE`.)*

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
    * After creating the new ZFS pool, `mergerfs` should automatically incorporate it if your `/etc/fstab` entry for `mergerfs` uses the pool names or mount points correctly.
    * Verify with `mount -l | grep mergerfs` and `df -h /mnt/merged_pool`.
5.  **Re-run Backup Script:** Manually run the backup script:
    ```bash
    sudo /usr/local/bin/backup_pull.sh
    ```
    `rsync` will then detect the missing files on the newly replaced disk's pool and copy them back from your NAS. This process will effectively "restore" the lost data to the new disk.
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
