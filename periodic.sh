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

export PERIODIC_LOGDIR PERIODIC_TIMEDIR

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

echo "periodic: starting at $(date)"
echo "periodic: host=$(hostname -s) date=${PP_DATE} config=${CONFIG_FILE}"

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

        set +o errexit
        "$script"
        rc=$?
        set -o errexit

        if [ "$rc" != "0" ]; then
            echo "periodic: FAIL $script exit=$rc at $(date)"
            if [ -n "$PERIODIC_MAILTO" ]; then
                mail -s "FAIL $(hostname -s) periodic: $(basename "$script")" \
                    "$PERIODIC_MAILTO" < "$LOGFILE"
            fi
            exit 1
        fi

        "${SCRIPT_DIR}/pp_every" write "$period_key" "$timefile"
        echo "periodic: ok   $script at $(date)"
    done
done

echo "periodic: finished at $(date)"

if [ "$DID_SOMETHING" = "1" ] && [ -n "$PERIODIC_MAILTO" ]; then
    mail -s "ok periodic $(hostname -s)" "$PERIODIC_MAILTO" < "$LOGFILE"
fi
