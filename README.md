# periodic

A small, resumable replacement for `run-parts` / `cron.daily`.

`periodic` runs a set of shell scripts ("parts") once per day, week, or month.
Unlike `run-parts`, each part's completion is tracked individually: if a later
part fails, you fix it and re-run `periodic`, and only the unfinished parts run
again. Parts that already succeeded this period are skipped.

## License

GPL-3.0-or-later. See `LICENSE`.

## Why

The common pattern is a nightly cron job that runs a pile of maintenance
scripts in order: backup, prune, rsync, rebuild indexes, email a report. If
script #5 of 10 fails at 3am, you want to fix it and re-run — but you do **not**
want to re-run the four expensive scripts that already finished. `run-parts`
gives you no way to express that. `periodic` does.

The mechanism is a per-script timestamp file: each script gets a marker
recording the period (e.g. `20260422`) in which it last succeeded. On each
invocation, `periodic` checks the marker and skips the script if it has already
run this period.

## Components

	periodic.sh            main driver — scan dirs, run parts, track completion
	pp_every               read/write per-script period markers
	pp_lock                run a command under a non-blocking file lock
	periodic.conf.example  sample configuration

## Installing

Drop the four files into a directory of your choice (e.g. `/opt/periodic`) and
make sure `periodic.sh`, `pp_every`, and `pp_lock` are executable.

Copy `periodic.conf.example` to `periodic.conf` (in the same directory, or
anywhere — you can pass the path as an argument) and edit it.

Schedule it from cron. Running every hour is a good default: if the machine is
off or the previous run failed, the next hour picks up where you left off.

	0 * * * * /opt/periodic/periodic.sh

## How it runs

1. `periodic.sh` sources `periodic.conf`.
2. It re-execs itself under `pp_lock` so only one copy runs at a time, with
   all output redirected to a timestamped logfile in `PERIODIC_LOGDIR`.
3. For each entry in `PERIODIC_DIRS` (in array order), it globs `*.sh`, keeps
   the ones that are executable, and sorts alphabetically (LC_COLLATE=C).
4. For each script, `pp_every read` checks the marker file. If the script
   already ran this period, it is skipped.
5. Otherwise the script is run. On success, `pp_every write` records the
   current period key. On failure, `periodic` stops immediately, optionally
   mails the log, and exits non-zero. The scripts that already succeeded keep
   their markers; the failed script does not. The next invocation resumes from
   the failed script.

Because failure is fatal to the whole run, order your parts so that later
parts depend on earlier parts succeeding (backup before prune, fetch before
process, etc.).

## `periodic.conf`

The config file is sourced as bash, so anything bash accepts is legal
(variables, command substitution, conditionals). The meaningful variables are:

	PERIODIC_DIRS        array of "dir" or "dir:frequency" entries (required)
	PERIODIC_LOGDIR      where per-run logs are written         (default /var/log/periodic)
	PERIODIC_TIMEDIR     where per-script markers are kept      (default /var/lib/periodic/times)
	PERIODIC_LOCKFILE    file lock path                          (default /tmp/periodic.lock)
	PERIODIC_NICE        nice level for the whole run            (default 20)
	PERIODIC_MAILTO      if non-empty, mail the log on success and failure (default empty)

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

You may also export your own variables from `periodic.conf` — they're
inherited by every part. The example config exports `PP_HOSTNAME` and
`PP_HOST_DATE_KEY` this way.

Naming tip: parts run in `LC_COLLATE=C` alphabetical order, so prefix with
numbers if order matters:

	10-backup.sh
	20-prune.sh
	30-report.sh

## Marker files

Each script gets its own marker at:

	${PERIODIC_TIMEDIR}/per${freq}.${escaped_script_path}

where `escaped_script_path` is the absolute path with `/` replaced by `_`.
Contents are a single line: `PERIODKEY,periodic_v1`.

To force a part to re-run this period, delete its marker file. To force the
entire daily run to repeat, delete everything under `PERIODIC_TIMEDIR`
matching `perday.*`.

## Locking

`pp_lock LOCKFILE CMD...` takes a non-blocking `flock` on `LOCKFILE` and execs
the command. If the lock is already held it exits 75 (EX_TEMPFAIL). This is
what keeps two overlapping cron ticks from stomping each other when a run
takes longer than the cron interval.

You can use `pp_lock` for your own scripts too — it's a standalone utility.

## Mail

If `PERIODIC_MAILTO` is set:

- On failure, the whole logfile is mailed with subject
  `FAIL <hostname> periodic: <script>`.
- On a successful run that actually did something (at least one part ran),
  the whole logfile is mailed with subject `ok periodic <hostname>`.
- A run where every part was already complete (nothing to do) does not send
  mail.

Requires a working local `mail` command (e.g. `bsd-mailx`, `s-nail`).

## Exit codes

	0     nothing ran, or everything ran and succeeded
	1     a part failed, or the config was unreadable
	75    another instance already holds the lock (from pp_lock)

## Example: a typical daily job set

	/local/periodic/daily.d/10-backup.sh       # tar + rsync to backup host
	/local/periodic/daily.d/20-prune-old.sh    # delete backups older than N days
	/local/periodic/daily.d/30-fetch-feeds.sh  # pull external data
	/local/periodic/daily.d/40-reindex.sh      # rebuild search index
	/local/periodic/daily.d/90-report.sh       # email a summary

If `40-reindex.sh` fails at 03:00, you fix it at 09:00 and the 10:00 cron
tick runs only `40-reindex.sh` and `90-report.sh`. The backup, prune, and
fetch are not repeated.
