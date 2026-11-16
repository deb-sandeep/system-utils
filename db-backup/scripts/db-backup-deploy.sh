#!/bin/bash
# =============================================================================
# db-backup-deploy.sh
#
# Purpose:
#   Deploys the database backup and its web status page:
#     1. removes the pre-project setup if it is still there: the jobs
#        local.db-backup and local.backup-status, and the copied scripts
#        ~/softwares/bin/scripts/db-backup and backup-status
#     2. links the scripts into ~/softwares/bin/scripts/ (on PATH) as
#        "db-backup" and "db-backup-status"
#     3. copies the status page into the Caddy site as /backups/
#     4. installs the status LaunchAgent and the backup LaunchDaemon built in
#        target/ and (re)starts them. The daemon runs as root, so this step
#        uses sudo: run the script from a terminal. Loading the daemon does not
#        run a backup; it waits for 02:00.
#   Run the build script first. Leaves the workspace (logs, restic repository)
#   and the configs in ~/softwares/logncfgs/db-backup/ alone.
#
# Usage:
#   db-backup-deploy.sh
#
# Parameters:
#   /?, -h, --help  Print this help and exit.
#
# Exit codes:
#   0  deployed
#   1  target/ not built, a link name is taken by a real file, or
#      launchctl/sudo failed
#   2  bad arguments
# =============================================================================
set -euo pipefail

NAME=db-backup
LABEL="com.sandeep.$NAME"
STATUS_LABEL="com.sandeep.$NAME-status"
LEGACY_DAEMON=local.db-backup
LEGACY_AGENT=local.backup-status
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HOME/softwares/bin/scripts"
SITE_DIR="$HOME/softwares/workspace/caddy/site/backups"
WS="$HOME/softwares/workspace/$NAME"
USER_DOMAIN="gui/$(id -u)"

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
# remove_legacy
#   Purpose : Remove the setup that predates this project: its two jobs and
#             the plain-file copies of the scripts that the links replace.
#   Input   : globals LEGACY_DAEMON, LEGACY_AGENT, BIN, USER_DOMAIN
#   Output  : legacy jobs unloaded and their plists deleted; legacy script
#             files deleted (symlinks are left for link_script); each removal
#             is reported on stdout
# -----------------------------------------------------------------------------
remove_legacy() {
    local f
    if [[ -f /Library/LaunchDaemons/$LEGACY_DAEMON.plist ]]; then
        sudo launchctl bootout "system/$LEGACY_DAEMON" 2>/dev/null || true
        sudo rm -f "/Library/LaunchDaemons/$LEGACY_DAEMON.plist"
        echo "  removed old daemon $LEGACY_DAEMON"
    fi
    if [[ -f $HOME/Library/LaunchAgents/$LEGACY_AGENT.plist ]]; then
        launchctl bootout "$USER_DOMAIN/$LEGACY_AGENT" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/$LEGACY_AGENT.plist"
        echo "  removed old agent $LEGACY_AGENT"
    fi
    for f in "$BIN/db-backup" "$BIN/backup-status"; do
        if [[ -f $f && ! -L $f ]]; then
            rm -f "$f"
            echo "  removed old script $f"
        fi
    done
}

# -----------------------------------------------------------------------------
# link_script
#   Purpose : Point a PATH link at a project script, replacing an old link.
#   Input   : $1 - script path; $2 - link path
#   Output  : symlink created; returns 1 if the link path is a real file,
#             which is left alone
# -----------------------------------------------------------------------------
link_script() {
    local script="$1" link="$2"
    if [[ -e $link && ! -L $link ]]; then
        echo "$link exists and is not a symlink; not replacing it" >&2
        return 1
    fi
    chmod +x "$script"
    mkdir -p "$(dirname "$link")"
    ln -sfn "$script" "$link"
}

# -----------------------------------------------------------------------------
# publish_page
#   Purpose : Copy the status page into the Caddy site folder.
#   Input   : globals PROJECT_DIR, SITE_DIR
#   Output  : SITE_DIR/index.html written (status.json is left to the status
#             job)
# -----------------------------------------------------------------------------
publish_page() {
    mkdir -p "$SITE_DIR"
    cp "$PROJECT_DIR/src/main/web/index.html" "$SITE_DIR/index.html"
}

# -----------------------------------------------------------------------------
# install_agent
#   Purpose : Stop any running copy of the status job, install its plist and
#             start it.
#   Input   : globals STATUS_LABEL, PROJECT_DIR, USER_DOMAIN
#   Output  : ~/Library/LaunchAgents/<label>.plist written; job loaded;
#             returns launchctl's exit code
# -----------------------------------------------------------------------------
install_agent() {
    local agent="$HOME/Library/LaunchAgents/$STATUS_LABEL.plist"
    launchctl bootout "$USER_DOMAIN/$STATUS_LABEL" 2>/dev/null || true
    mkdir -p "$(dirname "$agent")"
    cp "$PROJECT_DIR/target/$STATUS_LABEL.plist" "$agent"
    launchctl bootstrap "$USER_DOMAIN" "$agent"
}

# -----------------------------------------------------------------------------
# install_daemon
#   Purpose : Stop any loaded copy of the backup daemon, install its plist
#             (owned by root, as launchd requires) and load it.
#   Input   : globals LABEL, PROJECT_DIR
#   Output  : /Library/LaunchDaemons/<label>.plist written; job loaded;
#             returns non-zero if sudo or launchctl failed
# -----------------------------------------------------------------------------
install_daemon() {
    local daemon="/Library/LaunchDaemons/$LABEL.plist"
    sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
    sudo install -m 644 -o root -g wheel "$PROJECT_DIR/target/$LABEL.plist" "$daemon"
    sudo launchctl bootstrap system "$daemon"
}

# --- main ---
parse_args "$@"
for label in "$LABEL" "$STATUS_LABEL"; do
    if [[ ! -f $PROJECT_DIR/target/$label.plist ]]; then
        echo "No target/$label.plist; run scripts/$NAME-build.sh first" >&2
        exit 1
    fi
done
echo "sudo is needed for the root LaunchDaemon; it may ask for your password."
sudo -v
mkdir -p "$WS/logs" "$WS/work"
touch "$WS/status"
remove_legacy
link_script "$PROJECT_DIR/scripts/$NAME.sh" "$BIN/$NAME"
link_script "$PROJECT_DIR/src/main/python/$NAME-status.py" "$BIN/$NAME-status"
publish_page
install_agent
install_daemon
echo "Deployed $NAME"
echo "  commands: $BIN/$NAME, $BIN/$NAME-status"
echo "  page:     http://localhost/backups/"
echo "  logs:     $WS/logs/"
echo "  run now:  sudo launchctl kickstart system/$LABEL"
