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
#   Each run is logged to ~/softwares/workspace/sconsole-scrshot-backup/logs/
#   YYYY-MM-DD.log between "=== sconsole-scrshot-backup start" and
#   "=== sconsole-scrshot-backup OK|FINISHED WITH ERRORS" lines, and the result
#   is written to the workspace's status file. sconsole-scrshot-backup-status
#   turns these into the web status page. Every run ends by running
#   sconsole-scrshot-backup-gallery, which brings the browsing pages
#   (<local-dir>/index.html and the month/week pages) up to date; it only
#   rewrites pages whose screenshots changed.
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
#   1  the run finished with errors (failed files stay on the remote)
#   2  bad arguments
# =============================================================================
set -euo pipefail

NAME=sconsole-scrshot-backup
LABEL="com.sandeep.$NAME"
REMOTE_HOST=sconsole
REMOTE_DIR=projects/workspace/sconsole/screenshots
LOCAL_DIR="$HOME/projects/workspace/sconsole/sconsole-screenshots"
MIN_AGE_MIN=2
KEEP_REMOTE=0

WS="$HOME/softwares/workspace/$NAME"
LOG_DIR="$WS/logs"
WORK="$WS/work"
STATUS="$WS/status"
LOCK="$WORK/.lock"
LOG_KEEP_DAYS=90
GALLERY="$HOME/softwares/bin/scripts/$NAME-gallery"

STARTED=0        # set once the start marker is logged
FINISHED=0       # set once the end marker is logged
ERRORS=()        # run-level problems, for the end marker
FILED=()         # names safely in their month folder
FILED_BYTES=0

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
# init_logging
#   Purpose : Send all further output (including ssh/rsync errors) to today's
#             log file as well as stdout, and delete logs past LOG_KEEP_DAYS.
#   Input   : globals LOG_DIR, WORK, LOG_KEEP_DAYS
#   Output  : creates LOG_DIR and WORK; redirects stdout and stderr
# -----------------------------------------------------------------------------
init_logging() {
    mkdir -p "$LOG_DIR" "$WORK"
    exec > >(tee -a "$LOG_DIR/$(date +%F).log") 2>&1
    find "$LOG_DIR" -name '????-??-??.log' -mtime +"$LOG_KEEP_DAYS" -delete
}

# -----------------------------------------------------------------------------
# trigger
#   Purpose : Tell a scheduled run from a manual one.
#   Input   : env XPC_SERVICE_NAME (set by launchd to the job label)
#   Output  : stdout - "scheduled" or "manual"
# -----------------------------------------------------------------------------
trigger() {
    if [[ ${XPC_SERVICE_NAME:-} == "$LABEL" ]]; then
        echo scheduled
    else
        echo manual
    fi
}

# -----------------------------------------------------------------------------
# acquire_lock
#   Purpose : Make sure only one backup runs at a time. The status page also
#             reads the lock to show a run in progress.
#   Input   : globals LOCK
#   Output  : creates the LOCK folder; returns 1 if another run holds it
# -----------------------------------------------------------------------------
acquire_lock() {
    mkdir "$LOCK" 2>/dev/null
}

# -----------------------------------------------------------------------------
# finish
#   Purpose : Bring the browsing pages up to date, then log the end marker,
#             write the status file and exit.
#   Input   : globals ERRORS, FILED, NAME, STATUS
#   Output  : gallery refreshed; end marker logged; STATUS rewritten; exits
#             0 (OK) or 1 (errors)
# -----------------------------------------------------------------------------
finish() {
    FINISHED=1
    if ! update_gallery; then
        ERRORS+=("gallery")
    fi
    if (( ${#ERRORS[@]} )); then
        log "=== $NAME FINISHED WITH ERRORS: ${ERRORS[*]}"
        printf '%s FAILED %s\n' "$(date '+%F %T')" "${ERRORS[*]}" > "$STATUS"
        exit 1
    fi
    log "=== $NAME OK: ${#FILED[@]} file(s)"
    printf '%s OK %s\n' "$(date '+%F %T')" "${#FILED[@]}" > "$STATUS"
    exit 0
}

# -----------------------------------------------------------------------------
# cleanup
#   Purpose : EXIT trap. Logs an end marker if the run stopped unexpectedly,
#             then removes temp files and releases the lock.
#   Input   : $? of the exiting script; globals STARTED, FINISHED, MANIFEST,
#             NAMES, LOCK
#   Output  : none
# -----------------------------------------------------------------------------
cleanup() {
    local rc=$?
    if (( STARTED && ! FINISHED )); then
        ERRORS+=("aborted(exit-$rc)")
        ( finish ) || true
    fi
    rm -f "${MANIFEST-}" "${NAMES-}"
    rmdir "$LOCK" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# fetch_manifest
#   Purpose : List the remote screenshots that are old enough to copy,
#             with their SHA-256.
#   Input   : globals REMOTE_HOST, REMOTE_DIR, MIN_AGE_MIN
#   Output  : $1 - file written with "<sha256>  <name>" lines, sorted by name
#             $2 - file written with just the names, one per line
#             returns non-zero if the remote could not be listed
# -----------------------------------------------------------------------------
fetch_manifest() {
    local manifest="$1" names="$2"
    ssh "$REMOTE_HOST" "cd -- '$REMOTE_DIR' && find . -maxdepth 1 -type f -name '*.png' -mmin +$MIN_AGE_MIN -printf '%f\0' | sort -z | xargs -0 -r sha256sum" > "$manifest" || return 1
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
#   Output  : file moved to LOCAL_DIR/YYYY-MM/; adds its size to FILED_BYTES;
#             returns 0 when the file is safely in place (so the remote copy
#             may go), 1 otherwise (with a "FAILED <name>: ..." log line)
# -----------------------------------------------------------------------------
file_screenshot() {
    local hash="$1" name="$2"
    local src="$STAGING/$name" month="${2:0:7}"
    local dest="$LOCAL_DIR/$month/$name"

    if [[ ! -f $src ]]; then
        log "FAILED $name: missing after transfer"; return 1
    fi
    if [[ $(shasum -a 256 "$src" | cut -c1-64) != "$hash" ]]; then
        log "FAILED $name: checksum mismatch, discarded"; rm -f "$src"; return 1
    fi
    if [[ ! $month =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        log "FAILED $name: unexpected name, left in incoming"; return 1
    fi
    mkdir -p "$LOCAL_DIR/$month"
    if [[ -e $dest ]]; then
        if ! cmp -s "$src" "$dest"; then
            log "FAILED $name: a different file is already in $month, left in incoming"; return 1
        fi
        rm -f "$src"
    else
        mv -n "$src" "$dest"
    fi
    FILED_BYTES=$(( FILED_BYTES + $(stat -f %z "$dest") ))
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

# -----------------------------------------------------------------------------
# update_gallery
#   Purpose : Refresh the browsing pages in the backup folder.
#   Input   : globals GALLERY, LOCAL_DIR
#   Output  : pages rewritten by the gallery script; its summary logged;
#             returns non-zero (with a "FAILED: ..." log line) if it failed
# -----------------------------------------------------------------------------
update_gallery() {
    local out
    if out="$(/usr/bin/python3 "$GALLERY" --local-dir "$LOCAL_DIR" 2>&1)"; then
        log "$out"
    else
        log "FAILED: gallery update: $(printf '%s' "$out" | tail -1)"
        return 1
    fi
}

# --- main ---
parse_args "$@"
init_logging

STAGING="$LOCAL_DIR/incoming"
mkdir -p "$STAGING"
if ! acquire_lock; then
    log "another run holds $LOCK; exiting"
    exit 0
fi
MANIFEST="$(mktemp)"
NAMES="$(mktemp)"
trap cleanup EXIT

log "=== $NAME start ($(trigger))"
STARTED=1

if ! fetch_manifest "$MANIFEST" "$NAMES"; then
    log "FAILED: could not list files on $REMOTE_HOST"
    ERRORS+=("unreachable:$REMOTE_HOST")
    finish
fi
if [[ ! -s $MANIFEST ]]; then
    log "no new screenshots on $REMOTE_HOST"
    finish
fi
log "found $(wc -l < "$NAMES" | tr -d ' ') file(s) on $REMOTE_HOST"
if ! pull_files "$NAMES"; then
    log "FAILED: rsync exited non-zero"
    ERRORS+=("transfer")
fi

failed_files=0
while IFS= read -r line; do
    if file_screenshot "${line:0:64}" "${line:66}"; then
        FILED+=("${line:66}")
    else
        failed_files=$(( failed_files + 1 ))
    fi
done < "$MANIFEST"
if (( failed_files )); then
    ERRORS+=("files:$failed_files")
fi

if (( ${#FILED[@]} )); then
    log "backed up ${#FILED[@]} file(s) ($FILED_BYTES bytes): ${FILED[0]} .. ${FILED[${#FILED[@]}-1]}"
    if (( KEEP_REMOTE )); then
        log "kept on $REMOTE_HOST (--keep-remote)"
    elif delete_remote "${FILED[@]}"; then
        log "deleted ${#FILED[@]} file(s) from $REMOTE_HOST"
    else
        log "FAILED: could not delete backed-up files on $REMOTE_HOST"
        ERRORS+=("remote-delete")
    fi
fi
finish
