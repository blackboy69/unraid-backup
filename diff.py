#!/usr/bin/env python3

import subprocess
import json
import os
import sys
import argparse
from collections import defaultdict
from datetime import datetime, timedelta

# --- Configuration ---
SOURCE_PATH_CONFIG = "/mnt/backup"
SOURCE_SNAPSHOTS_PATH = "/mnt/backup/.snapshots"
DEST_PATH_CONFIG = "NAS-ssh:/mnt/user"
SOURCE_NAME = "coldstorage"
DEST_NAME = "nas"

# --- Configuration for --show-fix ---
COLDSTORAGE_USER = "byron"
COLDSTORAGE_HOST = "coldstorage"
NAS_BASE_PATH = "/mnt/user"

EXCLUDED_PATTERNS = [
    'domains/**', 'system/**', 'appdata/**', 'scratch/**',
    '.snapshots/**', 'torrents/**', '@revisions/**', '*.partial'
]

# --- Color and Style Codes for Terminal Output ---
class Colors:
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    CYAN = '\033[96m'
    BOLD = '\033[1m'
    RESET = '\033[0m'

def human_readable_bytes(size_bytes):
    """Converts a size in bytes to a human-readable format."""
    if size_bytes is None or size_bytes < 0: return "N/A"
    if size_bytes == 0: return "0B"
    power = 1024
    n = 0
    power_labels = {0: '', 1: 'K', 2: 'M', 3: 'G', 4: 'T'}
    while size_bytes >= power and n < len(power_labels) - 1:
        size_bytes /= power
        n += 1
    return f"{size_bytes:.1f}{power_labels[n]}B"

def human_readable_time(time_diff: timedelta) -> str:
    """Converts a timedelta object into a concise, human-readable string."""
    seconds = abs(time_diff.total_seconds())
    if seconds < 60: return f"{int(seconds)} second{'s' if seconds != 1 else ''}"
    if seconds < 3600: return f"{int(seconds / 60)} minute{'s' if int(seconds / 60) != 1 else ''}"
    if seconds < 86400: return f"{seconds / 3600:.1f} hour{'s' if seconds / 3600 != 1 else ''}"
    if seconds < 604800: return f"{seconds / 86400:.1f} day{'s' if seconds / 86400 != 1 else ''}"
    days = int(seconds / 86400)
    if days < 30:
        weeks, rem_days = divmod(days, 7)
        return f"{weeks} week{'s' if weeks != 1 else ''}, {rem_days} day{'s' if rem_days != 1 else ''}"
    if days < 365:
        months, rem_days = divmod(days, 30)
        weeks = rem_days // 7
        return f"{months} month{'s' if months != 1 else ''}, {weeks} week{'s' if weeks != 1 else ''}"
    years, rem_days = divmod(days, 365)
    months = rem_days // 30
    return f"{years} year{'s' if years != 1 else ''}, {months} month{'s' if months != 1 else ''}"

def select_snapshot() -> tuple[str, str]:
    """Lists available snapshots and prompts the user to select one."""
    snapshot_dir = SOURCE_SNAPSHOTS_PATH
    if not os.path.isdir(snapshot_dir):
        print(f"{Colors.RED}FATAL ERROR: Snapshot directory not found at '{snapshot_dir}'.{Colors.RESET}", file=sys.stderr)
        sys.exit(1)
    
    try:
        snapshots = sorted([d for d in os.listdir(snapshot_dir) if os.path.isdir(os.path.join(snapshot_dir, d))])
    except OSError as e:
        print(f"{Colors.RED}FATAL ERROR: Could not read snapshot directory: {e}{Colors.RESET}", file=sys.stderr)
        sys.exit(1)

    if not snapshots:
        print(f"{Colors.RED}FATAL ERROR: No snapshots found in '{snapshot_dir}'.{Colors.RESET}", file=sys.stderr)
        sys.exit(1)

    print("\nPlease select a snapshot to compare against:")
    for i, snap_name in enumerate(snapshots):
        print(f"  {Colors.YELLOW}{i + 1}{Colors.RESET}) {snap_name}")
    
    while True:
        try:
            choice = input(f"Enter number (1-{len(snapshots)}): ")
            choice_index = int(choice) - 1
            if 0 <= choice_index < len(snapshots):
                selected_snap_name = snapshots[choice_index]
                selected_snap_path = os.path.join(snapshot_dir, selected_snap_name)
                display_name = f"snapshot({selected_snap_name})"
                return selected_snap_path, display_name
            else:
                print("Invalid number, please try again.")
        except (ValueError, IndexError):
            print("Invalid input, please enter a number from the list.")

def get_file_listing(path: str, name: str, excludes: list) -> dict:
    """Gets a detailed listing of all files at a given path using 'rclone lsjson'."""
    command = ["rclone", "lsjson", "-R", path]
    for pattern in excludes:
        command.extend(["--exclude", pattern])

    print(f"INFO: Getting file list from {name} ({path})... This may take a moment.")
    process = subprocess.run(command, capture_output=True, text=True, encoding='utf-8')

    if process.returncode != 0:
        print(f"{Colors.RED}FATAL ERROR: rclone failed to list '{path}'.{Colors.RESET}", file=sys.stderr)
        print(process.stderr, file=sys.stderr)
        sys.exit(1)

    file_map = {}
    try:
        for item in json.loads(process.stdout):
            if not item.get('IsDir', False):
                mod_time_str = item['ModTime'].split('.')[0]
                dt_obj = datetime.fromisoformat(mod_time_str)
                if dt_obj.tzinfo:
                    dt_obj = dt_obj.replace(tzinfo=None)
                file_map[item['Path']] = {'size': item['Size'], 'mod_time': dt_obj}
    except json.JSONDecodeError:
        print(f"{Colors.RED}FATAL ERROR: Could not parse file list from '{path}'.{Colors.RESET}", file=sys.stderr)
        sys.exit(1)

    print(f"INFO: Found {len(file_map)} files in {name}.")
    return file_map

def get_tlds(path: str, name: str, excludes: list) -> list:
    """Gets a list of top-level directories at a given path, respecting excludes."""
    command = ["rclone", "lsf", "--dirs-only", path]
    for pattern in excludes:
        command.extend(["--exclude", pattern])
    
    print(f"INFO: Getting TLD list from {name} ({path})...")
    process = subprocess.run(command, capture_output=True, text=True, encoding='utf-8')
    if process.returncode != 0:
        print(f"{Colors.RED}FATAL ERROR: rclone failed to list TLDs for '{path}'.{Colors.RESET}", file=sys.stderr)
        print(process.stderr, file=sys.stderr)
        sys.exit(1)
    return [d.strip('/') for d in process.stdout.strip().split('\n') if d]

def get_dir_key(path: str) -> str:
    """Determines the top-level directory key for a given file path."""
    if '/' in path:
        return path.split('/')[0]
    return "(root)"

def compare_listings(source_map: dict, dest_map: dict) -> dict:
    """Compares two file listings and identifies all differences."""
    changes = defaultdict(lambda: defaultdict(list))
    source_paths = set(source_map.keys())
    dest_paths = set(dest_map.keys())

    for path in dest_paths - source_paths:
        changes[get_dir_key(path)]['nas_only'].append(path)

    for path in source_paths - dest_paths:
        changes[get_dir_key(path)]['cs_only'].append(path)

    for path in source_paths & dest_paths:
        source_file = source_map[path]
        dest_file = dest_map[path]
        dir_name = get_dir_key(path)

        if source_file['size'] != dest_file['size']:
            changes[dir_name]['size_changed'].append(path)
        elif source_file['mod_time'] != dest_file['mod_time']:
            if dest_file['mod_time'] > source_file['mod_time']:
                changes[dir_name]['nas_newer'].append(path)
            else:
                changes[dir_name]['cs_newer'].append(path)
    return changes

def print_report(changes: dict, source_map: dict, dest_map: dict, show_all: bool, show_fix: bool, source_path_for_fix: str, source_display_name: str, dest_display_name: str):
    """Prints the final summary, details, and optional fix commands."""
    
    all_source_dirs = {get_dir_key(path) for path in source_map.keys()}
    all_dest_dirs = {get_dir_key(path) for path in dest_map.keys()}
    all_dirs_sorted = sorted(list(all_source_dirs | all_dest_dirs))

    total_nas_size = sum(dest_map.get(path, {}).get('size', 0) for dir_name in changes for path in changes[dir_name].get('nas_only', []))
    total_cs_size = sum(source_map.get(path, {}).get('size', 0) for dir_name in changes for path in changes[dir_name].get('cs_only', []))
    
    print("\n--- Summary of Differences ---")
    header = f"{'Directory':<25} | {f'{dest_display_name} only':<12} | {f'{source_display_name} only':<12} | {'Size Change':<12} | {f'{dest_display_name} Newer':<12} | {f'{source_display_name} Newer':<12}"
    print(header)
    print("-" * len(header))
    for dir_name in all_dirs_sorted:
        nas_c = len(changes[dir_name].get('nas_only', []))
        cs_c = len(changes[dir_name].get('cs_only', []))
        sc_c = len(changes[dir_name].get('size_changed', []))
        nn_c = len(changes[dir_name].get('nas_newer', []))
        csn_c = len(changes[dir_name].get('cs_newer', []))
        print(f"{dir_name:<25} | {nas_c:<12} | {cs_c:<12} | {sc_c:<12} | {nn_c:<12} | {csn_c:<12}")
    print("-" * len(header))
    total_nas_hr = human_readable_bytes(total_nas_size)
    total_cs_hr = human_readable_bytes(total_cs_size)
    print(f"{'TOTAL SIZE':<25} | {total_nas_hr:<12} | {total_cs_hr:<12} | {'':<12} | {'':<12} | {'':<12}")

    if not changes:
        print("\nNo differences found.")
        return
        
    print("\n--- Details of Differences ---")
    for dir_name in sorted(all_dirs_sorted):
        # --- THIS IS THE FIX YOU REQUESTED ---
        # If there are no changes for this directory, skip it entirely.
        if not changes[dir_name]:
            continue
            
        print(f"\nDirectory: {dir_name}\n------------------------")
        
        detail_map = [
            ('nas_only', f'Only on {dest_display_name}', Colors.RED, '-'),
            ('cs_only', f'Only on {source_display_name}', Colors.GREEN, '+'),
            ('size_changed', 'Size has changed', Colors.YELLOW, '*'),
            ('nas_newer', f'Date is newer on {dest_display_name}', Colors.CYAN, '~'),
            ('cs_newer', f'Date is newer on {source_display_name}', Colors.CYAN, '~')
        ]
        if show_fix:
            print(f"\n--- Fix Commands (to run on {dest_display_name} server) ---")
            for dir_name in sorted(changes.keys()):
                to_copy = changes[dir_name].get('cs_only', [])
                if to_copy:
                    print(f"\n# Copy NEW files for directory: {dir_name}")
                    for path in to_copy:
                        source_full_path = os.path.join(source_path_for_fix, path)
                        dest_path = os.path.join(NAS_BASE_PATH, path)
                        dest_dir = os.path.dirname(dest_path)
                        print(f'mkdir -p "{dest_dir}"')
                        print(f'scp "{COLDSTORAGE_USER}@{COLDSTORAGE_HOST}:{source_full_path}" "{dest_path}"')

                to_copy = changes[dir_name].get('size_changed', [])
                if to_copy:
                    print(f"\n# Copy changed files for directory: {dir_name}")
                    for path in to_copy:
                        source_full_path = os.path.join(source_path_for_fix, path)
                        dest_path = os.path.join(NAS_BASE_PATH, path)
                        dest_dir = os.path.dirname(dest_path)
                        print(f'mkdir -p "{dest_dir}"')
                        print(f'scp "{COLDSTORAGE_USER}@{COLDSTORAGE_HOST}:{source_full_path}" "{dest_path}"')

                to_touch = changes[dir_name].get('cs_newer', [])
                if to_touch:
                    print(f"\n# Update timestamps newer on coldstorage for directory: {dir_name}")
                    for path in to_touch:
                        cs_time = source_map[path]['mod_time']
                        touch_format = cs_time.strftime('%Y%m%d%H%M.%S')
                        dest_path = os.path.join(NAS_BASE_PATH, path)
                        print(f'touch -t {touch_format} "{dest_path}"')

                to_touch = changes[dir_name].get('nas_newer', [])
                if to_touch:
                    print(f"\n# Update timestamps newer on nas for directory: {dir_name}")
                    for path in to_touch:
                        cs_time = source_map[path]['mod_time']
                        touch_format = cs_time.strftime('%Y%m%d%H%M.%S')
                        dest_path = os.path.join(NAS_BASE_PATH, path)
                        print(f'touch -t {touch_format} "{dest_path}"')                    
        else:
            for key, title, color, symbol in detail_map:
                items = changes[dir_name].get(key, [])
                if items:
                    print(f"{color}  {title} ({len(items)}):{Colors.RESET}")
                    limit = None if show_all else 3
                    for item in items[:limit]:
                        details = ""
                        if key == 'size_changed':
                            nas_size = human_readable_bytes(dest_map.get(item, {}).get('size'))
                            cs_size = human_readable_bytes(source_map.get(item, {}).get('size'))
                            details = f"({Colors.BOLD}{nas_size} on {dest_display_name}, {cs_size} on {source_display_name}{Colors.RESET})"
                        elif key in ['nas_newer', 'cs_newer']:
                            time_diff = abs(dest_map[item]['mod_time'] - source_map[item]['mod_time'])
                            hr_diff = human_readable_time(time_diff)
                            newer_on = dest_display_name if key == 'nas_newer' else source_display_name
                            details = f"({Colors.BOLD}{hr_diff} newer on {newer_on}{Colors.RESET})"
                        print(f"    {symbol} {item} {details}")
                    if not show_all and len(items) > 3:
                        print(f"    ... +{len(items) - 3} more")

        
def main():
    """Main function to parse arguments and run the script."""
    parser = argparse.ArgumentParser(
        description="Diff two locations and report changes.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument('tlds', nargs='*', default=[], help="Optional: One or more top-level directories to compare (e.g., MEDIA ISOs).")
    parser.add_argument('-x', '--exclude', action='append', default=[], help="Exclude a top-level directory from the comparison (can be used multiple times).")
    parser.add_argument('--show-all', action='store_true', help="Show all differing files, not just the first 3.")
    parser.add_argument('--show-fix', action='store_true', help=f"Show commands to sync {DEST_NAME} from {SOURCE_NAME}.")
    parser.add_argument('--use-snapshot', action='store_true', help=f"Interactively select a snapshot on {SOURCE_NAME} to use for comparison.")
    args = parser.parse_args()
    
    source_path = SOURCE_PATH_CONFIG
    source_display_name = SOURCE_NAME
    if args.use_snapshot:
        source_path, source_display_name = select_snapshot()

    # Get the full file lists once
    source_map_full = get_file_listing(source_path, source_display_name, EXCLUDED_PATTERNS)
    dest_map_full = get_file_listing(DEST_PATH_CONFIG, DEST_NAME, EXCLUDED_PATTERNS)

    # Determine the final set of TLDs to include in the report
    tlds_to_process = set(args.tlds)
    if not tlds_to_process: # If no TLDs specified, use all
        tlds_to_process = {get_dir_key(p) for p in list(source_map_full.keys()) + list(dest_map_full.keys())}

    if args.exclude:
        print(f"INFO: Excluding TLDs: {', '.join(args.exclude)}")
        tlds_to_process -= set(args.exclude)
      
    # Filter the full maps based on the final TLD list
    source_map = {path: data for path, data in source_map_full.items() if get_dir_key(path) in tlds_to_process}
    dest_map = {path: data for path, data in dest_map_full.items() if get_dir_key(path) in tlds_to_process}
            
    if not os.path.ismount(SOURCE_PATH_CONFIG):
        print(f"{Colors.RED}FATAL ERROR: Base path '{SOURCE_PATH_CONFIG}' is not mounted. Exiting.{Colors.RESET}", file=sys.stderr)
        sys.exit(1)
        
    differences = compare_listings(source_map, dest_map)
    print_report(differences, source_map, dest_map, args.show_all, args.show_fix, source_path, source_display_name, DEST_NAME)

if __name__ == "__main__":
    main()