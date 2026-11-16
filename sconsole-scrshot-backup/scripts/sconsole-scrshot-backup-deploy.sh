#!/bin/bash
# =============================================================================
# sconsole-scrshot-backup-deploy.sh
#
# Purpose:
#   Links the backup script into ~/softwares/bin/scripts/ (on PATH) as
#   "sconsole-scrshot-backup", then installs the launchd job built in target/
#   into ~/Library/LaunchAgents and (re)starts it. Loading the job runs a
#   backup straight away, then once per interval. Run the build script first.
#
# Usage:
#   sconsole-scrshot-backup-deploy.sh
#
# Parameters:
#   /?, -h, --help  Print this help and exit.
#
# Exit codes:
#   0  deployed
#   1  target/ not built, or launchctl failed
#   2  bad arguments
# =============================================================================
set -euo pipefail

NAME=sconsole-scrshot-backup
LABEL="com.sandeep.$NAME"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$PROJECT_DIR/scripts/$NAME.sh"
LINK="$HOME/softwares/bin/scripts/$NAME"
PLIST="$PROJECT_DIR/target/$LABEL.plist"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
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
#   Purpose : Point the PATH link at the backup script, replacing an old link.
#   Input   : globals SCRIPT, LINK
#   Output  : LINK symlink created; returns 1 if LINK is a real file, which
#             is left alone
# -----------------------------------------------------------------------------
link_script() {
    if [[ -e $LINK && ! -L $LINK ]]; then
        echo "$LINK exists and is not a symlink; not replacing it" >&2
        return 1
    fi
    chmod +x "$SCRIPT"
    mkdir -p "$(dirname "$LINK")"
    ln -sfn "$SCRIPT" "$LINK"
}

# -----------------------------------------------------------------------------
# install_agent
#   Purpose : Stop any running copy of the job, install the new plist and
#             start it.
#   Input   : globals PLIST, AGENT, DOMAIN, LABEL
#   Output  : AGENT file written; job loaded; returns launchctl's exit code
# -----------------------------------------------------------------------------
install_agent() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    mkdir -p "$(dirname "$AGENT")"
    cp "$PLIST" "$AGENT"
    launchctl bootstrap "$DOMAIN" "$AGENT"
}

# --- main ---
parse_args "$@"
if [[ ! -f $PLIST ]]; then
    echo "No $PLIST; run scripts/$NAME-build.sh first" >&2
    exit 1
fi
link_script
install_agent
echo "Deployed $LABEL"
echo "  command: $LINK -> $SCRIPT"
echo "  log:     ~/Library/Logs/$NAME.log"
