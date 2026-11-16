# system-utils

Home for projects that automate local system needs on this Mac (macOS, zsh). Each automation is its own subfolder.

## Project layout

```
<project>/
├── readme.md              # what it does; how to set up, configure, build, deploy and run it
├── pom.xml                # only for Maven/Java projects
├── scripts/               # operational scripts
│   ├── <project>-build.sh
│   ├── <project>-deploy.sh
│   └── ...                # other ops scripts (start, stop, cleanup, ...)
├── src/main/
│   ├── java/              # Java sources
│   ├── python/            # Python sources
│   ├── dbscripts/         # SQL / database scripts
│   └── web/               # static status pages, copied into the Caddy site on deploy
└── target/                # build output (binaries); generated, never edited by hand
```

- Only create the `src/main/*` folders a project actually uses. A shell-only project may have just `readme.md` and `scripts/`.
- Every new project starts with a `readme.md` and `scripts/<project>-build.sh` (and `-deploy.sh` if it gets installed anywhere).
- **Deploying scripts**: `<project>-deploy.sh` puts a symlink to each user-facing script in `~/softwares/bin/scripts/` (on PATH via `~/.zshrc`). The link is named without `.sh` (e.g. `sconsole-scrshot-backup` → `<project>/scripts/sconsole-scrshot-backup.sh`). Anything scheduled (launchd) runs the script through that link. `-undeploy.sh` removes the link.
- Ops scripts should be safe to run more than once, and should work from any folder (resolve paths relative to the script, not the caller).
- Keep secrets out of the project folders.

## Script standard

Every script (bash, `#!/bin/bash`; keep to bash 3.2 so macOS `/bin/bash` and launchd can run it) follows this shape:

1. **Header**: a comment block right after the shebang, between `# ====` rule lines, giving the script name, purpose, usage line, every parameter with its default, and exit codes.
2. **Functions**: all logic lives in small functions. Each has a comment block above it:
   ```bash
   # -----------------------------------------------------------------------------
   # <name>
   #   Purpose : what it does
   #   Input   : $1 - ...; globals read
   #   Output  : stdout/files/globals set; return code meaning
   # -----------------------------------------------------------------------------
   ```
3. **`print_usage()`**: prints the header's usage text. It runs on `/?` (also `-h`, `--help`), and on bad arguments with exit code 2. In zsh, quote it: `script.sh '/?'`.
4. **Main**: the driving logic comes last, after a `# --- main ---` line, and only calls functions.

Python scripts (`#!/usr/bin/python3`, Apple's 3.9, standard library only) follow the same four rules: the same `# ====` header block, the same function comment blocks, a `print_usage()` that prints the header on `/?`, `-h` or `--help`, and the driving logic under `# --- main ---` inside `if __name__ == "__main__":`.

## Publishing job status (Caddy)

Until syshub replaces it, Caddy (`~/softwares/logncfgs/caddy/Caddyfile`, LaunchAgent `local.caddy`) serves `~/softwares/workspace/caddy/site/` as plain files. A scheduled job publishes its status the way db-backup does (see `sconsole-scrshot-backup` for a full example):
- **Workspace:** the job uses `~/softwares/workspace/<project>/` for `logs/YYYY-MM-DD.log`, a `status` file and `work/.lock`. Each run is logged between `=== <project> start` and `=== <project> OK` / `=== <project> FINISHED WITH ERRORS: ...` lines.
- **Status builder:** a `<project>-status` script with its own LaunchAgent (WatchPaths on `status` and `work/`, plus a timer). It parses the logs into `site/<page>/status.json`, written atomically.
- **Page:** `src/main/web/index.html` is copied to `site/<page>/` on deploy, and a card on `site/index.html` links to it.
