#!/bin/bash
##
## Status job of a run. runFinish (lib/slurmTools.sh) submits it to start
## once every other job of the run has ended, in any state. It runs
## checkRun.sh -w, which writes RUNSTATUS.txt, and exits 0 only when the
## run is OK, so the end-of-job mail from SLURM says COMPLETED for a
## verified run and FAILED for anything else.
##
## Accounting can lag a little behind the jobs, so a RUNNING or UNKNOWN
## verdict is checked again, up to SLURMTOOLS_STATUS_TRIES times (10),
## SLURMTOOLS_STATUS_WAIT seconds apart (30). If there is still no final
## verdict, the run is marked UNKNOWN.
##

set -uo pipefail

if [ "$#" -ne 1 ]; then
    echo -e "\n   usage: sbatch runStatus.sh RUN_DIR (submitted by runFinish)\n" >&2
    exit 1
fi
RUN_DIR=$1

## SLURM runs a copy of this script, so lib/ is found through
## SLURMTOOLS_DIR, which lib/slurmTools.sh exports at submission.
# shellcheck source=../lib/slurmTools.sh
. "${SLURMTOOLS_DIR:?not set; this job is submitted by runFinish}/lib/slurmTools.sh"
# shellcheck source=../lib/jobTrailer.sh
. "$SLURMTOOLS_DIR/lib/jobTrailer.sh"

TRIES=${SLURMTOOLS_STATUS_TRIES:-10}
WAIT=${SLURMTOOLS_STATUS_WAIT:-30}

echo "Start: status of run $RUN_DIR $(date)"
for ((TRY = 1; ; TRY++)); do
    "$SLURMTOOLS_DIR/bin/checkRun.sh" -w "$RUN_DIR"
    RC=$?
    case "$RC" in
        0|1) break ;;
    esac
    if [ "$TRY" -ge "$TRIES" ]; then
        echo "ERROR: no final verdict after $TRIES checks (last exit status $RC)" >&2
        stWriteStatus "$RUN_DIR" UNKNOWN \
            "status job ${SLURM_JOB_ID:-} found no final verdict after $TRIES checks; run checkRun.sh again"
        break
    fi
    echo "Check $TRY of $TRIES: exit status $RC, no final verdict; next check in ${WAIT}s"
    sleep "$WAIT"
done
echo "End: status of run $RUN_DIR $(date)"

[ "$RC" -eq 0 ] || exit 1
