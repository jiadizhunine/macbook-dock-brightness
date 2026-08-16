#!/bin/sh
set -eu

LABEL="io.github.jiadizhunine.macbook-dock-brightness"
SUPPORT_DIR="$HOME/Library/Application Support/MacBookDockBrightness"
INSTALLED_BINARY="$SUPPORT_DIR/macbook-dock-brightness"
CONFIG_PATH="$SUPPORT_DIR/config.json"
STATE_PATH="$SUPPORT_DIR/state.json"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DISABLED_LAUNCH_AGENT="$SUPPORT_DIR/LaunchAgent.plist.disabled"
LOG_PATH="$HOME/Library/Logs/MacBookDockBrightness.log"
ERROR_LOG_PATH="$HOME/Library/Logs/MacBookDockBrightness.error.log"

DRY_RUN=0
PURGE_LOGS=0

usage() {
    cat <<'EOF'
Usage: ./scripts/uninstall.sh [--dry-run] [--purge-logs]

The uninstaller stops the LaunchAgent and restores the built-in display before
removing the executable and configuration. Logs are retained unless requested.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --purge-logs)
            PURGE_LOGS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this uninstaller as your normal login user, not with sudo." >&2
    exit 3
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Would stop: $LABEL"
    echo "Would restore the built-in display using: $INSTALLED_BINARY"
    echo "Would remove: $LAUNCH_AGENT"
    echo "Would remove: $INSTALLED_BINARY"
    echo "Would remove: $CONFIG_PATH"
    [ "$PURGE_LOGS" -eq 1 ] && echo "Would remove logs in $HOME/Library/Logs"
    exit 0
fi

USER_DOMAIN="gui/$(id -u)"
job_is_loaded() {
    /bin/launchctl print "$USER_DOMAIN/$LABEL" >/dev/null 2>&1
}

wait_for_job_unloaded() {
    MDB_WAIT_COUNT=0
    while job_is_loaded; do
        MDB_WAIT_COUNT=$((MDB_WAIT_COUNT + 1))
        [ "$MDB_WAIT_COUNT" -lt 50 ] || return 1
        sleep 0.1
    done
}

if job_is_loaded; then
    if ! /bin/launchctl bootout "$USER_DOMAIN/$LABEL" || ! wait_for_job_unloaded; then
        echo "Could not stop the LaunchAgent; uninstall aborted without removing files." >&2
        exit 6
    fi
fi

if [ -f "$LAUNCH_AGENT" ]; then
    mkdir -p "$SUPPORT_DIR"
    mv -f "$LAUNCH_AGENT" "$DISABLED_LAUNCH_AGENT"
fi

RESTORE_OK=1
if [ -f "$STATE_PATH" ]; then
    if [ -x "$INSTALLED_BINARY" ]; then
        if ! MDB_CONFIG_PATH="$CONFIG_PATH" MDB_STATE_PATH="$STATE_PATH" \
            "$INSTALLED_BINARY" --restore; then
            RESTORE_OK=0
        fi
    else
        RESTORE_OK=0
    fi
fi

if [ "$RESTORE_OK" -ne 1 ]; then
    cat >&2 <<EOF
The LaunchAgent is stopped, but automatic restoration was incomplete.
The recovery binary and configuration were kept at:
  $INSTALLED_BINARY
  $CONFIG_PATH
Use the MacBook brightness-up key, or retry:
  "$INSTALLED_BINARY" --restore
EOF
    exit 7
fi

rm -f "$INSTALLED_BINARY" "$CONFIG_PATH" "$STATE_PATH" "$DISABLED_LAUNCH_AGENT"
rmdir "$SUPPORT_DIR" >/dev/null 2>&1 || true

if [ "$PURGE_LOGS" -eq 1 ]; then
    rm -f "$LOG_PATH" "$ERROR_LOG_PATH"
fi

echo "MacBook Dock Brightness was uninstalled and the built-in display was restored."
