# sconsole-scrshot-backup

Backs up the screenshots that sconsole takes every 5 minutes on the Raspberry Pi
(`192.168.0.161`) to this Mac, sorted into month folders. Each remote file is
deleted only after its local copy matches it by SHA-256. Each run's result is
published on the Caddy site at `http://<this-mac>/screenshots/`, the same way
db-backup publishes `/backups/`.

| | |
|---|---|
| Remote | `sandeep@192.168.0.161:~/projects/workspace/sconsole/screenshots/` (flat; the `bak/` subfolder is ignored) |
| Local | `~/projects/workspace/sconsole/sconsole-screenshots/YYYY-MM/YYYY-MM-DD HHMMSS.png` |
| Schedule | launchd, hourly, plus once when deployed or at login |
| Workspace | `~/softwares/workspace/sconsole-scrshot-backup/` — `logs/YYYY-MM-DD.log` (kept 90 days), `logs/launchd.log`, `logs/status.out`, `status`, `work/.lock` |
| Status page | `~/softwares/workspace/caddy/site/screenshots/` (`index.html` + generated `status.json`) |

## How a run works

1. Lists remote `*.png` files older than 2 minutes, so it skips any file still being written, with their SHA-256.
2. Copies them with `rsync` into `<local>/incoming/`.
3. For each file: checks the SHA-256, then moves it into `<local>/YYYY-MM/`. If an identical file is already there, the staged copy is dropped.
4. Deletes from the remote only the files that passed step 3.

Files that fail a check stay on the remote and are logged, and the run exits with code 1. A file with a
different version already in the month folder is left in `incoming/` for you to look at.
`work/.lock` in the workspace stops two runs from overlapping. If a run is killed hard
(`kill -9`, power loss), delete it by hand: `rmdir ~/softwares/workspace/sconsole-scrshot-backup/work/.lock`.

## Browsing the screenshots

Open `~/projects/workspace/sconsole/sconsole-screenshots/index.html` in a browser (`open` it from the terminal).
The pages are plain static files, so they work from `file://` with no server.

- **Index:** a year → month → week tree on the left, with the selected view on the right. It opens on the newest week.
- **Month (`YYYY-MM/index.html`):** a Sunday–Saturday calendar. Each day shows its screenshot count and a midday thumbnail. Click a week or a day to open it.
- **Week (`YYYY-MM/week-N.html`):** a day × hour table of counts, shaded by how full each hour is.
  - Click an hour to see its screenshots in a grid below the table. The page fills the window: the header and the
    compact table stay in place and only the grid scrolls (on narrow or short windows the whole page scrolls). The address becomes `#YYYY-MM-DDTHH`, so Back and bookmarks work.
  - Click a screenshot to zoom it. ←/→ step through the hour, Esc closes, and **Save** downloads the original PNG.
    Some browsers ignore downloads from `file://` pages and open the image instead. Then use ⌘S or right-click › Save Image.
- **Week numbers** are the rows of each month's calendar. A week that spans two months is split between them, so each month folder only links its own images.

`sconsole-scrshot-backup-gallery` (`src/main/python/`) generates the pages. The backup runs it after every run that files new screenshots.
Every page carries a signature of the data it shows and is rewritten only when that changes. A normal run rewrites just
`index.html`, the current month and the current week. Older pages never change.
Run it by hand with `sconsole-scrshot-backup-gallery`. Add `--all` to rewrite every page after changing the page layout,
or bump `GEN_VERSION` in the script instead.

## Status page

Same pattern as db-backup's `/backups/`:

1. **Run log.** The backup appends each run to `logs/YYYY-MM-DD.log`. The status builder relies on these lines:
   ```
   2026-11-16 20:16:04 === sconsole-scrshot-backup start (manual|scheduled)
   2026-11-16 20:16:04 found 3 file(s) on sconsole
   2026-11-16 20:16:06 backed up 3 file(s) (503976 bytes): 2026-11-16 200000.png .. 2026-11-16 201000.png
   2026-11-16 20:16:06 deleted 3 file(s) from sconsole
   2026-11-16 20:16:06 FAILED <name>: <reason>            (per-file or run-level problems)
   2026-11-16 20:16:06 === sconsole-scrshot-backup OK: 3 file(s)
                       === sconsole-scrshot-backup FINISHED WITH ERRORS: <reason> ...
   ```
   It then rewrites the `status` file (`<timestamp> OK <n>` or `<timestamp> FAILED <reasons>`).
2. **Status builder.** `sconsole-scrshot-backup-status` (`src/main/python/`, Apple's python3, standard library only)
   reads the logs, the lock and the month folders, and writes `status.json` to the Caddy site in one atomic replace.
   Its LaunchAgent runs it when `status` or `work/` changes (a run ending or starting) and every 15 minutes.
   - It reports `ok`, `failed`, `running`, `stale` (no successful run in 3 hours) or `unknown`.
3. **Page.** `src/main/web/index.html` is copied to the site on deploy. It loads `status.json` every minute.
   - It shows a summary card, the latest screenshot, totals, the last 24 hours, and files stuck in `incoming/`.
   - Below that are a month-folder table and the run history. Runs that found nothing are folded into one row.

Deploy also links the backup folder into the site as `site/screenshots/gallery` (Caddy's file_server follows symlinks),
so the browsing pages are served at `http://<this-mac>/screenshots/gallery/`. On the status page, each month in
"Month folders" opens that month's page in a new tab, and "Browse all screenshots" opens the tree. Month and week pages
have an "All screenshots" link back to the tree. This puts every screenshot on the home network over plain HTTP.

The landing page (`site/index.html`) has a "Screenshot backups" card that reads the same `status.json`.
That page isn't part of this project, so the card was added by hand. Undeploy doesn't remove it.

## Setup (one time)

SSH key login, so no password is stored anywhere:

```sh
ssh-keygen -t ed25519 -N '' -C 'sconsole-scrshot-backup' -f ~/.ssh/sconsole_ed25519
cat >> ~/.ssh/config <<'EOF'
Host sconsole
    HostName 192.168.0.161
    User sandeep
    IdentityFile ~/.ssh/sconsole_ed25519
    IdentitiesOnly yes
    ConnectTimeout 10
EOF
ssh-copy-id -i ~/.ssh/sconsole_ed25519.pub sconsole     # asks for the password once
ssh -o BatchMode=yes sconsole true && echo OK            # must not prompt
```

## Build, deploy, run

```sh
scripts/sconsole-scrshot-backup-build.sh       # checks scripts, writes the two plists to target/ (--interval <sec> to change from hourly)
scripts/sconsole-scrshot-backup-deploy.sh      # links both commands, publishes the page, installs + starts both jobs (runs a backup immediately)
scripts/sconsole-scrshot-backup-undeploy.sh    # removes both jobs, both links and the page (keeps logs and screenshots)
```

Deploying creates three links in `~/softwares/bin/scripts/`, which is on PATH. launchd and the backup use them:
- `sconsole-scrshot-backup` → `scripts/sconsole-scrshot-backup.sh`
- `sconsole-scrshot-backup-status` → `src/main/python/sconsole-scrshot-backup-status.py`
- `sconsole-scrshot-backup-gallery` → `src/main/python/sconsole-scrshot-backup-gallery.py`

Run by hand:

```sh
sconsole-scrshot-backup                  # normal run: copy, check, delete remote
sconsole-scrshot-backup --keep-remote    # copy only
sconsole-scrshot-backup '/?'             # all options (quote /? in zsh)
sconsole-scrshot-backup-status           # rebuild status.json now
```

Check on the jobs:

```sh
tail -f ~/softwares/workspace/sconsole-scrshot-backup/logs/$(date +%F).log
launchctl print gui/$(id -u)/com.sandeep.sconsole-scrshot-backup | grep -E 'state|last exit'
launchctl kickstart gui/$(id -u)/com.sandeep.sconsole-scrshot-backup   # run a backup now
```

Changes to the backup script or the status builder apply on their next run, because the links point at them.
After changing the page, the schedule or the build script, build and deploy again.

## Layout

```
readme.md
scripts/
  sconsole-scrshot-backup.sh            the backup itself
  sconsole-scrshot-backup-build.sh      check scripts, generate target/ plists
  sconsole-scrshot-backup-deploy.sh     link commands, publish page, install launchd jobs
  sconsole-scrshot-backup-undeploy.sh   remove launchd jobs, links and page
src/main/
  python/sconsole-scrshot-backup-status.py   logs -> status.json for the page
  python/sconsole-scrshot-backup-gallery.py  static browsing pages in the backup folder
  web/index.html                             the /screenshots/ status page
target/                                      build output (generated)
  com.sandeep.sconsole-scrshot-backup.plist
  com.sandeep.sconsole-scrshot-backup-status.plist
```
