#!/bin/bash
# logging_utils.sh
# Contains utility functions for logging and sending Pushover notifications.
# This script is intended to be sourced by the main backup.sh script.
# It relies on PUSHOVER_APP_TOKEN, PUSHOVER_USER_KEY, and LOG_FILE
# being set and available in the environment when its functions are called.

# Sends a notification via Pushover.
# Arguments:
#   $1: title - The title of the Pushover notification.
#   $2: message - The main content of the Pushover notification.
#   $3: priority (optional) - The priority of the message (-2, -1, 0, 1, 2). Defaults to 0.
# Returns:
#   0 if the notification was sent successfully.
#   1 if there was an error (e.g., tokens not set, curl command failed).
pushover_notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-0}" # Default priority is 0 (normal)
    local url="https://api.pushover.net/1/messages.json"

    # Check if Pushover tokens are set and not default placeholder values.
    if [[ -z "$PUSHOVER_APP_TOKEN" || "$PUSHOVER_APP_TOKEN" == "YOUR_PUSHOVER_APP_TOKEN" || \
          -z "$PUSHOVER_USER_KEY" || "$PUSHOVER_USER_KEY" == "YOUR_PUSHOVER_USER_KEY" ]]; then
        echo "$(date) ERROR: Pushover API token or user key is not set or is still the default. Cannot send notification." | tee -a "$LOG_FILE"
        return 1
    fi

    # Send the notification using curl.
    # The output of curl is redirected to /dev/null to prevent it from appearing in logs unless there's an error.
    if ! curl -s \
        -F "token=$PUSHOVER_APP_TOKEN" \
        -F "user=$PUSHOVER_USER_KEY" \
        -F "title=$title" \
        -F "message=$message" \
        -F "priority=$priority" \
        "$url" > /dev/null; then
        echo "$(date) ERROR: Failed to send Pushover notification. Curl command failed." | tee -a "$LOG_FILE"
        return 1
    fi

    echo "$(date) INFO: Pushover notification sent: \"$title\"" | tee -a "$LOG_FILE"
    return 0
}
