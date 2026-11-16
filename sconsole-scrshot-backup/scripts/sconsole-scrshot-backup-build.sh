#!/bin/bash
# =============================================================================
# sconsole-scrshot-backup-build.sh
#
# Purpose:
#   Checks the project's scripts for syntax errors (and with shellcheck, when
#   installed), then rebuilds target/ with the two launchd job definitions:
#     com.sandeep.sconsole-scrshot-backup         - the backup, every interval
#     com.sandeep.sconsole-scrshot-backup-status  - rebuilds the web status
#       JSON when the backup's status file or lock changes, and every 15 min
#   Both jobs run their script through its link in ~/softwares/bin/scripts/,
#   which the deploy script creates.
#
# Usage:
#   sconsole-scrshot-backup-build.sh [options]
#
# Parameters:
#   --interval <sec>  How often launchd runs the backup. Default: 3600 (hourly)
#   /?, -h, --help    Print this help and exit.
#
# Exit codes:
#   0  built
#   1  a check failed
#   2  bad arguments
# =============================================================================
set -euo pipefail

NAME=sconsole-scrshot-backup
LABEL="com.sandeep.$NAME"
STATUS_LABEL="com.sandeep.$NAME-status"
INTERVAL_SEC=3600
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
#   Purpose : Read command-line options into the settings globals.
#   Input   : "$@" - the script's arguments
#   Output  : sets INTERVAL_SEC; on /? prints usage and exits 0; on a bad
#             argument prints usage to stderr and exits 2
# -----------------------------------------------------------------------------
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            '/?'|-h|--help) print_usage; exit 0 ;;
            --interval)     INTERVAL_SEC="${2:?}"; shift ;;
            *) echo "Unknown argument: $1" >&2; print_usage >&2; exit 2 ;;
        esac
        shift
    done
    if [[ ! $INTERVAL_SEC =~ ^[0-9]+$ ]] || (( INTERVAL_SEC < 60 )); then
        echo "--interval must be a whole number of seconds, at least 60" >&2
        exit 2
    fi
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
#   Purpose : Write the launchd job that runs the backup every INTERVAL_SEC.
#   Input   : $1 - output path; globals LABEL, NAME, BIN, WS, INTERVAL_SEC
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
    <key>StartInterval</key>
    <integer>$INTERVAL_SEC</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
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
#   Purpose : Write the launchd job that rebuilds the web status JSON when the
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
echo "Built $TARGET (backup every ${INTERVAL_SEC}s, status every ${STATUS_INTERVAL_SEC}s and on change)"
