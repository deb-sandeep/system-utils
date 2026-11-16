# db-backup

Nightly backup of the live MariaDB databases to this Mac. Each database is dumped, stored in a
restic repository (deduplicated and compressed), and reloaded into the local MariaDB as a
ready-to-query live copy. Each run's result is published on the Caddy site at `http://<this-mac>/backups/`.

| | |
|---|---|
| Sources | `capitalyst` (capitalyst), `jove_notes` (jove_notes, user), `sconsolenxt` (sconsolenxt): the `SOURCES` list in `scripts/db-backup.sh` |
| Configs | `~/softwares/logncfgs/db-backup/<source>.cnf` (`[client]` host/user/password) and `restic-password`. Kept out of the repo. |
| Schedule | LaunchDaemon `com.sandeep.db-backup`, runs as root every night at 02:00 |
| Retention | restic: 14 daily, 8 weekly, 12 monthly; `restic check` on Sundays |
| Workspace | `~/softwares/workspace/db-backup/`: `restic-repo/`, `restic-cache/`, `logs/YYYY-MM-DD.log` (kept 90 days), `logs/launchd.log`, `logs/status.out`, `status`, `work/` (temp dumps, `.lock`) |
| Status page | `~/softwares/workspace/caddy/site/backups/` (`index.html` + generated `status.json`) |

## Why it runs as root

macOS Local Network privacy blocks Homebrew binaries (`mariadb-dump`, `restic`) started by a user
LaunchAgent from reaching other machines on the LAN. Root LaunchDaemons are exempt. So the backup is a
LaunchDaemon. It sets `HOME` to the owner's home, puts Homebrew on `PATH` itself (brew refuses to run as
root), loads the live copies as root with the local `mariadb` client, and hands the workspace back to
`sandeep` when it exits. The status builder only reads, so it is a normal LaunchAgent.

## How a run works

For each source (all of them, or just the ones named on the command line):

1. `mariadb-dump --single-transaction` of each database into `work/<db>.sql` (consistent and non-locking for InnoDB).
2. Checks the dump ends with `-- Dump completed`.
3. `restic backup` with the stable name `mariadb/<db>.sql` and tags `mariadb` and `<db>`, so nights deduplicate well.
4. Recreates the database in the local MariaDB from the dump. Foreign key checks are off (jove_notes refers to the
   separate `user` database), and `DEFINER` clauses are stripped so views and routines don't refer to users that only
   exist on the source server.

Then `restic forget --prune` applies retention, and on Sundays `restic check` verifies the repository.
A failed step is logged and the run carries on with the next database. The run then exits 1 and the status
page shows what failed. `work/.lock` stops two runs from overlapping. If a run is killed hard, remove it:
`sudo rmdir ~/softwares/workspace/db-backup/work/.lock`.

## Status page

Same pattern as the other jobs in this repo (see `CLAUDE.md`):

1. **Run log.** The backup appends each run to `logs/YYYY-MM-DD.log`. The status builder relies on these lines:
   ```
   2026-11-16 02:00:04 === db-backup start: capitalyst jove_notes sconsolenxt
   2026-11-16 02:01:35 [capitalyst/capitalyst] dump OK (177M, 90s)
   2026-11-16 02:01:38 [capitalyst/capitalyst] stored in restic
   2026-11-16 02:01:50 [capitalyst/capitalyst] live copy refreshed (106s total)
   2026-11-16 02:01:50 [<source>/<db>] FAILED: <reason>
   2026-11-16 02:03:44 applying retention: --keep-daily 14 --keep-weekly 8 --keep-monthly 12
   2026-11-16 02:03:47 === db-backup OK
                       === db-backup FINISHED WITH ERRORS: <items> ...
   ```
   Untimestamped tool output (for example `mariadb-dump` errors) is attached to the database it belongs to.
   It then rewrites the `status` file (`<timestamp> OK` or `<timestamp> FAILED: <items>`).
2. **Status builder.** `db-backup-status` (`src/main/python/`, Apple's python3, standard library only) reads the
   logs, the lock and the restic snapshots (`--no-lock`, read-only), and writes `status.json` to the Caddy site in
   one atomic replace. Its LaunchAgent runs it when `status` or `work/` changes (a run ending or starting) and every 15 minutes.
   - It reports `ok`, `failed`, `running`, `stale` (no successful run in 26 hours) or `unknown`.
   - A run starting between 02:00 and 02:04 counts as nightly, any other as manual.
3. **Page.** `src/main/web/index.html` is copied to the site on deploy. It loads `status.json` every minute and shows
   the last run per database, the snapshots per database, the repository size and the run history.

The landing page (`site/index.html`) has a "Database backups" card in its Service health section that reads the same
`status.json`. That page isn't part of this project, so undeploy doesn't remove the card.

## Setup (one time)

These were in place before this project existed. On a new machine:

```sh
brew install mariadb restic
mkdir -p ~/softwares/logncfgs/db-backup && chmod 700 ~/softwares/logncfgs/db-backup
# one <source>.cnf per source, chmod 600:
#   [client]
#   host=<server>
#   user=<backup user>
#   password=<password>
# and the repository password, chmod 600, in restic-password
restic init -r ~/softwares/workspace/db-backup/restic-repo --password-file ~/softwares/logncfgs/db-backup/restic-password
```

## Build, deploy, run

```sh
scripts/db-backup-build.sh       # checks scripts, writes the two plists to target/
scripts/db-backup-deploy.sh      # links both commands, publishes the page, installs both jobs (uses sudo)
scripts/db-backup-undeploy.sh    # removes both jobs, both links and the page (keeps workspace, repo, configs)
```

Run deploy and undeploy from a terminal: the daemon lives in `/Library/LaunchDaemons`, so they ask for your password.
Deploying doesn't run a backup. The first one runs at 02:00, or start one now as shown below.
The first deploy also removes the setup from before this project: the `local.db-backup` daemon, the
`local.backup-status` agent, and the plain copies of `db-backup` and `backup-status` in `~/softwares/bin/scripts/`.

Deploying creates two links in `~/softwares/bin/scripts/`, which is on PATH. launchd uses them:
- `db-backup` → `scripts/db-backup.sh`
- `db-backup-status` → `src/main/python/db-backup-status.py`

Run by hand:

```sh
sudo launchctl kickstart system/com.sandeep.db-backup   # a full run, exactly as at night
sudo db-backup jove_notes                               # just one source (quote '/?' for help)
db-backup-status                                        # rebuild status.json now
```

Check on it:

```sh
tail -f ~/softwares/workspace/db-backup/logs/$(date +%F).log
sudo launchctl print system/com.sandeep.db-backup | grep -E 'state|last exit'
```

Restore an older copy:

```sh
export RESTIC_REPOSITORY=~/softwares/workspace/db-backup/restic-repo
export RESTIC_PASSWORD_FILE=~/softwares/logncfgs/db-backup/restic-password
restic snapshots --tag <db>
restic dump <snapshot-id> /mariadb/<db>.sql > <db>.sql
```

Changes to the backup script or the status builder apply on their next run, because the links point at them.
After changing the page, the schedule or the build script, build and deploy again.

## Layout

```
readme.md
scripts/
  db-backup.sh            the backup itself (runs as root)
  db-backup-build.sh      check scripts, generate target/ plists
  db-backup-deploy.sh     link commands, publish page, install the daemon and agent
  db-backup-undeploy.sh   remove the jobs, links and page
src/main/
  python/db-backup-status.py   logs + restic snapshots -> status.json for the page
  web/index.html               the /backups/ status page
target/                        build output (generated)
  com.sandeep.db-backup.plist          LaunchDaemon
  com.sandeep.db-backup-status.plist   LaunchAgent
```
