# deploy_agent — Automated Project Bootstrapping & Process Management

`deploy_agent.sh` deploys, runs and archives the logs of the **Student Attendance Tracker**
(`attendance_checker.py`), and cleanly handles **Ctrl+C / Ctrl+Z** while a deployment is in progress.
`attendance_checker.py` is never modified — everything here is shell scripting around it.

## Repository layout

```
deploy_agent_<GithubUsername>/
├── deploy_agent.sh          # the master script (3 features + signal handling)
├── README.md
├── .gitignore               # keeps generated projects / zips out of git
└── templates/               # unmodified source files
    ├── attendance_checker.py
    ├── assets.csv
    └── config.json
```

A deployed project (`attendance_tracker_<name>/`) looks like this — the exact layout the Python app expects:

```
attendance_tracker_<name>/
├── attendance_checker.py
├── Helpers/
│   ├── assets.csv
│   └── config.json
└── reports/                 # starts empty; the app creates attendance.log / absent.log
```

## Requirements

`bash`, `python3`, `zip` (checked automatically in pre-flight; the script fails early with install hints if one is missing).

## How to run the script and select a feature

I chose **both** an interactive menu and command-line flags. Run from the repository folder:

```bash
chmod +x deploy_agent.sh      # once
./deploy_agent.sh             # interactive menu
```

```
1) Deploy a new project     2) Run an existing project
3) Archive logs of a project   4) Exit
```

or jump straight to a feature:

| Command | Feature |
|---|---|
| `./deploy_agent.sh --deploy` | 1 – Deploy |
| `./deploy_agent.sh --run [name]` | 2 – Run (asks for the name if omitted) |
| `./deploy_agent.sh --archive [name]` | 3 – Archive logs (asks for the name if omitted) |
| `./deploy_agent.sh --help` | usage |

`name` is the part after `attendance_tracker_` (e.g. `v1`); passing the full folder name also works.
Projects, zip files and templates all live next to the script, so it works from any current directory.

## Feature 1 — Deploy

1. **Pre-flight** – verifies `python3` and `zip` exist, runs `python3 --version` to confirm a working Python 3 (the version is printed), checks the three template files are present and readable, and checks the folder is writable. Any problem stops the deployment early with a clear message.
2. **Name** – asks (`read`) for a name and creates `attendance_tracker_<name>/`. Only letters, digits, `-` and `_` are accepted. If the directory already exists you are asked whether to overwrite; answering anything but `y` aborts with an error and leaves the existing directory untouched.
3. **Populate** – `attendance_checker.py` and `config.json` are copied unmodified from `templates/`. For the roster you choose:
   - **Option A – copy from template:** asks how many students (1–10) and copies the header + that many rows.
   - **Option B – generate fresh:** asks how many students (1–20) and builds rows from sample name/email arrays inside the script, with counts `0,0`.
4. **Permissions** – `chmod +x attendance_checker.py`, `chmod 600 Helpers/config.json`; a confirmation with the resulting `ls -l` modes is printed.
5. **Thresholds** – see below.
6. **Verify** – prints a structure checklist, then launches the app (Feature 2). A successful startup shows the structure, roster and config work together.

### `total_sessions` stays consistent with the roster

`total_sessions` in `config.json` counts **all** sessions including today's, so it must be *prior sessions + 1*.

| Roster | Prior sessions per student | `total_sessions` |
|---|---|---|
| Option A (template rows, e.g. Alice 4+0) | 4 | **5** (template shipped as-is) |
| Option B (fresh, 0/0) | 0 | **1** (set automatically by the script) |

This is done without any extra prompt. For Option B the script changes only the `"total_sessions"` value in the *deployed* copy; `templates/config.json` is never touched. (If the numbers ever disagree, the app prints a "proceeding anyway" note.)

### How the threshold update works

After permissions are set, the script asks *"Update the attendance alert thresholds? [y/N]"*. On `y` it uses `read` to capture:

- **warning** (default **75**, press Enter to accept)
- **failure** (default **50**)

Inputs must be whole numbers 0–100 and `failure` must be lower than `warning` (otherwise it asks again). It then edits the file **in place with `sed`**, targeting just the two lines:

```bash
sed -i.bak -E -e 's/("warning":[[:space:]]*)[0-9]+/\1<new>/' \
              -e 's/("failure":[[:space:]]*)[0-9]+/\1<new>/' Helpers/config.json
```

Nothing is reordered or reformatted (`diff templates/config.json Helpers/config.json` shows exactly two changed lines), the temporary `.bak` is removed, and mode `600` is re-applied afterwards.

### Error handling during deploy

Every setup step (`mkdir`, `cp`, `chmod`, writing the roster, `sed`) is checked. If one fails — for example *Permission denied* — the script prints which step failed together with the system's message, removes the incomplete project directory so nothing is left behind, and exits with a non-zero status. Invalid input (bad project name, non-numeric or out-of-range counts/thresholds) is rejected and re-prompted rather than passed on to `sed`.

## Feature 2 — Run

`./deploy_agent.sh --run <name>` checks the project structure and then runs
`cd attendance_tracker_<name> && python3 attendance_checker.py`. The app is interactive: it asks `[P]resent or [A]bsent?` for each student, updates `Helpers/assets.csv`, and appends to `reports/attendance.log` and `reports/absent.log`. Signal trapping is **not** active here — the app handles its own Ctrl+C.

## Feature 3 — Archive the logs

`./deploy_agent.sh --archive <name>` checks for `reports/attendance.log` and `reports/absent.log` and archives each one that exists into its own directory with a timestamped name:

```
attendance_tracker_<name>/
└── archives/
    ├── attendance/attendance_YYYYMMDD_HHMMSS.log
    └── absent/absent_YYYYMMDD_HHMMSS.log
```

- The timestamp comes from `date +%Y%m%d_%H%M%S`, so every archive is unique and traceable.
- Logs are **moved** (log-rotation style), so the next session starts with fresh logs and archives never contain duplicated history.
- A confirmation lists each archived log with its final path.
- If a log doesn't exist (e.g. nobody was absent, so no `absent.log`) it prints `[skipped]` for that file and carries on — no crash. If neither exists it says so and suggests running the app first.

## Signal handling: Ctrl+C and Ctrl+Z

While Feature 1 is running (from the name prompt until setup finishes) `SIGINT` and `SIGTSTP` are trapped. On either one the script:

1. prints that the deployment was **interrupted** (and by which signal);
2. zips whatever exists of `attendance_tracker_<name>/` into **`attendance_tracker_<name>_archive.zip`** (using the `zip` command), listing the zip contents;
3. removes the half-built directory, prints "Session closed cleanly" and exits (code `130` for Ctrl+C, `148` for Ctrl+Z).

Details: if the interrupt arrives before anything was created (e.g. at the name prompt), it just says so and creates no zip; if it arrives at the *overwrite* prompt, the existing directory is left completely untouched; end-of-input (stdin closed) during deployment is treated the same way. The traps are removed once setup completes, so the marking session in the Python app is unaffected.

### How to test it

```bash
./deploy_agent.sh --deploy
# enter a name, e.g. demo, choose A, then at the "How many students" prompt press Ctrl+C (or Ctrl+Z)
ls                                        # attendance_tracker_demo_archive.zip exists, the folder is gone
unzip -l attendance_tracker_demo_archive.zip
```

**What the zip contains** is whatever had been created when you interrupted. Interrupt at the roster prompt → the folder skeleton plus `attendance_checker.py` and `Helpers/config.json`. Interrupt at the threshold prompt → also `Helpers/assets.csv`. Everything is stored under the `attendance_tracker_<name>/` folder inside the zip.

## How the deployed structure was tested

- **Built-in check:** after setup, the script checks that `attendance_checker.py`, `Helpers/assets.csv`, `Helpers/config.json` and `reports/` exist (printing `[ok]`/`[MISSING]`) and then actually runs the app; `--run` repeats the check and refuses to run an incomplete project.
- **Manual checks** I ran: `find attendance_tracker_<name> | sort` (layout), `ls -l` (`-rwxr-xr-x` script, `-rw-------` config), `diff templates/config.json Helpers/config.json` (only the two threshold lines differ), roster contents/counts after a marking session, and `cmp` to confirm `templates/` are byte-identical to the originals.
- **Scenarios exercised:** Option A (10 students, thresholds 80/60, mixed P/A marking – counts and alerts updated correctly); Option B (3 students, `total_sessions: 1`); archive with both logs, with only `attendance.log` (nobody absent), and with none; overwrite → `n` (untouched) and → `y` (fresh); invalid name/option/count/threshold input; missing project and unknown flag; a broken `python3` (pre-flight stops), an unwritable folder (run as a non-root user), and a failing `chmod` mid-deploy (clear error, incomplete directory removed); and Ctrl+C / Ctrl+Z (both as real signals and as real keystrokes through a pseudo-terminal) at several points of the deployment.

## Notes

- Run the script from a terminal; it is interactive by design.
- Generated `attendance_tracker_*/` folders and `*_archive.zip` files are git-ignored.
