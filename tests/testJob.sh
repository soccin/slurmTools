#!/bin/bash
#SBATCH -c 1
#SBATCH --mem 1G
#SBATCH -t 00:10:00
#SBATCH --partition cpushort,cmobic_short
##
## Job for runTests.sh. Writes OUTDIR/out.<job name>.<array task> when it
## succeeds. MODE:
##   ok        succeed
##   fail      exit 1
##   failtask  array task 3 exits 2, the other tasks succeed
##   sleep     sleep 90 s, then succeed
##   timeout   sleep 600 s; submitted with a 1 minute limit
##   oom       use memory until killed; submitted with a small --mem
##

set -euo pipefail
# shellcheck source=../lib/jobTrailer.sh
. "${SLURMTOOLS_DIR:?}/lib/jobTrailer.sh"

MODE=$1
OUTDIR=$2
OUT=$OUTDIR/out.$SLURM_JOB_NAME.${SLURM_ARRAY_TASK_ID:-0}
echo "testJob.sh $MODE $OUT"

case "$MODE" in
    ok) ;;
    fail)
        echo "ERROR: test job fails on purpose" >&2
        exit 1 ;;
    failtask)
        if [ "${SLURM_ARRAY_TASK_ID:-}" == "3" ]; then
            echo "ERROR: array task 3 fails on purpose" >&2
            exit 2
        fi ;;
    sleep)   sleep 90 ;;
    timeout) sleep 600 ;;
    ## tail keeps the last 10 lines; /dev/zero has no line end.
    oom)     tail /dev/zero ;;
    *)
        echo "ERROR: unknown mode $MODE" >&2
        exit 1 ;;
esac
date > "$OUT"
