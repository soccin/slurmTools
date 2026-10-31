# slurmTools

Tells you when a run of SLURM jobs has finished, and whether it succeeded:
every job of the run completed and the tool's outputs are complete.

A tool that submits several jobs (an array of per-sample tasks, then a job
that waits for them) gives no single answer to "did it work?". An array
task can fail while the others succeed, a job waiting on it is then
cancelled without a trace in the outputs, and outputs left by an earlier
run look like results. slurmTools records every job of a run when it is
submitted, then judges the run from SLURM's own accounting and from a check
of the outputs written by the tool.

## How it works

The tool's launcher sources `lib/slurmTools.sh` and submits its jobs through
it. Each run is recorded in `OUTDIR/SLM/<RUN_ID>/`, `RUN_ID` being the start
time. The last job of every run is a **status job**. It waits for all the
other jobs to end, in any state (`afterany`), then runs `bin/checkRun.sh`,
which:

1. reads the state of every task of every job from `sacct` (`State`);
2. if every task is `COMPLETED`, runs the tool's output check;
3. writes the verdict to `OUTDIR/RUNSTATUS.txt`.

The status job exits 0 only when the run is OK. SLURM mails when it ends
(`--mail-type=END,FAIL`), so the mail says the run has finished. Its
subject shows `COMPLETED` for an OK run and `FAILED` otherwise, but the
verdict and the reasons are in `RUNSTATUS.txt` and the report.

A run is **OK** only when every task of every job ended `COMPLETED` (exit
status 0) and the output check passed. Anything else is not OK:

| STATUS | Meaning | checkRun.sh exit |
|---|---|---|
| `OK` | every task completed, output check passed | 0 |
| `FAILED` | a task failed (any non-zero exit, time limit, out of memory, node failure, ...) or was cancelled, the submission failed, or the output check failed | 1 |
| `RUNNING` | tasks are pending or running | 2 |
| `SUBMITTING` | the launcher is still submitting | 2 |
| `UNKNOWN` | the state of a task could not be found | 3 |

`checkRun.sh` exits 4 on a usage error or when DIR holds no run.

A task that failed while others still run leaves the run `RUNNING`, with
the failure named in the reason; the run cannot end OK.

## Checking a run

```
bin/checkRun.sh [-w] DIR
```

`DIR` is the tool's output directory (its newest run is checked) or one run
directory, `OUTDIR/SLM/<RUN_ID>`. It can be run at any time, from a login
node. `-w` also writes the verdict to `RUNSTATUS.txt`, as the status job
does.

A conpair run given a file that is not a container, as reported by its
status job:

```
checkRun.sh 0.1.0
  run      /scratch/.../conpair/bad/SLM/20261030_232036
  tool     conpair 0.4.0
  started  2026-10-30 23:20:36
  checked  2026-10-30 23:21:48
  status   job 5460142 RUNNING

  JOB        NAME                      TASKS   DONE  ACTIVE  FAILED  CANCELLED  UNKNOWN
  5460140    conpairPileup                 3      0       0       3          0        0
  5460141    conpairAnalyze                1      0       0       0          1        0

  Failed:
    5460140_1      conpairPileup            FAILED (None)
      log: /scratch/.../conpair/bad/SLM/20261030_232036/conpairPileup.5460140_1.out
      FATAL:   While checking container encryption: could not open image /scratch/.../notAContainer.sif: image format not recognized
    ...

  Cancelled by SLURM because a job they depend on failed:
    5460141        conpairAnalyze           CANCELLED (None)

STATUS=FAILED
REASON=3 failed, 1 cancelled after a failed dependency, of 4 tasks; first failed 5460140_1 conpairPileup FAILED
```

For each failed task the report gives its log and the last line in it that
looks like a cause (`error`, `fatal`, `exception`, `killed`, `oom`, ...).

`RUNSTATUS.txt` is `KEY=VALUE`, for people and scripts:

```
STATUS=OK
REASON=all 13 tasks completed; output check passed
RUN_ID=20261030_231240
TOOL=conpair
VERSION=0.4.0
RUN_DIR=/data1/.../qc/conpair/SLM/20261030_231240
CHECKED=2026-10-30 23:31:02
TASKS=13
DONE=13
ACTIVE=0
FAILED=0
CANCELLED=0
UNKNOWN=0
VERIFY=PASSED
REPORT=/data1/.../qc/conpair/SLM/20261030_231240/checkRun.txt
```

`VERIFY` is `PASSED`, `FAILED`, `NOT_RUN` (not every task completed) or
`NONE` (the tool has no output check).

## Where states come from

`sacct -X` `State` is the authority: it is what SLURM recorded for each task,
including tasks that never wrote a log. Exit status alone is not enough: a
task killed for memory has `State` `OUT_OF_MEMORY` but `ExitCode` `0:125`.
Only jobs since the run's start are read, because SLURM reuses job ids.

- A job cancelled by a person shows `CANCELLED by <uid>`. A job SLURM
  cancelled itself, because a job it depends on (`afterok`) failed, shows a
  bare `CANCELLED`; the report lists those apart, so the first failure is
  easy to find.
- A task not (yet) in accounting is looked up in the queue (`squeue`).
- A task in neither is looked up in its log. Job scripts source
  `lib/jobTrailer.sh`, which ends the log with `#SLURMTOOLS_EXIT=<status>`.
  That line is only a fallback, and a task that has none is `UNKNOWN`. A
  task killed at its time limit usually has none: SLURM sends SIGTERM to
  the batch shell alone, which cannot act on it while a command runs, and
  kills the job 30 s later (KillWait).
- `sacct` is tried 3 times, 10 s apart. The status job retries a `RUNNING`
  or `UNKNOWN` verdict 10 times, 30 s apart, because accounting can lag
  behind the end of a job. It then gives up and marks the run `UNKNOWN`.

## Run directory

```
OUTDIR/RUNSTATUS.txt          verdict of the newest run
OUTDIR/SLM/<RUN_ID>/
  RUNINFO        KEY=VALUE: tool, version, command line, start, submission
  START          empty; its modification time is the start of the run
  jobs.tsv       every job: id, name, array spec, log pattern, role
  verify         the tool's output check, one argument per line
  RUNSTATUS.txt  verdict of this run
  checkRun.txt   report behind the verdict
  *.out          job logs: NAME.<jobid>.out, NAME.<arrayid>_<task>.out
```

## Writing a launcher

```bash
. "$SLURMTOOLS_DIR/lib/slurmTools.sh"

runGuard "$OUTDIR"        # before anything is written into OUTDIR
# ...check inputs, write files into OUTDIR...

runInit "$OUTDIR" mytool "$VERSION" "$0" "$@"
runSubmit mytoolA --array "1-$N" -- "$SDIR/stepA.sh" "$OUTDIR"
runSubmit mytoolB --dependency "afterok:$RUN_JOBID" -- "$SDIR/stepB.sh" "$OUTDIR"
runFinish "$SDIR/mytoolVerify.sh" "$OUTDIR" "$RUN_DIR/START"
```

| Function | Does |
|---|---|
| `runGuard OUTDIR` | Stops the launcher if the newest run in OUTDIR still has jobs queued: a second run would overwrite the files they use. |
| `runInit OUTDIR TOOL VERSION [COMMAND...]` | Creates the run directory; sets `RUN_ID`, `RUN_DIR`. |
| `runSubmit NAME [SBATCH_OPTION...] -- SCRIPT [ARG...]` | Submits one job; sets `RUN_JOBID`. |
| `runFinish [VERIFY [ARG...]]` | Submits the status job; sets `RUN_STATUS_JOBID`, `RUN_MAIL`. |

Rules:

- `runSubmit` sets the job name, the log (`RUN_DIR/NAME.%j.out`, or
  `NAME.%A_%a.out` for an array) and `--parsable`; do not pass `-J`, `-o`,
  `-e` or `--wrap`. Give an array with `--array`/`-a` to `runSubmit`, not
  with `#SBATCH --array` in the script, so the run knows its tasks.
- Every job gets `--kill-on-invalid-dep=yes`: a job whose dependency failed
  is cancelled rather than left pending, so the status job can start.
- From `runInit` until `runFinish` an EXIT trap is set. If the launcher
  stops early, for any reason, the jobs already submitted are cancelled and
  the run is marked FAILED. Do not set another EXIT trap in that stretch.
- Job scripts source the trailer:

  ```bash
  if [ -n "${SLURMTOOLS_DIR:-}" ]; then
      . "$SLURMTOOLS_DIR/lib/jobTrailer.sh"
  fi
  ```

  `lib/slurmTools.sh` exports `SLURMTOOLS_DIR`, so jobs submitted with the
  default `--export=ALL` (or `--export=ALL,...`) have it.
- The output check (`VERIFY`) exits 0 when the outputs are complete, and
  otherwise prints each problem and exits non-zero; the report shows its
  first 40 lines. Pass it `$RUN_DIR/START` and check that each output is
  newer, so outputs left by an earlier run cannot pass. Use absolute paths:
  it may run from any directory.

## Settings

Environment variables, read when the launcher runs:

| Variable | Default | |
|---|---|---|
| `SLURMTOOLS_MAIL` | `$USER@mskcc.org` | Address for the status job's mail; empty for no mail |
| `SLURMTOOLS_PARTITION` | `cpushort,cmobic_short` | Partition(s) for the status job |
| `SLURMTOOLS_STATUS_TRIES`, `SLURMTOOLS_STATUS_WAIT` | 10, 30 | Status job retries of a RUNNING or UNKNOWN verdict, and the seconds between them |
| `SLURMTOOLS_SACCT_TRIES` | 3 | Tries of `sacct` before a check gives up on it |

## Limits

- One run per output directory at a time (`runGuard`).
- Heterogeneous jobs are not supported.
- If the status job itself is cancelled, `RUNSTATUS.txt` keeps its last
  value and no mail comes; `checkRun.sh -w OUTDIR` updates it.
- The status job takes the jobs' word through SLURM accounting. A job that
  exits 0 without doing its work is only caught by the output check, so
  each tool needs one.

## Tests

`tests/runTests.sh ROOT` submits small real jobs into a new directory ROOT
on shared storage, one run per case: success, exit 1 with a dependent job,
one failing array task, time limit, out of memory, failed output check,
failed submission, a second launch into an active run, and checks without
`sacct`. It waits for the status jobs (about 5 minutes) and prints PASS or
FAIL per check. No mail is sent.

## Layout

```
lib/slurmTools.sh   sourced by launchers: runGuard, runInit, runSubmit, runFinish
lib/jobTrailer.sh   sourced by job scripts: exit status line at the end of the log
bin/checkRun.sh     verdict on a run
bin/runStatus.sh    the status job
tests/              end-to-end tests with real SLURM jobs
VERSION
```
