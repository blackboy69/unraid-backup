#!/bin/bash

# Function to send Pushover notification
notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-0}" # Default priority 0 (normal)
    local url="https://api.pushover.net/1/messages.json"

    if [[ -z "$PUSHOVER_APP_TOKEN" || -z "$PUSHOVER_USER_KEY" ]]; then
        echo "$(date) ERROR: Pushover API tokens not set. Cannot send notification." 
        return 1
    fi

    curl -s \
        -F "token=$PUSHOVER_APP_TOKEN" \
        -F "user=$PUSHOVER_USER_KEY" \
        -F "title=$title" \
        -F "message=$message" \
        -F "priority=$priority" \
        "$url" > /dev/null

    if [[ $? -ne 0 ]]; then
        echo "$(date) ERROR: Failed to send Pushover notification."
        return 1
    fi
}