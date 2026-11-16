#!/usr/bin/python3
# =============================================================================
# sconsole-scrshot-backup-status.py
#
# Purpose:
#   Builds the status JSON for the screenshot backup web page
#   (http://<this-mac>/screenshots/). Reads the backup's daily run logs and the
#   local backup folder, and writes status.json in one atomic replace so the
#   page never sees a half-written file. Run by the LaunchAgent
#   com.sandeep.sconsole-scrshot-backup-status whenever the backup writes its
#   status file or takes its lock, and every 15 minutes.
#   Uses Apple's /usr/bin/python3 (3.9), standard library only.
#
# Usage:
#   sconsole-scrshot-backup-status.py [options]
#
# Parameters:
#   --workspace <dir>  Backup workspace (logs/, work/, status).
#                      Default: ~/softwares/workspace/sconsole-scrshot-backup
#   --local-dir <dir>  Local backup folder with the YYYY-MM/ month folders.
#                      Default: ~/projects/workspace/sconsole/sconsole-screenshots
#   --out <file>       Where to write the JSON.
#                      Default: ~/softwares/workspace/caddy/site/screenshots/status.json
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
import sys
from datetime import datetime, timedelta

NAME = "sconsole-scrshot-backup"
HOME = os.path.expanduser("~")
WORKSPACE = f"{HOME}/softwares/workspace/{NAME}"
LOCAL_DIR = f"{HOME}/projects/workspace/sconsole/sconsole-screenshots"
OUT = f"{HOME}/softwares/workspace/caddy/site/screenshots/status.json"
INTERVAL_MIN = 60     # the backup's launchd StartInterval
STALE_HOURS = 3       # no successful run for this long = problem
MAX_RUNS = 400        # runs kept in the JSON, newest first
TS = "%Y-%m-%d %H:%M:%S"

LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (.*)$")
BACKED_UP = re.compile(r"^backed up (\d+) file\(s\) \((\d+) bytes\): (.+?) \.\. (.+)$")
MONTH = re.compile(r"^\d{4}-\d\d$")


# -----------------------------------------------------------------------------
# print_usage
#   Purpose : Print the usage text from this script's header.
#   Input   : none
#   Output  : stdout - the header without comment markers
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
#   Output  : dict with workspace, local_dir, out; on /? prints usage and
#             exits 0; on a bad argument prints usage to stderr and exits 2
# -----------------------------------------------------------------------------
def parse_args(argv):
    opts = {"workspace": WORKSPACE, "local_dir": LOCAL_DIR, "out": OUT}
    flags = {"--workspace": "workspace", "--local-dir": "local_dir", "--out": "out"}
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
# new_run
#   Purpose : Start a run record from a start marker line.
#   Input   : ts - start timestamp; msg - the marker text
#   Output  : run dict with result "incomplete" until an end marker is seen
# -----------------------------------------------------------------------------
def new_run(ts, msg):
    m = re.search(r"\((\w+)\)", msg)
    return {"start": ts, "end": None, "result": "incomplete",
            "trigger": m.group(1) if m else "manual",
            "files": 0, "bytes": 0, "first": None, "last": None,
            "remote_deleted": False, "errors": [], "details": []}


# -----------------------------------------------------------------------------
# parse_logs
#   Purpose : Turn the daily logs into a list of runs, oldest first.
#   Input   : log_dir - folder holding YYYY-MM-DD.log files
#   Output  : list of run dicts (see new_run), with duration_s for ended runs
# -----------------------------------------------------------------------------
def parse_logs(log_dir):
    runs = []
    for path in sorted(glob.glob(f"{log_dir}/????-??-??.log")):
        run = None
        with open(path, errors="replace") as fh:
            for raw in fh:
                raw = raw.rstrip("\n")
                m = LINE.match(raw)
                if not m:
                    # untimestamped output, e.g. ssh or rsync error text
                    if run is not None and raw.strip():
                        run["details"].append(raw.strip()[:300])
                    continue
                ts, msg = m.groups()
                if msg.startswith(f"=== {NAME} start"):
                    run = new_run(ts, msg)
                    runs.append(run)
                    continue
                if run is None:
                    continue
                if msg.startswith(f"=== {NAME} OK"):
                    run.update(end=ts, result="ok")
                    run = None
                elif msg.startswith(f"=== {NAME} FINISHED WITH ERRORS:"):
                    run.update(end=ts, result="failed", errors=msg.split(":", 1)[1].split())
                    run = None
                elif msg.startswith("FAILED"):
                    run["details"].append(msg[len("FAILED"):].lstrip(": ")[:300])
                elif msg.startswith("deleted "):
                    run["remote_deleted"] = True
                else:
                    bm = BACKED_UP.match(msg)
                    if bm:
                        run.update(files=int(bm.group(1)), bytes=int(bm.group(2)),
                                   first=bm.group(3), last=bm.group(4))
    for r in runs:
        if r["end"]:
            r["duration_s"] = int((datetime.strptime(r["end"], TS) -
                                   datetime.strptime(r["start"], TS)).total_seconds())
    return runs


# -----------------------------------------------------------------------------
# archive_stats
#   Purpose : Count files and bytes per month folder of the local backup.
#   Input   : local_dir - the backup folder
#   Output  : (months, incoming, latest) - months is a list of
#             {"month", "files", "bytes"} newest first; incoming is the number
#             of files waiting in incoming/; latest is the newest screenshot
#             name, or None
# -----------------------------------------------------------------------------
def archive_stats(local_dir):
    months, latest = [], None
    try:
        entries = sorted(os.scandir(local_dir), key=lambda e: e.name, reverse=True)
    except OSError:
        return [], 0, None
    for entry in entries:
        if not (entry.is_dir() and MONTH.match(entry.name)):
            continue
        files = nbytes = 0
        newest = None
        for f in os.scandir(entry.path):
            if f.is_file() and f.name.endswith(".png"):
                files += 1
                nbytes += f.stat().st_size
                newest = max(newest or f.name, f.name)
        months.append({"month": entry.name, "files": files, "bytes": nbytes})
        latest = latest or newest
    try:
        incoming = sum(1 for f in os.scandir(f"{local_dir}/incoming") if f.is_file())
    except OSError:
        incoming = 0
    return months, incoming, latest


# -----------------------------------------------------------------------------
# overall_state
#   Purpose : Summarise the job's health for the page's headline.
#   Input   : runs - from parse_logs; running - whether the lock is held;
#             now - current time
#   Output  : (overall, headline, last_finished_run_or_None)
# -----------------------------------------------------------------------------
def overall_state(runs, running, now):
    if running and runs and runs[-1]["result"] == "incomplete":
        runs[-1]["result"] = "running"
    finished = [r for r in runs if r["result"] in ("ok", "failed", "incomplete")]
    last = finished[-1] if finished else None
    if running:
        return "running", "Backup in progress", last
    if not last:
        return "unknown", "No backups yet", None
    if last["result"] != "ok":
        return "failed", "Last backup failed", last
    if now - datetime.strptime(last["end"], TS) > timedelta(hours=STALE_HOURS):
        return "stale", f"No backup in over {STALE_HOURS} hours", last
    return "ok", "Backups OK", last


# -----------------------------------------------------------------------------
# write_json
#   Purpose : Write data as JSON atomically (temp file + rename).
#   Input   : path - destination; data - JSON-serialisable value
#   Output  : the file at path replaced
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
    # launchd counts the interval from its own last start, so manual runs don't move it
    timed = [r for r in runs if r["trigger"] == "scheduled"] or runs
    last_start = datetime.strptime(timed[-1]["start"], TS) if timed else now
    months, incoming, latest = archive_stats(opts["local_dir"])

    write_json(opts["out"], {
        "generated": now.strftime(TS),
        "overall": overall,
        "headline": headline,
        "running": running,
        "last_run": last,
        "last_ok": last_ok["end"] if last_ok else None,
        "next_scheduled": (last_start + timedelta(minutes=INTERVAL_MIN)).strftime(TS),
        "interval_min": INTERVAL_MIN,
        "stale_hours": STALE_HOURS,
        "latest_screenshot": latest,
        "incoming": incoming,
        "total_files": sum(m["files"] for m in months),
        "total_bytes": sum(m["bytes"] for m in months),
        "months": months,
        "runs": list(reversed(runs))[:MAX_RUNS],
    })
    print(f"{now.strftime(TS)} wrote {opts['out']}: {overall}, {len(runs)} runs", file=sys.stderr)
