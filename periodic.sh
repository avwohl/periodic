#!/bin/bash
# periodic.sh - run scripts from configured directories on schedule
#
# Usage: periodic.sh [config_file]
#   config_file defaults to periodic.conf in the same directory as this script
#
# Each directory listed in PERIODIC_DIRS is scanned for executable *.sh files.
# Scripts run in glob (alphabetical) order.  pp_every tracks whether each
# script has already run this period (day/week/month) and skips it if so.
# A non-blocking file lock (pp_lock) prevents concurrent runs.

set -o errexit
set -o pipefail

# Consistent alphabetical glob ordering regardless of locale
export LC_COLLATE=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/periodic.conf}"

if [ ! -r "$CONFIG_FILE" ]; then
    echo "periodic: cannot read config: $CONFIG_FILE" >&2
    exit 1
fi

# Set built-in exports BEFORE sourcing config so the config can override them.
#   PP_DATE      YYYYMMDD     -- fixed for the whole run
#   PP_DATETIME  YYYYMMDD_HHMMSS -- fixed for the whole run (used in log name)
#   PERIODIC_DAY Mon/Tue/...  -- short day name
export PP_DATE="$(date +%Y%m%d)"
export PP_DATETIME="$(date +%Y%m%d_%H%M%S)"
export PERIODIC_DAY="$(date +%a)"

# Config is bash -- may set PERIODIC_DIRS and other variables
source "$CONFIG_FILE"

# Defaults (only applied if config did not set them)
: "${PERIODIC_LOGDIR:=/var/log/periodic}"
: "${PERIODIC_LOCKFILE:=/tmp/periodic.lock}"
: "${PERIODIC_TIMEDIR:=/var/lib/periodic/times}"
: "${PERIODIC_NICE:=20}"
: "${PERIODIC_MAILTO:=}"
: "${PERIODIC_TRACE:=}"
: "${PERIODIC_FAIL_TAIL:=200}"

export PERIODIC_LOGDIR PERIODIC_TIMEDIR PERIODIC_TRACE

mkdir -p "$PERIODIC_LOGDIR" "$PERIODIC_TIMEDIR" "$(dirname "$PERIODIC_LOCKFILE")"

# Empty glob expands to nothing instead of to the literal pattern
shopt -s nullglob

LOGFILE="${PERIODIC_LOGDIR}/periodic_${PP_DATETIME}.log"

# First invocation: redirect to log, wrap in nice + lock, re-exec
if [ -z "${_PERIODIC_LOCKED:-}" ]; then
    export _PERIODIC_LOCKED=1
    export _PERIODIC_LOGFILE="$LOGFILE"
    exec nice -n "$PERIODIC_NICE" \
        "${SCRIPT_DIR}/pp_lock" "$PERIODIC_LOCKFILE" \
        "$0" "$CONFIG_FILE" >> "$LOGFILE" 2>&1
fi

# --- Running under lock from here on ---

LOGFILE="${_PERIODIC_LOGFILE}"

# Optional shell-level trace: log every command this script (and each part)
# executes.  Uses BASH_ENV so the trace propagates into any nested bash
# invocation (e.g. 10-weekly.sh's `exec bash weekly.bash`) as well.
PERIODIC_BASH_ENV=""
if [ -n "$PERIODIC_TRACE" ]; then
    export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
    set -x
    PERIODIC_BASH_ENV="$(mktemp -t periodic.bashenv.XXXXXX)"
    {
        echo "export PS4='+ [\${BASH_SOURCE##*/}:\${LINENO}] '"
        echo "set -x"
    } > "$PERIODIC_BASH_ENV"
    export BASH_ENV="$PERIODIC_BASH_ENV"
    trap '[ -n "$PERIODIC_BASH_ENV" ] && rm -f "$PERIODIC_BASH_ENV"' EXIT
fi

echo "periodic: starting at $(date)"
echo "periodic: host=$(hostname -s) date=${PP_DATE} config=${CONFIG_FILE}"
[ -n "$PERIODIC_TRACE" ] && echo "periodic: trace mode ON (PERIODIC_TRACE=$PERIODIC_TRACE)"

if [ ${#PERIODIC_DIRS[@]} -eq 0 ]; then
    echo "periodic: PERIODIC_DIRS is empty, nothing to do"
    exit 0
fi

DID_SOMETHING=0

for dir_spec in "${PERIODIC_DIRS[@]}"; do
    # Parse "directory:frequency" -- frequency defaults to day
    dir="${dir_spec%%:*}"
    freq="${dir_spec#*:}"
    [ "$freq" = "$dir_spec" ] && freq="day"

    if [ ! -d "$dir" ]; then
        echo "periodic: directory not found, skipping: $dir"
        continue
    fi

    echo "periodic: scanning $dir ($freq)"

    for script in "$dir"/*.sh; do
        # nullglob means this loop is only entered if matches exist, but
        # keep the executable check -- non-executable .sh files are skipped.
        [ -x "$script" ] || continue

        script_key="$(echo "$script" | tr '/' '_')"
        timefile="${PERIODIC_TIMEDIR}/per${freq}.${script_key}"

        when="$("${SCRIPT_DIR}/pp_every" read "$freq" "$timefile")"
        read -r period_key status <<< "$when"

        if [ "$status" != "ok" ]; then
            echo "periodic: skip $script (done this $freq)"
            continue
        fi

        DID_SOMETHING=1
        echo "periodic: run  $script at $(date)"

        # Capture this part's combined output to a tempfile while still
        # tee'ing it live into the main log.  The tempfile lets us replay
        # the tail in the FAIL block below without scraping the main log.
        part_out="$(mktemp -t "periodic.$(basename "$script").XXXXXX")"

        # Trace propagates to bash children automatically via BASH_ENV.
        set +o errexit
        "$script" 2>&1 | tee "$part_out"
        rc=${PIPESTATUS[0]}
        set -o errexit

        if [ "$rc" != "0" ]; then
            # Decode signal vs ordinary exit code.
            if [ "$rc" -gt 128 ]; then
                signum=$((rc - 128))
                signame="$(kill -l "$signum" 2>/dev/null || echo unknown)"
                reason="killed by signal $signum (SIG$signame)"
            else
                reason="exit code $rc"
            fi
            echo "periodic: FAIL $script -- $reason at $(date)"
            echo "periodic: --- last ${PERIODIC_FAIL_TAIL} lines of $(basename "$script") output ---"
            tail -n "${PERIODIC_FAIL_TAIL}" "$part_out" | sed 's/^/  | /'
            echo "periodic: --- end FAIL detail for $(basename "$script") ---"

            if [ -n "$PERIODIC_MAILTO" ]; then
                {
                    echo "periodic part FAILED on $(hostname -s)"
                    echo "  script : $script"
                    echo "  reason : $reason"
                    echo "  when   : $(date)"
                    echo
                    echo "Last ${PERIODIC_FAIL_TAIL} lines of script output:"
                    echo "----"
                    tail -n "${PERIODIC_FAIL_TAIL}" "$part_out"
                    echo "----"
                    echo
                    echo "Full log: ${LOGFILE}"
                } | mail -s "FAIL $(hostname -s) periodic: $(basename "$script") ($reason)" \
                    "$PERIODIC_MAILTO"
            fi
            rm -f "$part_out"
            exit 1
        fi
        rm -f "$part_out"

        "${SCRIPT_DIR}/pp_every" write "$period_key" "$timefile"
        echo "periodic: ok   $script at $(date)"
    done
done

echo "periodic: finished at $(date)"

if [ "$DID_SOMETHING" = "1" ] && [ -n "$PERIODIC_MAILTO" ]; then
    mail -s "ok periodic $(hostname -s)" "$PERIODIC_MAILTO" < "$LOGFILE"
fi
