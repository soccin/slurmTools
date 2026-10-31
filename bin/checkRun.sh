#!/bin/bash
##
## checkRun.sh: did every job of a run succeed, and is its output complete?
##
## DIR is a tool's output directory, for its newest run, or one run
## directory, OUTDIR/SLM/<RUN_ID>. The state of every task comes from SLURM
## accounting (sacct State), with the queue and the job logs as fallbacks;
## see stTaskStates in lib/slurmTools.sh. Once every task has completed,
## the tool's output check (given to runFinish) is run, and the run is OK
## only if it passes.
##
## Prints a report that ends with STATUS= and REASON= lines. With -w it
## also writes RUNSTATUS.txt and checkRun.txt into the run directory, and
## copies RUNSTATUS.txt to OUTDIR when the run is the newest there.
##

set -euo pipefail

SDIR=$(dirname "$(readlink -f "$0")")
# shellcheck source=../lib/slurmTools.sh
. "$SDIR/../lib/slurmTools.sh"

## Problem tasks listed per class; the rest are counted.
MAX_LIST=20

usage() {
    cat <<EOF

checkRun.sh $SLURMTOOLS_VERSION -- did every job of a run succeed?

Usage:
  checkRun.sh [-w] DIR

Arguments:
  DIR   an output directory, for its newest run, or a run directory,
        OUTDIR/SLM/<RUN_ID>

Options:
  -w    write the verdict: RUNSTATUS.txt and checkRun.txt in the run
        directory, and OUTDIR/RUNSTATUS.txt if the run is the newest
  -h    show this message and exit

Exit status:
  0  OK       every task completed and the output check passed
  1  FAILED   a task failed or was cancelled, the submission failed, or
              the output check failed
  2  RUNNING  tasks are pending or running, or still being submitted
  3  UNKNOWN  the state of a task could not be found
  4  usage error, or no run in DIR

EOF
    exit 4
}

WRITE=""
while getopts 'wh' OPT; do
    case "$OPT" in
        w) WRITE=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ "$#" -eq 1 ] || usage

if [ ! -d "$1" ]; then
    echo "ERROR: not a directory: $1" >&2
    exit 4
fi
DIR=$(readlink -f "$1")
if [ -f "$DIR/RUNINFO" ]; then
    RUN_DIR=$DIR
elif ! RUN_DIR=$(stLatestRun "$DIR"); then
    echo "ERROR: no run in $1: neither $1/RUNINFO nor $1/SLM/*/RUNINFO" >&2
    exit 4
fi
INFO=$RUN_DIR/RUNINFO
if [ ! -f "$RUN_DIR/jobs.tsv" ]; then
    echo "ERROR: no jobs.tsv in $RUN_DIR" >&2
    exit 4
fi

ACCT_RC=0
STATES=$(stTaskStates "$RUN_DIR") || ACCT_RC=$?
WORK=$(awk -F'\t' '$4 == "work"' <<< "$STATES")

count() {
    awk -F'\t' -v c="$1" '$7 == c { n++ } END { print n + 0 }' <<< "$WORK"
}
TASKS=$(awk 'NF { n++ } END { print n + 0 }' <<< "$WORK")
DONE=$(count DONE)
ACTIVE=$(count ACTIVE)
FAILED=$(count FAILED)
CANCELLED=$(count CANCELLED)
DEPENDENCY=$(count DEPENDENCY)
UNKNOWN=$(count UNKNOWN)

## "job_task name state" of the first task of a class.
firstOf() {
    awk -F'\t' -v c="$1" '$7 == c {
        print ($2 == "-" ? $1 : $1 "_" $2), $3, $5; exit
    }' <<< "$WORK"
}

##
## Verdict.
##
SUBMIT_FAILED=$(stInfo "$INFO" SUBMIT_FAILED)
SUBMIT_COMPLETE=$(stInfo "$INFO" SUBMIT_COMPLETE)
VERIFY_STATE=NOT_RUN
VERIFY_OUT=""
VERIFY=()
STATUS=""
if [ -n "$SUBMIT_FAILED" ]; then
    STATUS=FAILED
    ## Drop the date and time in front of the reason.
    REASON="submission failed: $(cut -d' ' -f3- <<< "$SUBMIT_FAILED")"
elif [ -z "$SUBMIT_COMPLETE" ]; then
    if [ "$TASKS" -eq 0 ] || [ "$ACTIVE" -gt 0 ]; then
        STATUS=SUBMITTING
        REASON="jobs are being submitted"
    else
        STATUS=FAILED
        REASON="the submission never finished (no SUBMIT_COMPLETE in RUNINFO) and no job is active"
    fi
elif [ "$ACTIVE" -gt 0 ]; then
    STATUS=RUNNING
    REASON="$ACTIVE of $TASKS tasks pending or running"
    if [ "$FAILED" -gt 0 ]; then
        REASON="$REASON; $FAILED already failed, first $(firstOf FAILED)"
    fi
elif [ $((FAILED + CANCELLED + DEPENDENCY)) -gt 0 ]; then
    STATUS=FAILED
    REASON=""
    [ "$FAILED" -eq 0 ] || REASON="$REASON, $FAILED failed"
    [ "$CANCELLED" -eq 0 ] || REASON="$REASON, $CANCELLED cancelled by a user"
    [ "$DEPENDENCY" -eq 0 ] || REASON="$REASON, $DEPENDENCY cancelled after a failed dependency"
    REASON="${REASON#, }, of $TASKS tasks"
    if [ "$FAILED" -gt 0 ]; then
        REASON="$REASON; first failed $(firstOf FAILED)"
    elif [ "$CANCELLED" -gt 0 ]; then
        REASON="$REASON; first cancelled $(firstOf CANCELLED)"
    else
        REASON="$REASON; first cancelled $(firstOf DEPENDENCY)"
    fi
elif [ "$UNKNOWN" -gt 0 ]; then
    STATUS=UNKNOWN
    REASON="$UNKNOWN of $TASKS tasks have no known state, first $(firstOf UNKNOWN)"
    if [ "$ACCT_RC" -ne 0 ]; then
        REASON="$REASON; SLURM accounting (sacct) could not be read"
    fi
else
    if [ -s "$RUN_DIR/verify" ]; then
        mapfile -t VERIFY < "$RUN_DIR/verify"
    fi
    if [ "${#VERIFY[@]}" -eq 0 ]; then
        VERIFY_STATE=NONE
        STATUS=OK
        REASON="all $TASKS tasks completed; the tool has no output check"
    elif VERIFY_OUT=$("${VERIFY[@]}" 2>&1); then
        VERIFY_STATE=PASSED
        STATUS=OK
        REASON="all $TASKS tasks completed; output check passed"
    else
        VERIFY_STATE=FAILED
        STATUS=FAILED
        REASON="all $TASKS tasks completed, but the output check failed: $(head -n 1 <<< "$VERIFY_OUT")"
    fi
fi

##
## Report.
##

## Last line of a log that looks like the cause of a failure.
logReason() {
    if [ ! -f "$1" ]; then
        echo "(no log file)"
        return 0
    fi
    grep -aiE 'error|fatal|exception|traceback|killed|oom|time limit|cancelled' "$1" \
        | tail -n 1 | cut -c 1-200 || true
}

## Tasks of one class, at most MAX_LIST, with the log and its likely
## cause when WITH_LOG is set.
listTasks() {
    local class=$1 title=$2 withLog=${3:-} total shown=0 label line
    local job task name state reason cls log
    total=$(count "$class")
    [ "$total" -gt 0 ] || return 0
    echo "  $title"
    while IFS=$'\t' read -r job task name _ state reason cls log; do
        [ "$cls" == "$class" ] || continue
        if [ "$shown" -ge "$MAX_LIST" ]; then
            echo "    ... and $((total - shown)) more"
            break
        fi
        label=$job
        [ "$task" == "-" ] || label=${job}_$task
        printf '    %-14s %-24s %s (%s)\n' "$label" "$name" "$state" "$reason"
        if [ -n "$withLog" ]; then
            printf '      log: %s\n' "$log"
            line=$(logReason "$log")
            [ -z "$line" ] || printf '      %s\n' "$line"
        fi
        shown=$((shown + 1))
    done <<< "$WORK"
    echo
}

report() {
    local statusJob
    echo "checkRun.sh $SLURMTOOLS_VERSION"
    printf '  %-8s %s\n' run "$RUN_DIR"
    printf '  %-8s %s %s\n' tool "$(stInfo "$INFO" TOOL)" "$(stInfo "$INFO" VERSION)"
    printf '  %-8s %s\n' started "$(stInfo "$INFO" START)"
    printf '  %-8s %s\n' checked "$(date '+%F %T')"
    statusJob=$(awk -F'\t' '$4 == "status" { print $1 " " $5; exit }' <<< "$STATES")
    [ -z "$statusJob" ] || printf '  %-8s %s\n' status "job $statusJob"
    echo

    awk -F'\t' '
        NF && !($1 in seen) { seen[$1] = 1; order[++n] = $1; name[$1] = $3 }
        NF { t[$1]++; c[$1, $7]++ }
        END {
            if (n == 0) { print "  no jobs"; exit }
            fmt = "  %-10s %-24s %6s %6s %7s %7s %10s %8s\n"
            printf fmt, "JOB", "NAME", "TASKS", "DONE", "ACTIVE", "FAILED", "CANCELLED", "UNKNOWN"
            for (i = 1; i <= n; i++) {
                j = order[i]
                printf fmt, j, name[j], t[j], c[j, "DONE"] + 0, c[j, "ACTIVE"] + 0,
                    c[j, "FAILED"] + 0, c[j, "CANCELLED"] + c[j, "DEPENDENCY"], c[j, "UNKNOWN"] + 0
            }
        }
    ' <<< "$WORK"
    echo

    listTasks FAILED "Failed:" withLog
    listTasks CANCELLED "Cancelled by a user:"
    listTasks DEPENDENCY "Cancelled by SLURM because a job they depend on failed:"
    listTasks UNKNOWN "No state found:" withLog

    if [ "$VERIFY_STATE" == "PASSED" ] || [ "$VERIFY_STATE" == "FAILED" ]; then
        echo "  Output check: $VERIFY_STATE"
        echo "    $(printf '%q ' "${VERIFY[@]}")"
        if [ -n "$VERIFY_OUT" ]; then
            head -n 40 <<< "$VERIFY_OUT" | sed 's/^/    | /'
        fi
        echo
    fi

    echo "STATUS=$STATUS"
    echo "REASON=$REASON"
}

REPORT=$(report)
echo "$REPORT"

if [ -n "$WRITE" ]; then
    echo "$REPORT" > "$RUN_DIR/.checkRun.txt.$$"
    mv -f "$RUN_DIR/.checkRun.txt.$$" "$RUN_DIR/checkRun.txt"
    stWriteStatus "$RUN_DIR" "$STATUS" "$REASON" \
        "TASKS=$TASKS" "DONE=$DONE" "ACTIVE=$ACTIVE" "FAILED=$FAILED" \
        "CANCELLED=$((CANCELLED + DEPENDENCY))" "UNKNOWN=$UNKNOWN" \
        "VERIFY=$VERIFY_STATE" "REPORT=$RUN_DIR/checkRun.txt"
fi

case "$STATUS" in
    OK)                 exit 0 ;;
    FAILED)             exit 1 ;;
    RUNNING|SUBMITTING) exit 2 ;;
    *)                  exit 3 ;;
esac
