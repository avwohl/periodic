# Configuration and Parts

How to configure `periodic` in `periodic.conf`, and how to write the parts it runs.

## `periodic.conf`

The config file is sourced as bash, so anything bash accepts is legal
(variables, command substitution, conditionals). The meaningful variables are:

	PERIODIC_DIRS        array of "dir" or "dir:frequency" entries (required)
	PERIODIC_LOGDIR      where per-run logs are written         (default /var/log/periodic)
	PERIODIC_TIMEDIR     where per-script markers are kept      (default /var/lib/periodic/times)
	PERIODIC_LOCKFILE    file lock path                          (default /tmp/periodic.lock)
	PERIODIC_NICE        nice level for the whole run            (default 20)
	PERIODIC_WORKDIR     cwd handed to every part                 (default /)
	PERIODIC_MAILTO      if non-empty, mail the log on success and failure (default empty)
	PERIODIC_TRACE       if non-empty, xtrace the run and every part (default empty)
	PERIODIC_FAIL_TAIL   lines of a failed part's output to replay  (default 200)

`PERIODIC_DIRS` is the one you care about. Each entry is a directory path,
optionally followed by `:day`, `:week`, or `:month`. The suffix controls how
often scripts in that directory are eligible to run; the directory name itself
is just a label. Example:

	PERIODIC_DIRS=(
	    "/local/periodic/daily.d:day"
	    "/local/periodic/weekly.d:week"
	    "/local/periodic/monthly.d:month"
	)

The names `daily.d` / `weekly.d` / `monthly.d` are pure convention. The system
matches **whatever path you put on the left of the colon**, not a hard-coded
set of names. `/srv/chores:day` works identically to `/local/periodic/daily.d:day`.
If you omit the suffix, `day` is assumed, so `"/srv/chores"` and
`"/srv/chores:day"` are the same.

The period keys used for each frequency:

	day    date +%Y%m%d    e.g. 20260422
	week   date +%Gw%V     e.g. 2026w17   (ISO year + ISO week)
	month  date +%Y%m      e.g. 202604

A script "already ran this period" means its marker file contains the current
period key. When the key rolls over (midnight for daily, Monday 00:00 ISO for
weekly, first of the month for monthly), the marker no longer matches and the
script becomes eligible again.

## Writing parts

A part is any executable `*.sh` in one of the configured directories. Exit 0
for success, non-zero for failure. Standard output and standard error are
captured into the run's logfile.

`periodic.sh` exports a few variables that parts may use:

	PP_DATE           date +%Y%m%d at start of run (fixed for the whole run)
	PP_DATETIME       date +%Y%m%d_%H%M%S at start of run
	PERIODIC_DAY      date +%a (Mon, Tue, ...)
	PERIODIC_LOGDIR   same as configured
	PERIODIC_TIMEDIR  same as configured

These are set *before* the config is sourced, so the config can override them
if you want to pin them (e.g. force all parts to share a specific date key).

Parts are run with the working directory set to `PERIODIC_WORKDIR` (default
`/`), not the directory cron happened to start in. Do not rely on the cwd — cd
somewhere explicit if your part cares. The default is deliberately a directory
every uid can traverse: cron starts root's jobs in `/root` (mode `0700`), and a
part that drops privileges with `runuser`/`su`/`sudo` inherits that cwd. Tools
that save and restore their working directory (GNU `find`, for one) then fail
outright, which under `set -e` takes the whole part down.

You may also export your own variables from `periodic.conf` — they're
inherited by every part. The example config exports `PP_HOSTNAME` and
`PP_HOST_DATE_KEY` this way.

Naming tip: parts run in `LC_COLLATE=C` alphabetical order, so prefix with
numbers if order matters:

	10-backup.sh
	20-prune.sh
	30-report.sh
