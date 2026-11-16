#!/bin/bash
# =============================================================================
# sconsole-scrshot-backup-undeploy.sh
#
# Purpose:
#   Stops the launchd job, removes it from ~/Library/LaunchAgents, and
#   removes the "sconsole-scrshot-backup" link from ~/softwares/bin/scripts/.
#   The project, target/ and the backed-up screenshots are left alone.
#
# Usage:
#   sconsole-scrshot-backup-undeploy.sh
#
# Parameters:
#   /?, -h, --help  Print this help and exit.
#
# Exit codes:
#   0  undeployed (or was not deployed)
#   2  bad arguments
# =============================================================================
set -euo pipefail

NAME=sconsole-scrshot-backup
LABEL="com.sandeep.$NAME"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
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
# remove_agent
#   Purpose : Stop the job if it is loaded and delete its plist.
#   Input   : globals LABEL, AGENT
#   Output  : job unloaded; AGENT file removed
# -----------------------------------------------------------------------------
remove_agent() {
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$AGENT"
}

# -----------------------------------------------------------------------------
# remove_link
#   Purpose : Delete the PATH link, if it is a symlink.
#   Input   : globals LINK
#   Output  : LINK removed; a real file at LINK is left alone
# -----------------------------------------------------------------------------
remove_link() {
    if [[ -L $LINK ]]; then
        rm -f "$LINK"
    fi
}

# --- main ---
parse_args "$@"
remove_agent
remove_link
echo "Undeployed $LABEL"
