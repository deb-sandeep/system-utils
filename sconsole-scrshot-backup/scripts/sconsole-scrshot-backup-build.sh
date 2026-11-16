#!/bin/bash
# =============================================================================
# sconsole-scrshot-backup-build.sh
#
# Purpose:
#   Checks the project's scripts for syntax errors (and with shellcheck, when
#   installed), then rebuilds target/ with the launchd job definition. The job
#   runs the backup through its link in ~/softwares/bin/scripts/, which the
#   deploy script creates.
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
INTERVAL_SEC=3600
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$PROJECT_DIR/target"
LINK="$HOME/softwares/bin/scripts/$NAME"

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
#   Purpose : Syntax-check every script in scripts/, plus shellcheck if present.
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
}

# -----------------------------------------------------------------------------
# write_plist
#   Purpose : Write and validate the launchd job definition.
#   Input   : $1 - output path; globals LABEL, NAME, LINK, INTERVAL_SEC
#   Output  : the plist file; returns non-zero if plutil rejects it
# -----------------------------------------------------------------------------
write_plist() {
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
        <string>$LINK</string>
    </array>
    <key>StartInterval</key>
    <integer>$INTERVAL_SEC</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/$NAME.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/$NAME.log</string>
</dict>
</plist>
EOF
    plutil -lint "$1" >/dev/null
}

# --- main ---
parse_args "$@"
check_scripts
rm -rf "$TARGET"
mkdir -p "$TARGET"
write_plist "$TARGET/$LABEL.plist"
echo "Built $TARGET (runs every ${INTERVAL_SEC}s)"
