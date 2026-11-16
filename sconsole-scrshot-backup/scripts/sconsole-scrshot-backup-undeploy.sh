#!/bin/bash
# =============================================================================
# sconsole-scrshot-backup-undeploy.sh
#
# Purpose:
#   Stops the backup and status launchd jobs and removes them from
#   ~/Library/LaunchAgents, removes the three links from ~/softwares/bin/scripts/,
#   and removes the /screenshots/ page from the Caddy site. The project,
#   target/, the logs, the backed-up screenshots and their browsing pages are
#   left alone.
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
LABELS=("com.sandeep.$NAME" "com.sandeep.$NAME-status")
LINKS=("$HOME/softwares/bin/scripts/$NAME" "$HOME/softwares/bin/scripts/$NAME-status"
       "$HOME/softwares/bin/scripts/$NAME-gallery")
SITE_DIR="$HOME/softwares/workspace/caddy/site/screenshots"

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
#   Purpose : Stop a job if it is loaded and delete its plist.
#   Input   : $1 - job label
#   Output  : job unloaded; its LaunchAgents plist removed
# -----------------------------------------------------------------------------
remove_agent() {
    launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$1.plist"
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
#   Purpose : Delete the status page, its JSON and the gallery link from the
#             Caddy site (the linked backup folder itself is untouched).
#   Input   : globals SITE_DIR
#   Output  : SITE_DIR removed
# -----------------------------------------------------------------------------
remove_page() {
    if [[ -L $SITE_DIR/gallery ]]; then
        rm -f "$SITE_DIR/gallery"
    fi
    rm -f "$SITE_DIR/index.html" "$SITE_DIR/status.json" "$SITE_DIR/status.json.tmp"
    rmdir "$SITE_DIR" 2>/dev/null || true
}

# --- main ---
parse_args "$@"
for label in "${LABELS[@]}"; do
    remove_agent "$label"
done
for link in "${LINKS[@]}"; do
    remove_link "$link"
done
remove_page
echo "Undeployed $NAME"
