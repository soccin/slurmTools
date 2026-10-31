#!/bin/bash
##
## End-to-end tests with real SLURM jobs. Submits one run per scenario of
## testLauncher.sh into ROOT/<scenario>, waits for every status job, then
## checks each verdict, exit status and job state. Only submits and polls,
## so it can run on a login node. Takes about 5 minutes, depending on the
## queue. ROOT must be new and on shared storage. No mail is sent.
##

set -uo pipefail

SDIR=$(dirname "$(readlink -f "$0")")
# shellcheck source=../lib/slurmTools.sh
. "$SDIR/../lib/slurmTools.sh"
CHECKRUN=$SLURMTOOLS_DIR/bin/checkRun.sh
LAUNCH=$SDIR/testLauncher.sh

if [ "$#" -ne 1 ]; then
    echo -e "\n   usage: runTests.sh ROOT\n" >&2
    exit 1
fi
ROOT=$(readlink -m "$1")
if [ -e "$ROOT" ]; then
    echo "ERROR: $ROOT exists; give a new directory" >&2
    exit 1
fi
mkdir -p "$ROOT"

export SLURMTOOLS_MAIL=""
export SLURMTOOLS_STATUS_WAIT=15

PASSED=0
FAILED=0
## check DESCRIPTION COMMAND...: the test passes when COMMAND succeeds.
check() {
    local what=$1
    shift
    if "$@"; then
        echo "PASS  $what"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL  $what"
        FAILED=$((FAILED + 1))
    fi
}
equals() { [ "$1" == "$2" ] || { echo "      got [$1], expected [$2]"; return 1; }; }

## Exit status of checkRun.sh on a directory.
checkRc() {
    "$CHECKRUN" "$@" > /dev/null 2>&1
    echo $?
}
## Class (column 7) or state (column 5) of one task of a run.
taskField() {
    local runDir=$1 name=$2 task=$3 col=$4
    stTaskStates "$runDir" | awk -F'\t' -v n="$name" -v t="$task" -v c="$col" '$3 == n && $2 == t { print $c }'
}

SCENARIOS=(ok fail failtask timeout oom verifyfail slow)
declare -A EXPECT=([ok]=OK [fail]=FAILED [failtask]=FAILED [timeout]=FAILED
                   [oom]=FAILED [verifyfail]=FAILED [slow]=OK)

echo "== submit"
for S in "${SCENARIOS[@]}"; do
    "$LAUNCH" "$S" "$ROOT/$S" || echo "ERROR: launcher failed for $S"
done

echo "== checks during the run"
OUT=$("$LAUNCH" slow "$ROOT/slow" 2>&1)
RC=$?
check "guard: second launch into an active OUTDIR is refused" equals "$RC" 1
check "guard: the message names the active run" grep -q "still active" <<< "$OUT"
check "checkRun on a run with pending jobs exits 2" equals "$(checkRc "$ROOT/slow")" 2

OUT=$("$LAUNCH" submitfail "$ROOT/submitfail" 2>&1)
RC=$?
check "submitfail: launcher exits 1" equals "$RC" 1
check "submitfail: RUNSTATUS.txt is FAILED" \
    equals "$(stInfo "$ROOT/submitfail/RUNSTATUS.txt" STATUS)" FAILED
SUBMITFAIL_RUN=$(stLatestRun "$ROOT/submitfail")
check "submitfail: RUNINFO has SUBMIT_FAILED" grep -q '^SUBMIT_FAILED=' "$SUBMITFAIL_RUN/RUNINFO"
check "submitfail: checkRun exits 1" equals "$(checkRc "$ROOT/submitfail")" 1

echo "== waiting for the status jobs"
STATUS_JOBS=$(for S in "${SCENARIOS[@]}"; do
    awk -F'\t' '$5 == "status" { print $1 }' "$(stLatestRun "$ROOT/$S")/jobs.tsv"
done | paste -sd,)
for ((I = 0; I < 120; I++)); do
    [ -z "$(squeue -h -o %i -j "$STATUS_JOBS")" ] && break
    sleep 15
done
## Accounting can lag behind the queue.
sleep 10

echo "== verdicts"
for S in "${SCENARIOS[@]}"; do
    RUN=$(stLatestRun "$ROOT/$S")
    WANT=${EXPECT[$S]}
    case "$WANT" in OK) WANT_RC=0; WANT_JOB=COMPLETED ;; *) WANT_RC=1; WANT_JOB=FAILED ;; esac
    check "$S: OUTDIR/RUNSTATUS.txt is $WANT" equals "$(stInfo "$ROOT/$S/RUNSTATUS.txt" STATUS)" "$WANT"
    check "$S: checkRun exits $WANT_RC" equals "$(checkRc "$ROOT/$S")" "$WANT_RC"
    check "$S: status job ended $WANT_JOB" \
        equals "$(stTaskStates "$RUN" | awk -F'\t' '$4 == "status" { print $5 }')" "$WANT_JOB"
done

RUN=$(stLatestRun "$ROOT/ok")
check "ok: output check passed" equals "$(stInfo "$RUN/RUNSTATUS.txt" VERIFY)" PASSED
check "ok: 4 tasks done" equals "$(stInfo "$RUN/RUNSTATUS.txt" DONE)" 4

RUN=$(stLatestRun "$ROOT/fail")
check "fail: stepA FAILED" equals "$(taskField "$RUN" stepA - 7)" FAILED
check "fail: stepB cancelled by its dependency" equals "$(taskField "$RUN" stepB - 7)" DEPENDENCY
check "fail: output check not run" equals "$(stInfo "$RUN/RUNSTATUS.txt" VERIFY)" NOT_RUN

RUN=$(stLatestRun "$ROOT/failtask")
check "failtask: task 3 FAILED" equals "$(taskField "$RUN" stepA 3 7)" FAILED
check "failtask: 3 tasks done, 1 failed" \
    equals "$(stInfo "$RUN/RUNSTATUS.txt" DONE)/$(stInfo "$RUN/RUNSTATUS.txt" FAILED)" 3/1
check "failtask: report shows the task's error line" \
    grep -q "array task 3 fails on purpose" "$RUN/checkRun.txt"

RUN=$(stLatestRun "$ROOT/timeout")
check "timeout: state TIMEOUT" equals "$(taskField "$RUN" stepA - 5)" TIMEOUT

RUN=$(stLatestRun "$ROOT/oom")
check "oom: state OUT_OF_MEMORY" equals "$(taskField "$RUN" stepA - 5)" OUT_OF_MEMORY

RUN=$(stLatestRun "$ROOT/verifyfail")
check "verifyfail: output check failed" equals "$(stInfo "$RUN/RUNSTATUS.txt" VERIFY)" FAILED
check "verifyfail: report shows the check's message" \
    grep -q "expected 2 new output files, found 1" "$RUN/checkRun.txt"

RUN=$(stLatestRun "$ROOT/submitfail")
check "submitfail: the job submitted before the failure was cancelled" \
    equals "$(taskField "$RUN" stepA - 7)" CANCELLED

check "guard: a new launch is allowed once the run has ended" \
    bash -c ". '$SLURMTOOLS_DIR/lib/slurmTools.sh'; runGuard '$ROOT/slow'"

echo "== without accounting: states from the logs"
FAKEBIN=$ROOT/fakebin
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho "sacct: error: test" >&2\nexit 1\n' > "$FAKEBIN/sacct"
chmod +x "$FAKEBIN/sacct"
## checkRun.sh with a sacct that always fails; the report goes to FILE.
checkNoAcct() {
    env PATH="$FAKEBIN:$PATH" SLURMTOOLS_SACCT_TRIES=1 "$CHECKRUN" "$1" > "$2" 2>&1
    echo $?
}
check "ok without sacct: OK from the exit lines (exit 0)" \
    equals "$(checkNoAcct "$ROOT/ok" "$ROOT/ok.noacct.txt")" 0
## SLURM sends the time-limit SIGTERM to the batch shell only, which waits
## for its command until SIGKILL, so the log has no exit line.
check "timeout without sacct: UNKNOWN, never OK, with no exit line (exit 3)" \
    equals "$(checkNoAcct "$ROOT/timeout" "$ROOT/timeout.noacct.txt")" 3
check "fail without sacct: FAILED (exit 1)" \
    equals "$(checkNoAcct "$ROOT/fail" "$ROOT/fail.noacct.txt")" 1
check "fail without sacct: stepB, which never ran, has no state" \
    grep -q "No state found" "$ROOT/fail.noacct.txt"

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
