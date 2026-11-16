# sconsole-scrshot-backup

Backs up the screenshots that sconsole takes every 5 minutes on the Raspberry Pi
(`192.168.0.161`) to this Mac, sorted into month folders. Each remote file is
deleted only after its local copy matches it by SHA-256.

| | |
|---|---|
| Remote | `sandeep@192.168.0.161:~/projects/workspace/sconsole/screenshots/` (flat; the `bak/` subfolder is ignored) |
| Local | `~/projects/workspace/sconsole/sconsole-screenshots/YYYY-MM/YYYY-MM-DD HHMMSS.png` |
| Schedule | launchd, hourly, plus once when deployed or at login |
| Log | `~/Library/Logs/sconsole-scrshot-backup.log` |

## How a run works

1. Lists remote `*.png` files older than 2 minutes, so it skips any file still being written, with their SHA-256.
2. Copies them with `rsync` into `<local>/incoming/`.
3. For each file: checks the SHA-256, then moves it into `<local>/YYYY-MM/`. If an identical file is already there, the staged copy is dropped.
4. Deletes from the remote only the files that passed step 3.

Files that fail a check stay on the remote and are logged, and the run exits with code 1. A file with a
different version already in the month folder is left in `incoming/` for you to look at.
A hidden `.backup.lock` folder stops two runs from overlapping. If a run is killed hard
(`kill -9`, power loss), delete it by hand: `rmdir ~/projects/workspace/sconsole/sconsole-screenshots/.backup.lock`.

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
scripts/sconsole-scrshot-backup-build.sh       # checks scripts, writes target/ plist (--interval <sec> to change from hourly)
scripts/sconsole-scrshot-backup-deploy.sh      # links the command into ~/softwares/bin/scripts/, installs + starts the launchd job (runs a backup immediately)
scripts/sconsole-scrshot-backup-undeploy.sh    # stops + removes the launchd job and the link
```

Deploying creates `~/softwares/bin/scripts/sconsole-scrshot-backup` → `scripts/sconsole-scrshot-backup.sh`.
That folder is on PATH, and launchd runs the backup through the same link. Run a backup by hand:

```sh
sconsole-scrshot-backup                  # normal run: copy, check, delete remote
sconsole-scrshot-backup --keep-remote    # copy only
sconsole-scrshot-backup '/?'             # all options (quote /? in zsh)
```

Check on the job:

```sh
tail -f ~/Library/Logs/sconsole-scrshot-backup.log
launchctl print gui/$(id -u)/com.sandeep.sconsole-scrshot-backup | grep -E 'state|last exit'
launchctl kickstart gui/$(id -u)/com.sandeep.sconsole-scrshot-backup   # run now
```

Changes to `scripts/sconsole-scrshot-backup.sh` apply on the next run, because the link points at it.
After changing the schedule or the build script, build and deploy again.

## Layout

```
readme.md
scripts/
  sconsole-scrshot-backup.sh            the backup itself
  sconsole-scrshot-backup-build.sh      check scripts, generate target/ plist
  sconsole-scrshot-backup-deploy.sh     link command onto PATH, install launchd job
  sconsole-scrshot-backup-undeploy.sh   remove launchd job and link
target/                                 build output (generated)
  com.sandeep.sconsole-scrshot-backup.plist
```
