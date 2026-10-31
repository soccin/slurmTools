#!/bin/bash
##
## Launcher for runTests.sh: submits the jobs of one test SCENARIO into
## OUTDIR through lib/slurmTools.sh, as a tool's launcher would. The output
## check (testVerify.sh) expects one out.* file per task that should
## succeed.
##

set -euo pipefail

SDIR=$(dirname "$(readlink -f "$0")")
# shellcheck source=../lib/slurmTools.sh
. "$SDIR/../lib/slurmTools.sh"

if [ "$#" -ne 2 ]; then
    echo -e "\n   usage: testLauncher.sh SCENARIO OUTDIR\n" >&2
    exit 1
fi
SCENARIO=$1
OUTDIR=$(readlink -m "$2")
JOB=$SDIR/testJob.sh
P=("--partition=cpushort,cmobic_short")

runGuard "$OUTDIR"
mkdir -p "$OUTDIR"
runInit "$OUTDIR" "test_$SCENARIO" "$SLURMTOOLS_VERSION" "$0" "$@"

case "$SCENARIO" in
    ok)
        runSubmit stepA --array=1-3 "${P[@]}" -- "$JOB" ok "$OUTDIR"
        runSubmit stepB --dependency="afterok:$RUN_JOBID" "${P[@]}" -- "$JOB" ok "$OUTDIR"
        N=4 ;;
    fail)
        runSubmit stepA "${P[@]}" -- "$JOB" fail "$OUTDIR"
        runSubmit stepB --dependency="afterok:$RUN_JOBID" "${P[@]}" -- "$JOB" ok "$OUTDIR"
        N=1 ;;
    failtask)
        runSubmit stepA --array=1-4 "${P[@]}" -- "$JOB" failtask "$OUTDIR"
        N=3 ;;
    timeout)
        runSubmit stepA --time=1 "${P[@]}" -- "$JOB" timeout "$OUTDIR"
        N=1 ;;
    oom)
        runSubmit stepA --mem=256M "${P[@]}" -- "$JOB" oom "$OUTDIR"
        N=1 ;;
    verifyfail)
        runSubmit stepA "${P[@]}" -- "$JOB" ok "$OUTDIR"
        N=2 ;;
    slow)
        runSubmit stepA "${P[@]}" -- "$JOB" sleep "$OUTDIR"
        N=1 ;;
    submitfail)
        runSubmit stepA "${P[@]}" -- "$JOB" sleep "$OUTDIR"
        runSubmit stepB --partition=noSuchPartition -- "$JOB" ok "$OUTDIR"
        N=2 ;;
    *)
        echo "ERROR: unknown scenario $SCENARIO" >&2
        exit 1 ;;
esac

runFinish "$SDIR/testVerify.sh" "$OUTDIR" "$RUN_DIR/START" "$N"
echo "$SCENARIO: run $RUN_ID, status job $RUN_STATUS_JOBID"
