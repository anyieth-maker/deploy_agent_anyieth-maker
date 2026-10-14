# deploy_agent

`deploy_agent.sh` deploys, runs and archives the logs of the Student Attendance Tracker (`attendance_checker.py`, unmodified), and handles Ctrl+C / Ctrl+Z cleanly during deployment.

```
deploy_agent_<username>/
├── deploy_agent.sh
├── README.md
└── templates/   (attendance_checker.py, assets.csv, config.json - unmodified)
```

## Requirements
`bash`, `python3`, `zip`. Pre-flight prints `python3 --version` and stops with a clear message if anything is missing, a template is unreadable, or the folder isn't writable.
Linux/macOS/WSL usually have `zip` (`sudo apt install zip`). Git Bash on Windows does not include it: use WSL or add `zip.exe` + `bzip2.dll` to `~/bin`.

## Running and choosing a feature
```bash
chmod +x deploy_agent.sh
./deploy_agent.sh              # interactive menu (1 Deploy, 2 Run, 3 Archive, 4 Exit)
./deploy_agent.sh --deploy     # Feature 1
./deploy_agent.sh --run  [name]    # Feature 2
./deploy_agent.sh --archive [name] # Feature 3
```
`name` is the part after `attendance_tracker_`.

## Feature 1 - Deploy
1. Pre-flight checks (above).
2. Asks for a name and creates `attendance_tracker_<name>/` with `Helpers/` and `reports/`. If it exists, you choose overwrite or abort (nothing is silently overwritten).
3. Copies `attendance_checker.py` and `config.json` from `templates/`. Roster: **A** copies N rows from the template; **B** generates N fresh students (counts 0/0) from arrays in the script.
4. `chmod +x attendance_checker.py`, `chmod 600 Helpers/config.json`, and prints the resulting permissions.
5. Offers to update thresholds, then verifies the deployment by launching the app (Feature 2).

**`total_sessions`** = prior sessions + 1. Option A rows have 4 prior sessions, so `total_sessions` stays 5. Option B starts at 0, so the script sets it to 1 (deployed copy only).

**Threshold update:** answer `y`, then enter warning (default 75) and failure (default 50). Input must be a number 0-100 and failure must be lower than warning, otherwise it re-asks (empty input = default). Only the `"warning"` and `"failure"` lines are changed, in place with `sed`; nothing is reformatted and mode 600 is re-applied.

**Errors:** every setup step is checked; on failure the script prints the failing step and system message (e.g. *Permission denied*), removes the incomplete directory, and exits non-zero.

## Feature 2 - Run
Checks the structure, then runs `cd attendance_tracker_<name> && python3 attendance_checker.py` (interactive: mark each student P/A).

## Feature 3 - Archive logs
Run after a session. For each existing log in `reports/`, the script moves it to a timestamped file:
```
attendance_tracker_<name>/archives/attendance/attendance_YYYYMMDD_HHMMSS.log
attendance_tracker_<name>/archives/absent/absent_YYYYMMDD_HHMMSS.log
```
It prints which logs were archived and their final paths. A missing log (e.g. nobody was absent, so no `absent.log`) is reported as skipped without crashing.

## Ctrl+C / Ctrl+Z handling
During deployment (from the name prompt until setup finishes) SIGINT and SIGTSTP are trapped. On either signal the script prints that the deployment was interrupted, runs `zip` to bundle whatever exists into `attendance_tracker_<name>_archive.zip`, **deletes the incomplete directory**, and exits cleanly (130 for Ctrl+C, 148 for Ctrl+Z). If nothing was created yet, no zip is made; an existing directory at the overwrite prompt is left untouched.

**Test it:**
```bash
./deploy_agent.sh --deploy     # name: demo, choose A, then press Ctrl+C (or Ctrl+Z) at the next prompt
ls                              # demo folder gone, attendance_tracker_demo_archive.zip present
unzip -l attendance_tracker_demo_archive.zip
```
The zip contains the partial project as it was at that moment, e.g. `attendance_checker.py`, `Helpers/config.json` and empty `reports/` (plus `Helpers/assets.csv` if interrupted later).

## How the deployment was tested
- Structure: `find attendance_tracker_<name> | sort`, `ls -l` (script `-rwxr-xr-x`, config `-rw-------`), and `diff templates/config.json Helpers/config.json` (only the threshold lines differ); the script also checks the layout itself and runs the app.
- Scenarios: Option A and B; threshold update and invalid inputs; roster/counts after a marking session; archive with both logs, one log, and none; overwrite yes/no; missing project and unknown flag; broken `python3`; unwritable folder; failing `chmod` mid-deploy; Ctrl+C and Ctrl+Z at several prompts (as real signals and as keystrokes in a pseudo-terminal).
