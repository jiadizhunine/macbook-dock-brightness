#!/bin/sh
set -eu

LABEL="io.github.jiadizhunine.macbook-dock-brightness"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SUPPORT_DIR="$HOME/Library/Application Support/MacBookDockBrightness"
INSTALLED_BINARY="$SUPPORT_DIR/macbook-dock-brightness"
CONFIG_PATH="$SUPPORT_DIR/config.json"
STATE_PATH="$SUPPORT_DIR/state.json"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_PATH="$HOME/Library/Logs/MacBookDockBrightness.log"
ERROR_LOG_PATH="$HOME/Library/Logs/MacBookDockBrightness.error.log"
BUILD_BINARY="$PROJECT_ROOT/build/macbook-dock-brightness"

TARGET_DISPLAY_ID=""
UNDOCKED_BRIGHTNESS=""
WATCHDOG_INTERVAL=""
MATCH_SERIAL=0
FORCE_CONFIG=0
DRY_RUN=0
NO_START=0

usage() {
    cat <<'EOF'
Usage: ./scripts/install.sh [options]

Options:
  --target-display-id ID      Select an active external display
  --match-serial              Include its serial number in matching
  --undocked-brightness N     Restore level from 0.05 to 1 (default 0.32)
  --watchdog-interval N       Safety check interval (default 2 seconds)
  --force-config              Replace an existing configuration
  --dry-run                   Print paths and actions without changing anything
  --no-start                  Install files but do not load the LaunchAgent
  -h, --help                  Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target-display-id)
            [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
            TARGET_DISPLAY_ID=$2
            shift 2
            ;;
        --match-serial)
            MATCH_SERIAL=1
            shift
            ;;
        --undocked-brightness)
            [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
            UNDOCKED_BRIGHTNESS=$2
            shift 2
            ;;
        --watchdog-interval)
            [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }
            WATCHDOG_INTERVAL=$2
            shift 2
            ;;
        --force-config)
            FORCE_CONFIG=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --no-start)
            NO_START=1
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
    echo "Run this installer as your normal login user, not with sudo." >&2
    exit 3
fi

if [ "$DRY_RUN" -eq 0 ] && \
   { [ ! -f "$CONFIG_PATH" ] || [ "$FORCE_CONFIG" -eq 1 ]; } && \
   [ -z "$TARGET_DISPLAY_ID" ]; then
    echo "--target-display-id is required for first install or --force-config." >&2
    echo "Run the built program with --list-displays first." >&2
    exit 4
fi

if [ "$DRY_RUN" -eq 1 ]; then
    cat <<EOF
Would build: $BUILD_BINARY
Would install: $INSTALLED_BINARY
Would configure: $CONFIG_PATH
Would create: $LAUNCH_AGENT
Would log to: $LOG_PATH
Would load label: $LABEL
EOF
    exit 0
fi

make -C "$PROJECT_ROOT" release

BINARY_TEMP=""
PLIST_TEMP=""
CONFIG_TEMP=""
CONFIG_CANDIDATE_DIR=""
CONFIG_CANDIDATE=""
MDB_ROLLBACK_TEMP=""
BACKUP_DIR=""
KEEP_BACKUP=0
TRANSACTION_STARTED=0
INSTALL_COMMITTED=0
cleanup() {
    [ -z "$BINARY_TEMP" ] || rm -f "$BINARY_TEMP"
    [ -z "$PLIST_TEMP" ] || rm -f "$PLIST_TEMP"
    [ -z "$CONFIG_TEMP" ] || rm -f "$CONFIG_TEMP"
    [ -z "$MDB_ROLLBACK_TEMP" ] || rm -f "$MDB_ROLLBACK_TEMP"
    [ -z "$CONFIG_CANDIDATE" ] || rm -f "$CONFIG_CANDIDATE"
    [ -z "$CONFIG_CANDIDATE_DIR" ] || rmdir "$CONFIG_CANDIDATE_DIR" >/dev/null 2>&1 || true
    if [ -n "$BACKUP_DIR" ] && [ "$KEEP_BACKUP" -eq 0 ]; then
        rm -f "$BACKUP_DIR/binary" "$BACKUP_DIR/config.json" \
            "$BACKUP_DIR/LaunchAgent.plist" "$BACKUP_DIR/failed-new.plist"
        rmdir "$BACKUP_DIR" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

if [ -f "$CONFIG_PATH" ] && [ "$FORCE_CONFIG" -eq 0 ]; then
    MDB_CONFIG_PATH="$CONFIG_PATH" "$BUILD_BINARY" --validate-config
fi

if [ ! -f "$CONFIG_PATH" ] || [ "$FORCE_CONFIG" -eq 1 ]; then
    CONFIG_CANDIDATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/macbook-dock-brightness-config.XXXXXX")
    CONFIG_CANDIDATE="$CONFIG_CANDIDATE_DIR/config.json"
    set -- "$BUILD_BINARY" --init-config --target-display-id "$TARGET_DISPLAY_ID"
    [ "$MATCH_SERIAL" -eq 1 ] && set -- "$@" --match-serial
    [ -n "$UNDOCKED_BRIGHTNESS" ] && set -- "$@" --undocked-brightness "$UNDOCKED_BRIGHTNESS"
    [ -n "$WATCHDOG_INTERVAL" ] && set -- "$@" --watchdog-interval "$WATCHDOG_INTERVAL"
    MDB_CONFIG_PATH="$CONFIG_CANDIDATE" "$@"
    MDB_CONFIG_PATH="$CONFIG_CANDIDATE" "$BUILD_BINARY" --validate-config
fi

USER_DOMAIN="gui/$(id -u)"
job_is_loaded() {
    /bin/launchctl print "$USER_DOMAIN/$LABEL" >/dev/null 2>&1
}

job_is_running() {
    /bin/launchctl print "$USER_DOMAIN/$LABEL" 2>/dev/null |
        grep -q '^[[:space:]]*state = running$'
}

wait_for_job_unloaded() {
    MDB_WAIT_COUNT=0
    while job_is_loaded; do
        MDB_WAIT_COUNT=$((MDB_WAIT_COUNT + 1))
        [ "$MDB_WAIT_COUNT" -lt 50 ] || return 1
        sleep 0.1
    done
}

wait_for_job_running() {
    MDB_WAIT_COUNT=0
    while ! job_is_running; do
        MDB_WAIT_COUNT=$((MDB_WAIT_COUNT + 1))
        [ "$MDB_WAIT_COUNT" -lt 50 ] || return 1
        sleep 0.1
    done
}

stop_job() {
    if job_is_loaded; then
        /bin/launchctl bootout "$USER_DOMAIN/$LABEL" || return 1
        wait_for_job_unloaded || return 1
    fi
}

loaded_installation_is_restartable() {
    MDB_CONFIG_PATH="$CONFIG_PATH" "$INSTALLED_BINARY" --validate-config >/dev/null 2>&1 || return 1
    /usr/bin/plutil -lint "$LAUNCH_AGENT" >/dev/null 2>&1 || return 1
    MDB_OLD_LABEL=$(/usr/bin/plutil -extract Label raw -o - "$LAUNCH_AGENT" 2>/dev/null) || return 1
    MDB_OLD_PROGRAM=$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$LAUNCH_AGENT" 2>/dev/null) || return 1
    MDB_OLD_MODE=$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$LAUNCH_AGENT" 2>/dev/null) || return 1
    [ "$MDB_OLD_LABEL" = "$LABEL" ] &&
        [ "$MDB_OLD_PROGRAM" = "$INSTALLED_BINARY" ] &&
        [ "$MDB_OLD_MODE" = "--daemon" ]
}

restore_backup_file() {
    MDB_RESTORE_SOURCE=$1
    MDB_RESTORE_DESTINATION=$2
    MDB_RESTORE_MODE=$3
    MDB_ROLLBACK_TEMP=$(mktemp "${MDB_RESTORE_DESTINATION%/*}/.rollback.XXXXXX") || return 1
    install -m "$MDB_RESTORE_MODE" "$MDB_RESTORE_SOURCE" "$MDB_ROLLBACK_TEMP" || return 1
    mv -f "$MDB_ROLLBACK_TEMP" "$MDB_RESTORE_DESTINATION" || return 1
}

rollback_install() {
    echo "Installation did not commit; attempting to restore the previous installation." >&2
    if ! stop_job; then
        echo "The failed LaunchAgent could not be stopped." >&2
        KEEP_BACKUP=1
        return 1
    fi

    if [ -f "$LAUNCH_AGENT" ]; then
        mv -f "$LAUNCH_AGENT" "$BACKUP_DIR/failed-new.plist" || {
            KEEP_BACKUP=1
            return 1
        }
    fi

    if [ -f "$STATE_PATH" ]; then
        MDB_RESTORE_OK=0
        if [ -x "$INSTALLED_BINARY" ]; then
            if MDB_CONFIG_PATH="$CONFIG_PATH" MDB_STATE_PATH="$STATE_PATH" \
                "$INSTALLED_BINARY" --restore; then
                MDB_RESTORE_OK=1
            fi
        fi
        if [ "$MDB_RESTORE_OK" -ne 1 ] && [ -x "$BACKUP_DIR/binary" ]; then
            MDB_OLD_CONFIG="$BACKUP_DIR/missing-config.json"
            [ ! -f "$BACKUP_DIR/config.json" ] || MDB_OLD_CONFIG="$BACKUP_DIR/config.json"
            if MDB_CONFIG_PATH="$MDB_OLD_CONFIG" MDB_STATE_PATH="$STATE_PATH" \
                "$BACKUP_DIR/binary" --restore; then
                MDB_RESTORE_OK=1
            fi
        fi
        if [ "$MDB_RESTORE_OK" -ne 1 ]; then
            echo "The new service is stopped, but the built-in display could not be restored." >&2
            KEEP_BACKUP=1
            return 1
        fi
    fi

    if [ "$OLD_HAD_BINARY" -eq 1 ]; then
        restore_backup_file "$BACKUP_DIR/binary" "$INSTALLED_BINARY" 755 || return 1
    else
        rm -f "$INSTALLED_BINARY"
    fi
    if [ "$OLD_HAD_CONFIG" -eq 1 ]; then
        restore_backup_file "$BACKUP_DIR/config.json" "$CONFIG_PATH" 600 || return 1
    else
        rm -f "$CONFIG_PATH"
    fi
    if [ "$OLD_HAD_PLIST" -eq 1 ]; then
        restore_backup_file "$BACKUP_DIR/LaunchAgent.plist" "$LAUNCH_AGENT" 644 || return 1
    else
        rm -f "$LAUNCH_AGENT"
    fi

    if [ "$OLD_JOB_WAS_LOADED" -eq 1 ]; then
        if ! /bin/launchctl bootstrap "$USER_DOMAIN" "$LAUNCH_AGENT" || \
            ! wait_for_job_running; then
            stop_job >/dev/null 2>&1 || true
            rm -f "$LAUNCH_AGENT"
            echo "Previous files were restored, but the previous LaunchAgent could not restart." >&2
            KEEP_BACKUP=1
            return 1
        fi
        sleep 1
        if ! job_is_running; then
            stop_job >/dev/null 2>&1 || true
            rm -f "$LAUNCH_AGENT"
            echo "The previous LaunchAgent did not stay running after rollback." >&2
            KEEP_BACKUP=1
            return 1
        fi
    fi
    TRANSACTION_STARTED=0
    echo "Previous installation restored." >&2
    return 0
}

finish() {
    MDB_EXIT_STATUS=$1
    trap - EXIT HUP INT TERM
    if [ "$MDB_EXIT_STATUS" -ne 0 ] && \
       [ "$TRANSACTION_STARTED" -eq 1 ] && \
       [ "$INSTALL_COMMITTED" -eq 0 ]; then
        if ! rollback_install; then
            KEEP_BACKUP=1
            echo "Automatic rollback was incomplete. Recovery files were kept in:" >&2
            echo "  $BACKUP_DIR" >&2
        fi
    fi
    cleanup
    exit "$MDB_EXIT_STATUS"
}

trap 'finish $?' EXIT
trap 'exit 130' HUP INT TERM

mkdir -p "$SUPPORT_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
BACKUP_DIR=$(mktemp -d "$SUPPORT_DIR/.install-backup.XXXXXX")
OLD_HAD_BINARY=0
OLD_HAD_CONFIG=0
OLD_HAD_PLIST=0
OLD_JOB_WAS_LOADED=0
[ -f "$INSTALLED_BINARY" ] && OLD_HAD_BINARY=1
[ -f "$CONFIG_PATH" ] && OLD_HAD_CONFIG=1
[ -f "$LAUNCH_AGENT" ] && OLD_HAD_PLIST=1
job_is_loaded && OLD_JOB_WAS_LOADED=1

if [ "$OLD_JOB_WAS_LOADED" -eq 1 ] && [ "$OLD_HAD_PLIST" -ne 1 ]; then
    echo "The existing job is loaded but its LaunchAgent plist is missing; installation aborted." >&2
    exit 6
fi
if [ "$OLD_JOB_WAS_LOADED" -eq 1 ] && ! job_is_running; then
    echo "The existing LaunchAgent is loaded but not running; installation was not changed." >&2
    echo "Repair or uninstall the existing service before upgrading." >&2
    exit 7
fi
if [ "$OLD_JOB_WAS_LOADED" -eq 1 ] && \
   { [ ! -x "$INSTALLED_BINARY" ] || [ ! -f "$CONFIG_PATH" ]; }; then
    echo "The existing job is running without a complete binary/configuration pair." >&2
    echo "Installation was not changed; repair the existing files before upgrading." >&2
    exit 7
fi
if [ "$OLD_JOB_WAS_LOADED" -eq 1 ] && ! loaded_installation_is_restartable; then
    echo "The running installation cannot be safely restarted from its on-disk files." >&2
    echo "Installation was not changed; repair its config/plist before upgrading." >&2
    exit 7
fi
if [ -f "$STATE_PATH" ] && [ ! -x "$INSTALLED_BINARY" ]; then
    echo "Managed recovery state exists but its recovery binary is missing." >&2
    echo "Installation was not changed; keep any running service and use the brightness-up key." >&2
    exit 7
fi
[ "$OLD_HAD_BINARY" -eq 0 ] || cp -p "$INSTALLED_BINARY" "$BACKUP_DIR/binary"
[ "$OLD_HAD_CONFIG" -eq 0 ] || cp -p "$CONFIG_PATH" "$BACKUP_DIR/config.json"
[ "$OLD_HAD_PLIST" -eq 0 ] || cp -p "$LAUNCH_AGENT" "$BACKUP_DIR/LaunchAgent.plist"

TRANSACTION_STARTED=1
if ! stop_job; then
    echo "Could not stop the existing LaunchAgent; installation aborted." >&2
    exit 6
fi

if [ -f "$STATE_PATH" ]; then
    if [ -x "$INSTALLED_BINARY" ]; then
        if ! MDB_CONFIG_PATH="$CONFIG_PATH" MDB_STATE_PATH="$STATE_PATH" \
            "$INSTALLED_BINARY" --restore; then
            echo "The previous installation could not restore the built-in display; update aborted." >&2
            exit 7
        fi
    else
        echo "Managed recovery state exists but its recovery binary is missing; install aborted." >&2
        echo "Use the brightness-up key and repair or remove the previous installation first." >&2
        exit 7
    fi
fi

if [ -n "$CONFIG_CANDIDATE" ]; then
    CONFIG_TEMP=$(mktemp "$SUPPORT_DIR/.config.json.XXXXXX")
    install -m 600 "$CONFIG_CANDIDATE" "$CONFIG_TEMP"
    mv -f "$CONFIG_TEMP" "$CONFIG_PATH"
fi

MDB_CONFIG_PATH="$CONFIG_PATH" "$BUILD_BINARY" --validate-config

BINARY_TEMP=$(mktemp "$SUPPORT_DIR/.macbook-dock-brightness.XXXXXX")
PLIST_TEMP=$(mktemp "$HOME/Library/LaunchAgents/.macbook-dock-brightness.XXXXXX")

install -m 755 "$BUILD_BINARY" "$BINARY_TEMP"
mv -f "$BINARY_TEMP" "$INSTALLED_BINARY"

xml_escape() {
    printf '%s' "$1" | sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&apos;/g"
}

sed_escape() {
    printf '%s' "$1" | sed -e 's/[&|]/\\&/g'
}

PROGRAM_VALUE=$(sed_escape "$(xml_escape "$INSTALLED_BINARY")")
LOG_VALUE=$(sed_escape "$(xml_escape "$LOG_PATH")")
ERROR_LOG_VALUE=$(sed_escape "$(xml_escape "$ERROR_LOG_PATH")")

sed \
    -e "s|__PROGRAM_PATH__|$PROGRAM_VALUE|g" \
    -e "s|__LOG_PATH__|$LOG_VALUE|g" \
    -e "s|__ERROR_LOG_PATH__|$ERROR_LOG_VALUE|g" \
    "$PROJECT_ROOT/LaunchAgent.plist.template" > "$PLIST_TEMP"
plutil -lint "$PLIST_TEMP" >/dev/null
mv -f "$PLIST_TEMP" "$LAUNCH_AGENT"

if [ "$NO_START" -eq 0 ]; then
    BOOTSTRAP_OK=1
    /bin/launchctl bootstrap "$USER_DOMAIN" "$LAUNCH_AGENT" || BOOTSTRAP_OK=0
    if [ "$BOOTSTRAP_OK" -ne 1 ] || ! wait_for_job_running; then
        echo "LaunchAgent failed to stay running." >&2
        exit 6
    fi
    sleep 1
    if ! job_is_running || ! MDB_CONFIG_PATH="$CONFIG_PATH" \
        "$INSTALLED_BINARY" --status; then
        echo "LaunchAgent health verification failed." >&2
        exit 6
    fi
fi

INSTALL_COMMITTED=1
TRANSACTION_STARTED=0
trap - EXIT HUP INT TERM
cleanup

echo "Installed MacBook Dock Brightness."
echo "Configuration: $CONFIG_PATH"
echo "LaunchAgent: $LAUNCH_AGENT"
if [ "$NO_START" -eq 0 ]; then
    echo "The LaunchAgent is running and passed its initial status check."
else
    echo "The LaunchAgent was not started (--no-start)."
fi
