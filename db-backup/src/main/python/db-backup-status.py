#!/usr/bin/python3
# =============================================================================
# db-backup-status.py
#
# Purpose:
#   Builds the status JSON for the database backup web page
#   (http://<this-mac>/backups/). Reads the backup's daily run logs and the
#   restic repository (read-only, --no-lock), and writes status.json in one
#   atomic replace so the page never sees a half-written file. Run by the
#   LaunchAgent com.sandeep.db-backup-status whenever the backup writes its
#   status file or takes its lock, and every 15 minutes.
#   Uses Apple's /usr/bin/python3 (3.9), standard library only.
#
# Usage:
#   db-backup-status.py [options]
#
# Parameters:
#   --workspace <dir>  Backup workspace (logs/, work/, restic-repo/).
#                      Default: ~/softwares/workspace/db-backup
#   --out <file>       Where to write the JSON.
#                      Default: ~/softwares/workspace/caddy/site/backups/status.json
#   /?, -h, --help     Print this help and exit.
#
# Exit codes:
#   0  status.json written
#   2  bad arguments
# =============================================================================
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta

NAME = "db-backup"
HOME = os.path.expanduser("~")
WORKSPACE = f"{HOME}/softwares/workspace/{NAME}"
PW_FILE = f"{HOME}/softwares/logncfgs/{NAME}/restic-password"
OUT = f"{HOME}/softwares/workspace/caddy/site/backups/status.json"
RESTIC = "/opt/homebrew/bin/restic"
SCHEDULE_HOUR = 2     # the LaunchDaemon com.sandeep.db-backup runs at 02:00
STALE_HOURS = 26      # no successful run for this long = problem
MAX_RUNS = 200        # runs kept in the JSON, newest first
RETENTION = "14 daily, 8 weekly, 12 monthly"   # matches KEEP in db-backup.sh
TS = "%Y-%m-%d %H:%M:%S"

LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (.*)$")
ITEM = re.compile(r"^\[([^\]]+)\] (.*)$")


# -----------------------------------------------------------------------------
# print_usage
#   Purpose : Print the usage text from this script's header.
#   Input   : stream - where to print (default stdout)
#   Output  : the header without comment markers
# -----------------------------------------------------------------------------
def print_usage(stream=sys.stdout):
    with open(os.path.realpath(__file__)) as fh:
        lines = fh.read().splitlines()[2:]
    for line in lines:
        if line.startswith("# ====="):
            break
        stream.write(re.sub(r"^# ?", "", line) + "\n")


# -----------------------------------------------------------------------------
# parse_args
#   Purpose : Read command-line options.
#   Input   : argv - the script's arguments (without the program name)
#   Output  : dict with workspace, out; on /? prints usage and exits 0; on a
#             bad argument prints usage to stderr and exits 2
# -----------------------------------------------------------------------------
def parse_args(argv):
    opts = {"workspace": WORKSPACE, "out": OUT}
    flags = {"--workspace": "workspace", "--out": "out"}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("/?", "-h", "--help"):
            print_usage()
            sys.exit(0)
        if arg in flags and i + 1 < len(argv):
            opts[flags[arg]] = argv[i + 1]
            i += 2
            continue
        print(f"Unknown argument: {arg}", file=sys.stderr)
        print_usage(sys.stderr)
        sys.exit(2)
    return opts


# -----------------------------------------------------------------------------
# apply_item
#   Purpose : Update a database's entry in a run from one "[source/db] ..."
#             log line.
#   Input   : item - the database's dict in run["items"]; what - the text
#             after the tag
#   Output  : item updated in place (size, dump_s, stored, status, total_s,
#             error)
# -----------------------------------------------------------------------------
def apply_item(item, what):
    if what.startswith("dump OK"):
        m = re.search(r"\(\s*([^,]+),\s*(\d+)s\)", what)
        if m:
            item["size"], item["dump_s"] = m.group(1), int(m.group(2))
    elif what == "stored in restic":
        item["stored"] = True
    elif what.startswith("live copy refreshed"):
        m = re.search(r"\((\d+)s total\)", what)
        item["status"] = "ok"
        if m:
            item["total_s"] = int(m.group(1))
    elif what.startswith("FAILED"):
        item["status"] = "failed"
        item["error"] = what.split(":", 1)[-1].strip()


# -----------------------------------------------------------------------------
# parse_logs
#   Purpose : Turn the daily run logs into a list of runs.
#   Input   : log_dir - folder with YYYY-MM-DD.log files
#   Output  : list of runs, oldest first; each has start, end, result (ok,
#             failed, incomplete), trigger (nightly or manual), sources,
#             failures, items (one per database), duration_s once ended,
#             and details (untimestamped tool output) where there was any
# -----------------------------------------------------------------------------
def parse_logs(log_dir):
    runs = []
    for path in sorted(glob.glob(f"{log_dir}/????-??-??.log")):
        run = None
        last_item = None
        with open(path, errors="replace") as fh:
            for raw in fh:
                raw = raw.rstrip("\n")
                m = LINE.match(raw)
                if not m:
                    # untimestamped output (e.g. mariadb-dump's error text)
                    if run is not None and raw.strip():
                        target = run["items"][last_item] if last_item in run["items"] else run
                        target.setdefault("details", []).append(raw.strip()[:300])
                    continue
                ts, msg = m.groups()
                if msg.startswith(f"=== {NAME} start:"):
                    t = datetime.strptime(ts, TS)
                    run = {"start": ts, "end": None, "result": "incomplete", "items": {},
                           "failures": [], "sources": msg.split(":", 1)[1].split(),
                           "trigger": "nightly" if (t.hour == SCHEDULE_HOUR and t.minute < 5) else "manual"}
                    runs.append(run)
                    last_item = None
                    continue
                if run is None:
                    continue
                if msg.startswith(f"=== {NAME} OK"):
                    run.update(end=ts, result="ok")
                    run = None
                    continue
                if msg.startswith(f"=== {NAME} FINISHED WITH ERRORS:"):
                    run.update(end=ts, result="failed", failures=msg.split(":", 1)[1].split())
                    run = None
                    continue
                im = ITEM.match(msg)
                if im:
                    tag, what = im.groups()
                    db = tag.split("/")[-1]
                    item = run["items"].setdefault(db, {"db": db, "source": tag.split("/")[0],
                                                        "status": "running"})
                    last_item = db
                    apply_item(item, what)
                elif msg.startswith("applying retention"):
                    last_item = None
    for r in runs:
        if r["end"]:
            r["duration_s"] = int((datetime.strptime(r["end"], TS) -
                                   datetime.strptime(r["start"], TS)).total_seconds())
        r["items"] = list(r["items"].values())
    return runs


# -----------------------------------------------------------------------------
# restic_snapshots
#   Purpose : Summarise the repository's snapshots per database.
#   Input   : workspace - holds restic-repo/ and restic-cache/; globals
#             RESTIC, PW_FILE
#   Output  : (list of {db, count, oldest, latest, latest_bytes, latest_id}
#             sorted by db, None), or (None, error text) if restic failed
# -----------------------------------------------------------------------------
def restic_snapshots(workspace):
    env = dict(os.environ, RESTIC_REPOSITORY=f"{workspace}/restic-repo",
               RESTIC_PASSWORD_FILE=PW_FILE, RESTIC_CACHE_DIR=f"{workspace}/restic-cache")
    try:
        out = subprocess.run([RESTIC, "snapshots", "--json", "--no-lock", "--tag", "mariadb"],
                             env=env, capture_output=True, text=True, timeout=120)
        if out.returncode != 0:
            return None, out.stderr.strip()[-300:]
        snaps = json.loads(out.stdout or "[]")
    except Exception as e:  # noqa: BLE001 - report anything to the page
        return None, str(e)[:300]
    by_db = {}
    for s in snaps:
        db = next((t for t in s.get("tags", []) if t != "mariadb"), "?")
        t = s["time"][:19].replace("T", " ")
        d = by_db.setdefault(db, {"db": db, "count": 0, "oldest": t, "latest": t,
                                  "latest_bytes": None, "latest_id": s.get("short_id")})
        d["count"] += 1
        d["oldest"] = min(d["oldest"], t)
        if t >= d["latest"]:
            d["latest"] = t
            d["latest_id"] = s.get("short_id")
            d["latest_bytes"] = (s.get("summary") or {}).get("total_bytes_processed")
    return sorted(by_db.values(), key=lambda d: d["db"]), None


# -----------------------------------------------------------------------------
# du_bytes
#   Purpose : Total size of the files under a folder.
#   Input   : path - folder
#   Output  : size in bytes (unreadable files are skipped)
# -----------------------------------------------------------------------------
def du_bytes(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total


# -----------------------------------------------------------------------------
# overall_state
#   Purpose : Decide the page's headline state.
#   Input   : runs - from parse_logs (a running run is marked here);
#             running - whether the lock is held; now - current time
#   Output  : (overall, headline, last finished run or None); overall is ok,
#             failed, running, stale or unknown
# -----------------------------------------------------------------------------
def overall_state(runs, running, now):
    # A run without an end line is still going only if it is the newest one and holds the lock
    if running and runs and runs[-1]["result"] == "incomplete":
        runs[-1]["result"] = "running"
    finished = [r for r in runs if r["result"] in ("ok", "failed", "incomplete")]
    last = finished[-1] if finished else None
    if running:
        return "running", "Backup in progress", last
    if not last:
        return "unknown", "No backups yet", last
    if last["result"] != "ok":
        return "failed", "Last backup failed", last
    if (now - datetime.strptime(last["end"], TS)) > timedelta(hours=STALE_HOURS):
        return "stale", "No backup in over a day", last
    return "ok", "Backups OK", last


# -----------------------------------------------------------------------------
# next_run
#   Purpose : When the nightly job runs next.
#   Input   : now - current time; global SCHEDULE_HOUR
#   Output  : datetime of the next SCHEDULE_HOUR:00
# -----------------------------------------------------------------------------
def next_run(now):
    nxt = now.replace(hour=SCHEDULE_HOUR, minute=0, second=0, microsecond=0)
    return nxt + timedelta(days=1) if nxt <= now else nxt


# -----------------------------------------------------------------------------
# write_json
#   Purpose : Write the status JSON atomically.
#   Input   : path - output file; data - dict
#   Output  : path replaced in one step (via path.tmp)
# -----------------------------------------------------------------------------
def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=1)
    os.replace(tmp, path)


# --- main ---
if __name__ == "__main__":
    opts = parse_args(sys.argv[1:])
    now = datetime.now()
    runs = parse_logs(f"{opts['workspace']}/logs")
    running = os.path.isdir(f"{opts['workspace']}/work/.lock")
    overall, headline, last = overall_state(runs, running, now)
    last_ok = next((r for r in reversed(runs) if r["result"] == "ok"), None)
    snaps, snap_err = restic_snapshots(opts["workspace"])

    write_json(opts["out"], {
        "generated": now.strftime(TS),
        "overall": overall,
        "headline": headline,
        "running": running,
        "last_run": last,
        "last_ok": last_ok["end"] if last_ok else None,
        "next_scheduled": next_run(now).strftime(TS),
        "stale_hours": STALE_HOURS,
        "repo_bytes": du_bytes(f"{opts['workspace']}/restic-repo"),
        "retention": RETENTION,
        "snapshots": snaps,
        "snapshot_error": snap_err,
        "runs": list(reversed(runs))[:MAX_RUNS],
    })
    print(f"{now.strftime(TS)} wrote {opts['out']}: {overall}, {len(runs)} runs", file=sys.stderr)
