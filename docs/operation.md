# How periodic Runs

The run sequence, the marker files, locking, mail and exit codes.

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
