#!/bin/bash
# =============================================================================
# db-backup.sh
#
# Purpose:
#   Nightly backup of the live MariaDB databases to this Mac. For each source:
#     1. mariadb-dump (consistent, non-locking for InnoDB) to a temp .sql
#     2. check the dump completed
#     3. store it in the restic repository (deduplicated and compressed)
#     4. reload it into the local MariaDB as a ready-to-use live copy
#   Then applies retention (restic forget --prune) and, on Sundays, runs
#   restic check.
#
#   Runs as root from the LaunchDaemon com.sandeep.db-backup: root daemons are
#   exempt from macOS Local Network privacy, which blocks Homebrew binaries
#   otherwise. When run as root it hands the workspace back to OWNER on exit.
#
#   Each run is logged to ~/softwares/workspace/db-backup/logs/YYYY-MM-DD.log
#   between "=== db-backup start: <sources>" and "=== db-backup OK|FINISHED
#   WITH ERRORS" lines, and the result is written to the workspace's status
#   file. db-backup-status turns these into the web status page.
#
#   Configs (kept out of the project):
#     ~/softwares/logncfgs/db-backup/<source>.cnf  [client] host/user/password
#     ~/softwares/logncfgs/db-backup/restic-password
#   Workspace: ~/softwares/workspace/db-backup/{restic-repo,restic-cache,work,
#              logs,status}
#
# Usage:
#   db-backup.sh [source ...]
#
# Parameters:
#   source          Back up only these sources (capitalyst, jove_notes,
#                   sconsolenxt). Default: all of them.
#   /?, -h, --help  Print this help and exit.
#
# Exit codes:
#   0  success
#   1  the run finished with errors, or another run is in progress
#   2  bad arguments
# =============================================================================
set -uo pipefail

NAME=db-backup
OWNER=sandeep
HOME="/Users/$OWNER"
# brew refuses to run as root, so its folders are put on PATH by hand
export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin

# "<source>:<databases to dump from that server>"; <source> names its .cnf
SOURCES=(
    "capitalyst:capitalyst"
    "jove_notes:jove_notes user"
    "sconsolenxt:sconsolenxt"
)

CONF_DIR="$HOME/softwares/logncfgs/$NAME"
WS="$HOME/softwares/workspace/$NAME"
WORK="$WS/work"
LOG_DIR="$WS/logs"
STATUS="$WS/status"
LOCK="$WORK/.lock"
LOG_KEEP_DAYS=90
KEEP=(--keep-daily 14 --keep-weekly 8 --keep-monthly 12)
export RESTIC_REPOSITORY="$WS/restic-repo"
export RESTIC_PASSWORD_FILE="$CONF_DIR/restic-password"
export RESTIC_CACHE_DIR="$WS/restic-cache"

NAMES=()         # sources to back up this run
FAILURES=()      # failed sources/databases/steps, for the end marker

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
# source_dbs
#   Purpose : Look up the databases of a source.
#   Input   : $1 - source name; globals SOURCES
#   Output  : stdout - space-separated database names; returns 1 if the
#             source is unknown
# -----------------------------------------------------------------------------
source_dbs() {
    local entry
    for entry in "${SOURCES[@]}"; do
        if [[ ${entry%%:*} == "$1" ]]; then
            echo "${entry#*:}"
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# parse_args
#   Purpose : Read the sources to back up.
#   Input   : "$@" - the script's arguments; globals SOURCES
#   Output  : sets NAMES (all sources when none are given); on /? prints
#             usage and exits 0; on an unknown source prints usage to stderr
#             and exits 2
# -----------------------------------------------------------------------------
parse_args() {
    local entry
    while (( $# > 0 )); do
        case "$1" in
            '/?'|-h|--help) print_usage; exit 0 ;;
        esac
        if ! source_dbs "$1" >/dev/null; then
            echo "Unknown source: $1" >&2; print_usage >&2; exit 2
        fi
        NAMES+=("$1")
        shift
    done
    if (( ${#NAMES[@]} == 0 )); then
        for entry in "${SOURCES[@]}"; do
            NAMES+=("${entry%%:*}")
        done
    fi
}

# -----------------------------------------------------------------------------
# init_logging
#   Purpose : Send all further output (including tool errors) to today's log
#             file as well as stdout, and delete logs past LOG_KEEP_DAYS.
#   Input   : globals LOG_DIR, WORK, LOG_KEEP_DAYS
#   Output  : creates LOG_DIR and WORK (WORK private, as it holds dumps);
#             redirects stdout and stderr
# -----------------------------------------------------------------------------
init_logging() {
    mkdir -p "$LOG_DIR" "$WORK"
    chmod 700 "$WORK"
    exec > >(tee -a "$LOG_DIR/$(date +%F).log") 2>&1
    find "$LOG_DIR" -name '????-??-??.log' -mtime +"$LOG_KEEP_DAYS" -delete
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
# cleanup
#   Purpose : EXIT trap. Removes dumps left behind, releases the lock and,
#             when running as root, gives the workspace back to OWNER.
#   Input   : globals WORK, LOCK, WS, OWNER
#   Output  : none
# -----------------------------------------------------------------------------
cleanup() {
    rm -f "$WORK"/*.sql
    rmdir "$LOCK" 2>/dev/null || true
    if (( EUID == 0 )); then
        chown -R "$OWNER:staff" "$WS"
    fi
}

# -----------------------------------------------------------------------------
# dump_db
#   Purpose : Dump one database and check the dump is complete.
#   Input   : $1 - .cnf file for the server; $2 - database; $3 - output file;
#             global TAG (source/db, for log lines)
#   Output  : the dump in $3; returns 1 (with a FAILED log line) on failure
# -----------------------------------------------------------------------------
dump_db() {
    local cnf="$1" db="$2" out="$3"
    if ! mariadb-dump --defaults-extra-file="$cnf" --single-transaction --quick \
            --routines --triggers --events --hex-blob --default-character-set=utf8mb4 \
            --databases "$db" > "$out"; then
        log "[$TAG] FAILED: mariadb-dump exited non-zero"; return 1
    fi
    if [[ "$(tail -c 200 "$out")" != *"-- Dump completed"* ]]; then
        log "[$TAG] FAILED: dump is incomplete"; return 1
    fi
}

# -----------------------------------------------------------------------------
# store_dump
#   Purpose : Store a dump in restic. A stable per-database file name gives
#             good deduplication between nights.
#   Input   : $1 - database; $2 - dump file; restic env vars
#   Output  : a new snapshot tagged mariadb + <db>; returns restic's code
# -----------------------------------------------------------------------------
store_dump() {
    restic backup --quiet --host mac-studio --tag mariadb --tag "$1" \
        --stdin-filename "mariadb/$1.sql" --stdin-from-command -- cat "$2"
}

# -----------------------------------------------------------------------------
# load_live_copy
#   Purpose : Recreate the database in the local MariaDB from a dump.
#             Foreign key checks are off (jove_notes has foreign keys into the
#             separate `user` database), and DEFINER clauses are stripped so
#             views and routines don't reference users that only exist on the
#             source server.
#   Input   : $1 - database; $2 - dump file
#   Output  : local database replaced; returns non-zero if loading failed
# -----------------------------------------------------------------------------
load_live_copy() {
    { printf 'SET FOREIGN_KEY_CHECKS=0; DROP DATABASE IF EXISTS `%s`;\n' "$1"
      sed -E 's/DEFINER=`[^`]*`@`[^`]*`//g' "$2"; } | mariadb --binary-mode
}

# -----------------------------------------------------------------------------
# backup_source
#   Purpose : Dump, store and reload every database of one source.
#   Input   : $1 - source name; globals CONF_DIR, WORK
#   Output  : progress logged; failed items added to FAILURES
# -----------------------------------------------------------------------------
backup_source() {
    local name="$1" cnf="$CONF_DIR/$1.cnf" db f t0
    if [[ ! -r $cnf ]]; then
        log "[$name] missing $cnf - skipped"; FAILURES+=("$name"); return
    fi
    for db in $(source_dbs "$name"); do
        TAG="$name/$db"; f="$WORK/$db.sql"; t0=$SECONDS
        log "[$TAG] dumping"
        if ! dump_db "$cnf" "$db" "$f"; then
            FAILURES+=("$TAG"); continue
        fi
        log "[$TAG] dump OK ($(du -h "$f" | cut -f1), $((SECONDS - t0))s)"
        if ! store_dump "$db" "$f"; then
            log "[$TAG] FAILED: restic backup"; FAILURES+=("$TAG"); continue
        fi
        log "[$TAG] stored in restic"
        if load_live_copy "$db" "$f"; then
            log "[$TAG] live copy refreshed ($((SECONDS - t0))s total)"
        else
            log "[$TAG] FAILED: loading live copy into local MariaDB"; FAILURES+=("$TAG(live-copy)")
        fi
        rm -f "$f"
    done
}

# -----------------------------------------------------------------------------
# maintain_repo
#   Purpose : Apply retention and, on Sundays, check the repository.
#   Input   : globals KEEP; restic env vars
#   Output  : old snapshots pruned; failed steps added to FAILURES
# -----------------------------------------------------------------------------
maintain_repo() {
    log "applying retention: ${KEEP[*]}"
    if ! restic forget --quiet --host mac-studio --tag mariadb --group-by host,tags "${KEEP[@]}" --prune; then
        FAILURES+=("retention")
    fi
    if [[ $(date +%u) == 7 ]]; then
        log "weekly repository check"
        restic check --quiet || FAILURES+=("restic-check")
    fi
}

# -----------------------------------------------------------------------------
# finish
#   Purpose : Log the end marker, write the status file and exit.
#   Input   : globals FAILURES, NAME, STATUS
#   Output  : STATUS rewritten; exits 0 (OK) or 1 (errors)
# -----------------------------------------------------------------------------
finish() {
    if (( ${#FAILURES[@]} )); then
        log "=== $NAME FINISHED WITH ERRORS: ${FAILURES[*]}"
        printf '%s FAILED: %s\n' "$(date '+%F %T')" "${FAILURES[*]}" > "$STATUS"
        exit 1
    fi
    log "=== $NAME OK"
    printf '%s OK\n' "$(date '+%F %T')" > "$STATUS"
    exit 0
}

# --- main ---
parse_args "$@"
init_logging
if ! acquire_lock; then
    log "Another run is in progress ($LOCK) - exiting."
    exit 1
fi
trap cleanup EXIT

log "=== $NAME start: ${NAMES[*]}"
for name in "${NAMES[@]}"; do
    backup_source "$name"
done
maintain_repo
finish
