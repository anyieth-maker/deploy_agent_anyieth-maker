#!/usr/bin/env bash
# =============================================================================
# deploy_agent.sh - Automated Project Bootstrapping & Process Management
#
# Deploys, runs and archives logs for the Student Attendance Tracker
# (attendance_checker.py), and handles Ctrl+C / Ctrl+Z cleanly while deploying.
#
# Usage:
#   ./deploy_agent.sh                    interactive menu
#   ./deploy_agent.sh --deploy           Feature 1: deploy a new project
#   ./deploy_agent.sh --run [name]       Feature 2: run a deployed project
#   ./deploy_agent.sh --archive [name]   Feature 3: archive the logs
#   ./deploy_agent.sh --help
# =============================================================================

# Everything (templates, projects, zip files) lives next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || { echo "ERROR: cannot enter $SCRIPT_DIR" >&2; exit 1; }

TEMPLATES_DIR="templates"
PREFIX="attendance_tracker_"

# Deployment state used by the signal handler.
DEPLOY_ACTIVE=0      # 1 while Feature 1 is in progress (signals are trapped)
DEPLOY_STARTED=0     # 1 once the project directory has been created
PROJECT_DIR=""

# Sample data for Option B (fresh roster). Parallel arrays: name <-> email.
SAMPLE_NAMES=(
  "Amara Okafor" "Brian Mugisha" "Chloe Martin" "Daniel Atwood" "Esther Wanjiru"
  "Farid Hassan" "Grace Achieng" "Hugo Silva" "Imani Joseph" "Jonas Weber"
  "Kofi Boateng" "Layla Ahmed" "Mateo Garcia" "Nia Thompson" "Omar Khalid"
  "Priya Nair" "Quinn Murphy" "Rita Kamau" "Samuel Deng" "Tara Wilson"
)
SAMPLE_EMAILS=(
  "amara@example.com" "brian@example.com" "chloe@example.com" "daniel@example.com" "esther@example.com"
  "farid@example.com" "grace@example.com" "hugo@example.com" "imani@example.com" "jonas@example.com"
  "kofi@example.com" "layla@example.com" "mateo@example.com" "nia@example.com" "omar@example.com"
  "priya@example.com" "quinn@example.com" "rita@example.com" "samuel@example.com" "tara@example.com"
)

# -----------------------------------------------------------------------------
# Small helpers
# -----------------------------------------------------------------------------
err()  { echo "ERROR: $*" >&2; }
info() { echo "$*"; }

# ask VAR "prompt"  - read a line into VAR. On end-of-input, stop cleanly.
ask() {
  local __answer
  if ! read -r -p "$2" __answer; then
    echo
    on_eof
  fi
  printf -v "$1" '%s' "$__answer"
}

# ask_int VAR "prompt" MIN MAX [DEFAULT] - keep asking until a valid integer.
ask_int() {
  local __var="$1" __prompt="$2" __min="$3" __max="$4" __default="${5:-}" __in
  while true; do
    ask __in "$__prompt"
    [[ -z "$__in" && -n "$__default" ]] && __in="$__default"
    if [[ "$__in" =~ ^[0-9]+$ ]] && (( __in >= __min && __in <= __max )); then
      printf -v "$__var" '%s' "$__in"
      return 0
    fi
    echo "  Please enter a whole number between $__min and $__max."
  done
}

is_yes() { [[ "$1" =~ ^[Yy]([Ee][Ss])?$ ]]; }

on_eof() {
  if (( DEPLOY_ACTIVE )); then
    handle_interrupt "end of input" 1
  fi
  err "Input ended unexpectedly. Exiting."
  exit 1
}

# -----------------------------------------------------------------------------
# Signal handling (Ctrl+C = SIGINT, Ctrl+Z = SIGTSTP) - active only in deploy
# -----------------------------------------------------------------------------
handle_interrupt() {
  local reason="$1" code="$2"
  trap '' INT TSTP            # ignore further signals while we clean up
  echo
  echo "!! Deployment interrupted ($reason)."

  if (( DEPLOY_STARTED )) && [[ -d "$PROJECT_DIR" ]]; then
    local zipfile="${PROJECT_DIR}_archive.zip"
    rm -f "$zipfile"
    echo "   Archiving the incomplete project into $zipfile ..."
    if zip -rq "$zipfile" "$PROJECT_DIR"; then
      echo "   Archive created. Contents:"
      zip -sf "$zipfile" | sed 's/^/     /'
      rm -rf "$PROJECT_DIR"
      echo "   Removed the half-built directory $PROJECT_DIR/."
    else
      err "zip failed - leaving $PROJECT_DIR/ in place so nothing is lost."
    fi
  else
    echo "   Nothing had been created yet, so there is nothing to archive."
  fi

  echo "   Session closed cleanly."
  exit "$code"
}

arm_traps()    { trap 'handle_interrupt "SIGINT (Ctrl+C)" 130' INT
                 trap 'handle_interrupt "SIGTSTP (Ctrl+Z)" 148' TSTP; }
disarm_traps() { trap - INT TSTP; }

# -----------------------------------------------------------------------------
# Shared helpers: pre-flight, structure check, project name resolution
# -----------------------------------------------------------------------------
preflight() {
  local ok=0 cmd f pyver
  for cmd in python3 zip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "'$cmd' is not installed or not on your PATH."
      case "$cmd" in
        zip)     echo "       Install it with e.g.:  sudo apt install zip   (or: brew install zip)" >&2 ;;
        python3) echo "       Install Python 3 from https://www.python.org/downloads/" >&2 ;;
      esac
      ok=1
    fi
  done

  # Health check: python3 must actually run (python3 --version) and be Python 3.
  if command -v python3 >/dev/null 2>&1; then
    if pyver="$(python3 --version 2>&1)" && [[ "$pyver" == "Python 3"* ]]; then
      info "python3 --version -> $pyver"
    else
      err "'python3 --version' did not report a working Python 3 (got: ${pyver:-no output})."
      ok=1
    fi
  fi

  for f in attendance_checker.py assets.csv config.json; do
    if [[ ! -f "$TEMPLATES_DIR/$f" ]]; then
      err "missing template file: $TEMPLATES_DIR/$f"
      ok=1
    elif [[ ! -r "$TEMPLATES_DIR/$f" ]]; then
      err "permission denied: cannot read template file $TEMPLATES_DIR/$f (fix with: chmod u+r $TEMPLATES_DIR/$f)"
      ok=1
    fi
  done

  # Permission check: we must be able to create the project (and zip) here.
  if [[ ! -w "$SCRIPT_DIR" ]]; then
    err "permission denied: no write access to '$SCRIPT_DIR', so projects cannot be created here."
    ok=1
  fi

  if (( ok )); then
    err "Pre-flight checks failed. Fix the problems above and try again."
    return 1
  fi
  info "Pre-flight checks passed (python3, zip, templates and write access all OK)."
}

# run_step "description" cmd args... - run a command; on failure print a clear
# error including the system message (e.g. "Permission denied") and return 1.
run_step() {
  local desc="$1" out
  shift
  if ! out="$("$@" 2>&1)"; then
    err "$desc failed: ${out:-unknown error}"
    return 1
  fi
}

# check_structure DIR [verbose]
check_structure() {
  local dir="$1" verbose="${2:-}" missing=0 item
  local items=(
    "$dir/attendance_checker.py"
    "$dir/Helpers/assets.csv"
    "$dir/Helpers/config.json"
    "$dir/reports"
  )
  for item in "${items[@]}"; do
    if [[ -e "$item" ]]; then
      [[ -n "$verbose" ]] && echo "   [ok]      $item"
    else
      echo "   [MISSING] $item"
      missing=1
    fi
  done
  return $missing
}

# resolve_project [name-from-flag] -> sets PROJECT_DIR (must already exist)
resolve_project() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    local found
    found="$(ls -d ${PREFIX}*/ 2>/dev/null | sed 's:/$::' | tr '\n' ' ')"
    [[ -n "$found" ]] && echo "Deployed projects: $found"
    ask name "Project name (the part after ${PREFIX}): "
  fi
  name="${name%/}"
  name="${name#$PREFIX}"
  if [[ -z "$name" ]]; then
    err "No project name given."
    return 1
  fi
  PROJECT_DIR="${PREFIX}${name}"
  if [[ ! -d "$PROJECT_DIR" ]]; then
    err "Project directory '$PROJECT_DIR' does not exist. Deploy it first (option 1)."
    return 1
  fi
}

# -----------------------------------------------------------------------------
# FEATURE 2: run the application
# -----------------------------------------------------------------------------
run_app() {
  local dir="$1"
  if ! check_structure "$dir"; then
    err "'$dir' is not a complete deployment - refusing to run."
    return 1
  fi
  echo
  echo ">>> Starting the attendance checker in $dir/ ..."
  ( cd "$dir" && python3 attendance_checker.py )
  local rc=$?
  echo
  case "$rc" in
    0)   info ">>> Application finished normally (exit 0)." ;;
    130) info ">>> Marking stopped early with Ctrl+C inside the app (exit 130); progress was saved by the app." ;;
    *)   err  ">>> Application exited with status $rc - check the messages above." ;;
  esac
  return "$rc"
}

# -----------------------------------------------------------------------------
# FEATURE 3: archive the logs
# -----------------------------------------------------------------------------
archive_logs() {
  resolve_project "${1:-}" || return 1
  local dir="$PROJECT_DIR" ts kind src dest archived=0
  ts="$(date +%Y%m%d_%H%M%S)"

  echo "Archiving logs for $dir (timestamp $ts) ..."
  for kind in attendance absent; do
    src="$dir/reports/${kind}.log"
    if [[ -f "$src" ]]; then
      mkdir -p "$dir/archives/$kind" || { err "cannot create $dir/archives/$kind"; continue; }
      dest="$dir/archives/$kind/${kind}_${ts}.log"
      [[ -e "$dest" ]] && dest="$dir/archives/$kind/${kind}_${ts}_$$.log"
      if mv "$src" "$dest"; then
        echo "   [archived] $src -> $dest"
        archived=$((archived + 1))
      else
        err "could not archive $src"
      fi
    else
      echo "   [skipped]  $src does not exist (nothing was logged for it, e.g. nobody was absent)."
    fi
  done

  if (( archived == 0 )); then
    echo "No logs were archived. Run the application first (option 2) to generate logs."
  else
    echo "Done: $archived log file(s) archived. The originals were moved out of reports/ so the next session starts a fresh log."
  fi
  return 0
}

# -----------------------------------------------------------------------------
# FEATURE 1: deploy - building blocks
# -----------------------------------------------------------------------------
build_roster() {
  local csv="$PROJECT_DIR/Helpers/assets.csv"
  local cfg="$PROJECT_DIR/Helpers/config.json"
  local choice n i

  echo
  echo "How should the student roster be built?"
  echo "  A) Copy students from the template (4 prior sessions each -> total_sessions stays 5)"
  echo "  B) Generate a fresh roster (all counts start at 0 -> total_sessions set to 1)"
  while true; do
    ask choice "Choose A or B: "
    case "$choice" in
      [Aa]|[Bb]) break ;;
      *) echo "  Please enter A or B." ;;
    esac
  done

  if [[ "$choice" =~ ^[Aa]$ ]]; then
    local available
    available="$(tail -n +2 "$TEMPLATES_DIR/assets.csv" | grep -c .)"
    ask_int n "How many students to copy (1-$available)? " 1 "$available"
    if ! head -n $((n + 1)) "$TEMPLATES_DIR/assets.csv" > "$csv" 2>/dev/null; then
      err "cannot write the roster to $csv (permission denied or disk full?)"
      return 1
    fi
    echo "Copied header + $n student row(s) from the template. total_sessions stays at 5 (4 prior sessions + today)."
  else
    local max=${#SAMPLE_NAMES[@]}
    ask_int n "How many students to generate (1-$max)? " 1 "$max"
    {
      echo "Email,Names,Attendance Count,Absence Count"
      for (( i = 0; i < n; i++ )); do
        echo "${SAMPLE_EMAILS[$i]},${SAMPLE_NAMES[$i]},0,0"
      done
    } > "$csv" 2>/dev/null || { err "cannot write the roster to $csv (permission denied or disk full?)"; return 1; }
    # Fresh roster = first session ever, so total_sessions must be 1.
    run_step "setting total_sessions in config.json" \
      sed -i.bak -E 's/("total_sessions":[[:space:]]*)[0-9]+/\11/' "$cfg" || return 1
    rm -f "$cfg.bak"
    echo "Generated $n student(s) with 0/0 counts. total_sessions set to 1 (this is the first session)."
  fi
}

set_permissions() {
  local script="$PROJECT_DIR/attendance_checker.py"
  local cfg="$PROJECT_DIR/Helpers/config.json"
  run_step "making attendance_checker.py executable (chmod +x)" chmod +x "$script" || return 1
  run_step "restricting config.json to owner read/write (chmod 600)" chmod 600 "$cfg" || return 1
  echo
  echo "Permissions set:"
  echo "   $(ls -l "$script" | awk '{print $1}')  $script   (executable)"
  echo "   $(ls -l "$cfg"    | awk '{print $1}')  $cfg   (owner read/write only)"
}

offer_thresholds() {
  local cfg="$PROJECT_DIR/Helpers/config.json"
  local ans warn fail
  echo
  ask ans "Update the attendance alert thresholds in config.json? [y/N]: "
  if ! is_yes "$ans"; then
    echo "Keeping default thresholds (warning 75, failure 50)."
    return 0
  fi

  while true; do
    ask_int warn "  Warning threshold % [default 75]: " 0 100 75
    ask_int fail "  Failure threshold % [default 50]: " 0 100 50
    (( fail < warn )) && break
    echo "  The failure threshold ($fail) must be lower than the warning threshold ($warn). Try again."
  done

  # Edit ONLY the "warning" and "failure" values, in place (no reformatting).
  run_step "updating thresholds in config.json" sed -i.bak -E \
    -e "s/(\"warning\":[[:space:]]*)[0-9]+/\1${warn}/" \
    -e "s/(\"failure\":[[:space:]]*)[0-9]+/\1${fail}/" \
    "$cfg" || return 1
  rm -f "$cfg.bak"
  run_step "re-applying chmod 600 to config.json" chmod 600 "$cfg" || return 1

  echo "Thresholds updated in $cfg:"
  grep -E '"(warning|failure)"' "$cfg" | sed 's/^ */   /'
}

# -----------------------------------------------------------------------------
# FEATURE 1: deploy
# -----------------------------------------------------------------------------
abort_deploy() {
  err "$1"
  DEPLOY_ACTIVE=0
  disarm_traps
  # Leave no half-made project behind after a failed setup.
  if (( DEPLOY_STARTED )) && [[ -d "$PROJECT_DIR" ]]; then
    if rm -rf "$PROJECT_DIR" 2>/dev/null; then
      echo "Removed the incomplete directory $PROJECT_DIR/ (nothing was left behind)." >&2
    else
      err "could not remove $PROJECT_DIR/ - please delete it manually."
    fi
  fi
  DEPLOY_STARTED=0
}

deploy() {
  local name ans
  DEPLOY_STARTED=0
  PROJECT_DIR=""

  echo "=== Feature 1: Deploy the application ==="
  preflight || return 1

  # From here until setup finishes, Ctrl+C / Ctrl+Z are handled.
  DEPLOY_ACTIVE=1
  arm_traps

  while true; do
    ask name "Enter a project name (will create ${PREFIX}<name>): "
    if [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then break; fi
    echo "  Use only letters, digits, '-' and '_' (no spaces or slashes)."
  done
  PROJECT_DIR="${PREFIX}${name}"

  if [[ -e "$PROJECT_DIR" ]]; then
    ask ans "'$PROJECT_DIR' already exists. Overwrite it? [y/N]: "
    if ! is_yes "$ans"; then
      abort_deploy "Aborted: '$PROJECT_DIR' already exists and was left untouched."
      return 1
    fi
    run_step "removing the existing '$PROJECT_DIR'" rm -rf "$PROJECT_DIR" \
      || { abort_deploy "Could not overwrite '$PROJECT_DIR' (check its permissions)."; return 1; }
    echo "Existing directory removed."
  fi

  DEPLOY_STARTED=1
  run_step "creating the directory structure" mkdir -p "$PROJECT_DIR/Helpers" "$PROJECT_DIR/reports" \
    || { abort_deploy "Could not create the directory structure."; return 1; }
  run_step "copying attendance_checker.py" cp "$TEMPLATES_DIR/attendance_checker.py" "$PROJECT_DIR/attendance_checker.py" \
    && run_step "copying config.json" cp "$TEMPLATES_DIR/config.json" "$PROJECT_DIR/Helpers/config.json" \
    || { abort_deploy "Could not copy the template files."; return 1; }
  echo "Created $PROJECT_DIR/ with Helpers/ and reports/, copied attendance_checker.py and config.json."

  build_roster       || { abort_deploy "could not build the roster"; return 1; }
  set_permissions    || { abort_deploy "could not set permissions"; return 1; }
  offer_thresholds   || { abort_deploy "could not update thresholds"; return 1; }

  # Setup finished: stop trapping so the marking session behaves normally.
  DEPLOY_ACTIVE=0
  DEPLOY_STARTED=0
  disarm_traps

  echo
  echo "Deployment structure:"
  if ! check_structure "$PROJECT_DIR" verbose; then
    err "Deployment verification failed."
    return 1
  fi

  echo
  echo "Verifying the deployment by launching the application (mark a few students, Ctrl+C in the app to stop early)."
  run_app "$PROJECT_DIR"
  local rc=$?
  echo "Tip: archive the logs afterwards with:  ./deploy_agent.sh --archive ${name}"
  return $rc
}

# -----------------------------------------------------------------------------
# Menu / argument handling
# -----------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: ./deploy_agent.sh [option]

  (no option)          interactive menu
  --deploy             Feature 1: deploy a new attendance tracker project
  --run [name]         Feature 2: run a deployed project
  --archive [name]     Feature 3: archive reports/*.log with timestamps
  -h, --help           show this help

Projects are created as ${PREFIX}<name>/ next to this script.
EOF
}

menu() {
  local choice
  while true; do
    echo
    echo "========= Attendance Tracker Deploy Agent ========="
    echo "  1) Deploy a new project"
    echo "  2) Run an existing project"
    echo "  3) Archive logs of a project"
    echo "  4) Exit"
    ask choice "Select an option [1-4]: "
    case "$choice" in
      1) deploy ;;
      2) preflight >/dev/null || continue
         resolve_project && run_app "$PROJECT_DIR" ;;
      3) archive_logs ;;
      4|q|Q) echo "Goodbye."; exit 0 ;;
      *) echo "Please choose 1, 2, 3 or 4." ;;
    esac
  done
}

case "${1:-}" in
  "")            menu ;;
  -d|--deploy)   deploy; exit $? ;;
  -r|--run)      preflight >/dev/null || exit 1
                 resolve_project "${2:-}" && run_app "$PROJECT_DIR"; exit $? ;;
  -a|--archive)  archive_logs "${2:-}"; exit $? ;;
  -h|--help)     usage; exit 0 ;;
  *)             err "Unknown option: $1"; usage; exit 1 ;;
esac
