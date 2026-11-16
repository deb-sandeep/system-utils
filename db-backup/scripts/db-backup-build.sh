#!/bin/bash
# =============================================================================
# db-backup-build.sh
#
# Purpose:
#   Checks the project's scripts for syntax errors (and with shellcheck, when
#   installed), then rebuilds target/ with the two launchd job definitions:
#     com.sandeep.db-backup         - LaunchDaemon (runs as root): the backup,
#                                     nightly at 02:00
#     com.sandeep.db-backup-status  - LaunchAgent: rebuilds the web status
#       JSON when the backup's status file or lock changes, and every 15 min
#   Both jobs run their script through its link in ~/softwares/bin/scripts/,
#   which the deploy script creates. The backup's hour is also SCHEDULE_HOUR
#   in db-backup-status.py; change both together.
#
# Usage:
#   db-backup-build.sh
#
# Parameters:
#   /?, -h, --help  Print this help and exit.
#
# Exit codes:
#   0  built
#   1  a check failed
#   2  bad arguments
# =============================================================================
set -euo pipefail

NAME=db-backup
LABEL="com.sandeep.$NAME"
STATUS_LABEL="com.sandeep.$NAME-status"
HOUR=2
STATUS_INTERVAL_SEC=900
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$PROJECT_DIR/target"
BIN="$HOME/softwares/bin/scripts"
WS="$HOME/softwares/workspace/$NAME"

# -----------------------------------------------------------------------------
# print_usage
#   Purpose : Print the usage text from this script's header.
#   Input   : none
#   Output  : stdout - the header without comment markers
# -----------------------------------------------------------------------------
print_usage() {
    sed -n '3,/^# =====/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
}

# -----------------------------------------------------------------------------
# parse_args
#   Purpose : Handle the help flag and reject anything else.
#   Input   : "$@" - the script's arguments
#   Output  : on /? prints usage and exits 0; on any other argument prints
#             usage to stderr and exits 2
# -----------------------------------------------------------------------------
parse_args() {
    case "${1-}" in
        '')             ;;
        '/?'|-h|--help) print_usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; print_usage >&2; exit 2 ;;
    esac
}

# -----------------------------------------------------------------------------
# check_scripts
#   Purpose : Syntax-check every shell script in scripts/ (plus shellcheck if
#             present) and every Python file in src/main/python/.
#   Input   : globals PROJECT_DIR
#   Output  : errors on stderr; returns non-zero on the first failure
# -----------------------------------------------------------------------------
check_scripts() {
    local script
    for script in "$PROJECT_DIR"/scripts/*.sh; do
        bash -n "$script"
    done
    if command -v shellcheck >/dev/null; then
        shellcheck "$PROJECT_DIR"/scripts/*.sh
    fi
    for script in "$PROJECT_DIR"/src/main/python/*.py; do
        /usr/bin/python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$script"
    done
}

# -----------------------------------------------------------------------------
# write_backup_plist
#   Purpose : Write the LaunchDaemon that runs the backup as root every night
#             at HOUR:00. HOME and USER point at the owner's account, as the
#             script's paths and restic expect.
#   Input   : $1 - output path; globals LABEL, NAME, BIN, WS, HOUR, HOME, USER
#   Output  : the plist file
# -----------------------------------------------------------------------------
write_backup_plist() {
    cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$BIN/$NAME</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$HOUR</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>USER</key>
        <string>$USER</string>
        <key>LANG</key>
        <string>en_US.UTF-8</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>$HOME</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$WS/logs/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$WS/logs/launchd.log</string>
</dict>
</plist>
EOF
}

# -----------------------------------------------------------------------------
# write_status_plist
#   Purpose : Write the LaunchAgent that rebuilds the web status JSON when the
#             backup's status file or work/ folder (its lock) changes, and
#             every STATUS_INTERVAL_SEC.
#   Input   : $1 - output path; globals STATUS_LABEL, NAME, BIN, WS,
#             STATUS_INTERVAL_SEC
#   Output  : the plist file
# -----------------------------------------------------------------------------
write_status_plist() {
    cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$STATUS_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$BIN/$NAME-status</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>$WS/status</string>
        <string>$WS/work</string>
    </array>
    <key>StartInterval</key>
    <integer>$STATUS_INTERVAL_SEC</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$WS/logs/status.out</string>
    <key>StandardErrorPath</key>
    <string>$WS/logs/status.out</string>
</dict>
</plist>
EOF
}

# --- main ---
parse_args "$@"
check_scripts
rm -rf "$TARGET"
mkdir -p "$TARGET"
write_backup_plist "$TARGET/$LABEL.plist"
write_status_plist "$TARGET/$STATUS_LABEL.plist"
plutil -lint "$TARGET"/*.plist >/dev/null
echo "Built $TARGET (backup nightly at $(printf '%02d' "$HOUR"):00, status every ${STATUS_INTERVAL_SEC}s and on change)"
