#!/bin/bash
# =============================================================================
# sconsole-scrshot-backup.sh
#
# Purpose:
#   Pulls the screenshots sconsole writes on the remote host into month
#   folders (YYYY-MM/) under the local backup folder. Each file is staged in
#   <local-dir>/incoming/, checked against the remote SHA-256, filed into its
#   month folder, and only then deleted on the remote.
#
# Usage:
#   sconsole-scrshot-backup.sh [options]
#
# Parameters:
#   --host <alias>      SSH host (an ~/.ssh/config alias). Default: sconsole
#   --remote-dir <dir>  Screenshot folder on the remote, relative to its home.
#                       Default: projects/workspace/sconsole/screenshots
#   --local-dir <dir>   Local backup folder.
#                       Default: ~/projects/workspace/sconsole/sconsole-screenshots
#   --min-age <min>     Skip files modified in the last <min> minutes, which
#                       sconsole may still be writing. Default: 2
#   --keep-remote       Copy only; never delete anything on the remote.
#   /?, -h, --help      Print this help and exit.
#
# Exit codes:
#   0  success, or nothing to back up, or another run is in progress
#   1  some files failed checks (they stay on the remote)
#   2  bad arguments
# =============================================================================
set -euo pipefail

REMOTE_HOST=sconsole
REMOTE_DIR=projects/workspace/sconsole/screenshots
LOCAL_DIR="$HOME/projects/workspace/sconsole/sconsole-screenshots"
MIN_AGE_MIN=2
KEEP_REMOTE=0

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
# log
#   Purpose : Print a timestamped log line.
#   Input   : $* - message
#   Output  : stdout - "YYYY-MM-DD HH:MM:SS message"
# -----------------------------------------------------------------------------
log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*"
}

# -----------------------------------------------------------------------------
# parse_args
#   Purpose : Read command-line options into the settings globals.
#   Input   : "$@" - the script's arguments
#   Output  : sets REMOTE_HOST, REMOTE_DIR, LOCAL_DIR, MIN_AGE_MIN,
#             KEEP_REMOTE; on /? prints usage and exits 0; on a bad
#             argument prints usage to stderr and exits 2
# -----------------------------------------------------------------------------
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            '/?'|-h|--help) print_usage; exit 0 ;;
            --host)         REMOTE_HOST="${2:?}"; shift ;;
            --remote-dir)   REMOTE_DIR="${2:?}"; shift ;;
            --local-dir)    LOCAL_DIR="${2:?}"; shift ;;
            --min-age)      MIN_AGE_MIN="${2:?}"; shift ;;
            --keep-remote)  KEEP_REMOTE=1 ;;
            *) echo "Unknown argument: $1" >&2; print_usage >&2; exit 2 ;;
        esac
        shift
    done
    if [[ ! $MIN_AGE_MIN =~ ^[0-9]+$ ]]; then
        echo "--min-age must be a whole number of minutes" >&2
        exit 2
    fi
}

# -----------------------------------------------------------------------------
# acquire_lock
#   Purpose : Make sure only one backup runs at a time.
#   Input   : globals LOCK
#   Output  : creates the LOCK folder; returns 1 if another run holds it
# -----------------------------------------------------------------------------
acquire_lock() {
    mkdir "$LOCK" 2>/dev/null
}

# -----------------------------------------------------------------------------
# cleanup
#   Purpose : Remove temp files and release the lock (EXIT trap).
#   Input   : globals MANIFEST, NAMES, LOCK
#   Output  : none
# -----------------------------------------------------------------------------
cleanup() {
    rm -f "$MANIFEST" "$NAMES"
    rmdir "$LOCK" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# fetch_manifest
#   Purpose : List the remote screenshots that are old enough to copy,
#             with their SHA-256.
#   Input   : globals REMOTE_HOST, REMOTE_DIR, MIN_AGE_MIN
#   Output  : $1 - file written with "<sha256>  <name>" lines, sorted by name
#             $2 - file written with just the names, one per line
# -----------------------------------------------------------------------------
fetch_manifest() {
    local manifest="$1" names="$2"
    ssh "$REMOTE_HOST" "cd -- '$REMOTE_DIR' && find . -maxdepth 1 -type f -name '*.png' -mmin +$MIN_AGE_MIN -printf '%f\0' | sort -z | xargs -0 -r sha256sum" > "$manifest"
    cut -c67- "$manifest" > "$names"
}

# -----------------------------------------------------------------------------
# pull_files
#   Purpose : Copy the listed remote files into the staging folder.
#   Input   : $1 - file listing the names to copy; globals REMOTE_HOST,
#             REMOTE_DIR, STAGING
#   Output  : files in STAGING; returns rsync's exit code
# -----------------------------------------------------------------------------
pull_files() {
    rsync -t --partial --timeout=120 --files-from="$1" "$REMOTE_HOST:$REMOTE_DIR/" "$STAGING/"
}

# -----------------------------------------------------------------------------
# file_screenshot
#   Purpose : Check one staged file against its remote checksum and move it
#             into its month folder.
#   Input   : $1 - expected SHA-256; $2 - file name ("YYYY-MM-DD HHMMSS.png");
#             globals STAGING, LOCAL_DIR
#   Output  : file moved to LOCAL_DIR/YYYY-MM/; returns 0 when the file is
#             safely in place (so the remote copy may go), 1 otherwise
# -----------------------------------------------------------------------------
file_screenshot() {
    local hash="$1" name="$2"
    local src="$STAGING/$name" month="${2:0:7}"
    local dest="$LOCAL_DIR/$month/$name"

    if [[ ! -f $src ]]; then
        log "missing after transfer: $name"; return 1
    fi
    if [[ $(shasum -a 256 "$src" | cut -c1-64) != "$hash" ]]; then
        log "checksum mismatch, discarded: $name"; rm -f "$src"; return 1
    fi
    if [[ ! $month =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        log "unexpected name, left in incoming: $name"; return 1
    fi
    mkdir -p "$LOCAL_DIR/$month"
    if [[ -e $dest ]]; then
        if ! cmp -s "$src" "$dest"; then
            log "different file already at $dest, left in incoming"; return 1
        fi
        rm -f "$src"
    else
        mv -n "$src" "$dest"
    fi
}

# -----------------------------------------------------------------------------
# delete_remote
#   Purpose : Delete files on the remote that are safely backed up.
#   Input   : "$@" - file names; globals REMOTE_HOST, REMOTE_DIR
#   Output  : files removed on the remote; returns ssh's exit code
# -----------------------------------------------------------------------------
delete_remote() {
    printf '%s\0' "$@" | ssh "$REMOTE_HOST" "cd -- '$REMOTE_DIR' && xargs -0 -r rm -f --"
}

# --- main ---
parse_args "$@"

STAGING="$LOCAL_DIR/incoming"
LOCK="$LOCAL_DIR/.backup.lock"
mkdir -p "$STAGING"
if ! acquire_lock; then
    log "another run holds $LOCK; exiting"
    exit 0
fi
MANIFEST="$(mktemp)"
NAMES="$(mktemp)"
trap cleanup EXIT

fetch_manifest "$MANIFEST" "$NAMES"
if [[ ! -s $MANIFEST ]]; then
    log "nothing to back up"
    exit 0
fi
log "pulling $(wc -l < "$NAMES" | tr -d ' ') file(s) from $REMOTE_HOST"
pull_files "$NAMES"

status=0
filed=()
while IFS= read -r line; do
    if file_screenshot "${line:0:64}" "${line:66}"; then
        filed+=("${line:66}")
    else
        status=1
    fi
done < "$MANIFEST"

if (( ${#filed[@]} == 0 )); then
    log "no files backed up"
    exit 1
fi
if (( KEEP_REMOTE )); then
    log "backed up ${#filed[@]} file(s); --keep-remote, remote left as is"
else
    delete_remote "${filed[@]}"
    log "backed up ${#filed[@]} file(s) and deleted them from $REMOTE_HOST"
fi
exit $status
