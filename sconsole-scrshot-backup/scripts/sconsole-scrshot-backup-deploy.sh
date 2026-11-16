#!/bin/bash
# =============================================================================
# sconsole-scrshot-backup-deploy.sh
#
# Purpose:
#   Deploys the screenshot backup and its web status page:
#     1. links the scripts into ~/softwares/bin/scripts/ (on PATH) as
#        "sconsole-scrshot-backup", "sconsole-scrshot-backup-status" and
#        "sconsole-scrshot-backup-gallery"
#     2. copies the status page into the Caddy site as /screenshots/, and
#        links the backup folder there as /screenshots/gallery/ so the page
#        can open the browsing pages (Caddy's file_server follows symlinks)
#     3. installs the two launchd jobs built in target/ into
#        ~/Library/LaunchAgents and (re)starts them. Loading the backup job
#        runs a backup straight away, then once per interval.
#   Run the build script first.
#
# Usage:
#   sconsole-scrshot-backup-deploy.sh
#
# Parameters:
#   /?, -h, --help  Print this help and exit.
#
# Exit codes:
#   0  deployed
#   1  target/ not built, a link name is taken by a real file, or launchctl
#      failed
#   2  bad arguments
# =============================================================================
set -euo pipefail

NAME=sconsole-scrshot-backup
LABELS=("com.sandeep.$NAME-status" "com.sandeep.$NAME")
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HOME/softwares/bin/scripts"
SITE_DIR="$HOME/softwares/workspace/caddy/site/screenshots"
LOCAL_DIR="$HOME/projects/workspace/sconsole/sconsole-screenshots"
WS="$HOME/softwares/workspace/$NAME"
DOMAIN="gui/$(id -u)"

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
#   Purpose : Copy the status page into the Caddy site folder and link the
#             backup folder (with its browsing pages) beside it.
#   Input   : globals PROJECT_DIR, SITE_DIR, LOCAL_DIR
#   Output  : SITE_DIR/index.html written; SITE_DIR/gallery -> LOCAL_DIR
#             (status.json is left to the status job)
# -----------------------------------------------------------------------------
publish_page() {
    mkdir -p "$SITE_DIR"
    cp "$PROJECT_DIR/src/main/web/index.html" "$SITE_DIR/index.html"
    ln -sfn "$LOCAL_DIR" "$SITE_DIR/gallery"
}

# -----------------------------------------------------------------------------
# install_agent
#   Purpose : Stop any running copy of a job, install its plist and start it.
#   Input   : $1 - job label; globals PROJECT_DIR, DOMAIN
#   Output  : ~/Library/LaunchAgents/<label>.plist written; job loaded;
#             returns launchctl's exit code
# -----------------------------------------------------------------------------
install_agent() {
    local label="$1"
    local agent="$HOME/Library/LaunchAgents/$label.plist"
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    mkdir -p "$(dirname "$agent")"
    cp "$PROJECT_DIR/target/$label.plist" "$agent"
    launchctl bootstrap "$DOMAIN" "$agent"
}

# --- main ---
parse_args "$@"
for label in "${LABELS[@]}"; do
    if [[ ! -f $PROJECT_DIR/target/$label.plist ]]; then
        echo "No target/$label.plist; run scripts/$NAME-build.sh first" >&2
        exit 1
    fi
done
mkdir -p "$WS/logs" "$WS/work"
touch "$WS/status"
link_script "$PROJECT_DIR/scripts/$NAME.sh" "$BIN/$NAME"
link_script "$PROJECT_DIR/src/main/python/$NAME-status.py" "$BIN/$NAME-status"
link_script "$PROJECT_DIR/src/main/python/$NAME-gallery.py" "$BIN/$NAME-gallery"
publish_page
for label in "${LABELS[@]}"; do
    install_agent "$label"
done
echo "Deployed $NAME"
echo "  commands: $BIN/$NAME, $BIN/$NAME-status, $BIN/$NAME-gallery"
echo "  page:     http://localhost/screenshots/"
echo "  logs:     $WS/logs/"
