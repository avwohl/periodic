# periodic

A small, resumable replacement for `run-parts` / `cron.daily`.

`periodic` runs a set of shell scripts ("parts") once per day, week, or month.
Unlike `run-parts`, each part's completion is tracked individually: if a later
part fails, you fix it and re-run `periodic`, and only the unfinished parts run
again. Parts that already succeeded this period are skipped.

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

## Example: a typical daily job set

	/local/periodic/daily.d/10-backup.sh       # tar + rsync to backup host
	/local/periodic/daily.d/20-prune-old.sh    # delete backups older than N days
	/local/periodic/daily.d/30-fetch-feeds.sh  # pull external data
	/local/periodic/daily.d/40-reindex.sh      # rebuild search index
	/local/periodic/daily.d/90-report.sh       # email a summary

If `40-reindex.sh` fails at 03:00, you fix it at 09:00 and the 10:00 cron
tick runs only `40-reindex.sh` and `90-report.sh`. The backup, prune, and
fetch are not repeated.

## Documentation

- [docs/operation.md](docs/operation.md): how a run proceeds, marker files, locking, mail, exit codes
- [docs/configuration.md](docs/configuration.md): the `periodic.conf` variables, `PERIODIC_DIRS` and period keys, writing parts

## License

GPL-3.0-or-later. See `LICENSE`.
