#!/bin/bash
# =============================================================================
# db-backup-undeploy.sh
#
# Purpose:
#   Stops the backup LaunchDaemon and the status LaunchAgent and removes their
#   plists, removes the two links from ~/softwares/bin/scripts/, and removes
#   the /backups/ page from the Caddy site. Uses sudo for the daemon, so run it
#   from a terminal. The project, target/, the workspace (logs and the restic
#   repository), the configs and the local live copies are left alone.
#
# Usage:
#   db-backup-undeploy.sh
#
# Parameters:
#   /?, -h, --help  Print this help and exit.
#
# Exit codes:
#   0  undeployed (or was not deployed)
#   1  sudo failed
#   2  bad arguments
# =============================================================================
set -euo pipefail

NAME=db-backup
LABEL="com.sandeep.$NAME"
STATUS_LABEL="com.sandeep.$NAME-status"
LINKS=("$HOME/softwares/bin/scripts/$NAME" "$HOME/softwares/bin/scripts/$NAME-status")
SITE_DIR="$HOME/softwares/workspace/caddy/site/backups"

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
# remove_daemon
#   Purpose : Stop the backup daemon if it is loaded and delete its plist.
#   Input   : globals LABEL
#   Output  : daemon unloaded; its LaunchDaemons plist removed
# -----------------------------------------------------------------------------
remove_daemon() {
    sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
    sudo rm -f "/Library/LaunchDaemons/$LABEL.plist"
}

# -----------------------------------------------------------------------------
# remove_agent
#   Purpose : Stop the status job if it is loaded and delete its plist.
#   Input   : globals STATUS_LABEL
#   Output  : job unloaded; its LaunchAgents plist removed
# -----------------------------------------------------------------------------
remove_agent() {
    launchctl bootout "gui/$(id -u)/$STATUS_LABEL" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$STATUS_LABEL.plist"
}

# -----------------------------------------------------------------------------
# remove_link
#   Purpose : Delete a PATH link, if it is a symlink.
#   Input   : $1 - link path
#   Output  : link removed; a real file at that path is left alone
# -----------------------------------------------------------------------------
remove_link() {
    if [[ -L $1 ]]; then
        rm -f "$1"
    fi
}

# -----------------------------------------------------------------------------
# remove_page
#   Purpose : Delete the status page and its JSON from the Caddy site.
#   Input   : globals SITE_DIR
#   Output  : SITE_DIR removed
# -----------------------------------------------------------------------------
remove_page() {
    rm -f "$SITE_DIR/index.html" "$SITE_DIR/status.json" "$SITE_DIR/status.json.tmp"
    rmdir "$SITE_DIR" 2>/dev/null || true
}

# --- main ---
parse_args "$@"
remove_daemon
remove_agent
for link in "${LINKS[@]}"; do
    remove_link "$link"
done
remove_page
echo "Undeployed $NAME"
