# shellcheck shell=bash
##
## slurmTools.sh: records every SLURM job of a tool's run, so that
## bin/checkRun.sh can decide whether the run succeeded. Sourced by the
## tool's launcher, not executed.
##
## Each run gets a directory OUTDIR/SLM/<RUN_ID>, RUN_ID being its start
## time (YYYYmmdd_HHMMSS):
##
##   RUNINFO        KEY=VALUE: tool, version, command, start, submission
##   START          empty; its modification time is the start of the run
##   jobs.tsv       one line per job: id, name, array spec, log, role
##   verify         the tool's output check, one argument per line
##   *.out          the jobs' logs
##   RUNSTATUS.txt  the latest verdict, copied to OUTDIR/RUNSTATUS.txt
##   checkRun.txt   the report behind that verdict
##
## The last job of a run is its status job. It starts once every other job
## has ended, in any state, runs bin/checkRun.sh and mails the user.
##
## A launcher:
##
##   . "$SLURMTOOLS_DIR/lib/slurmTools.sh"
##   runGuard "$OUTDIR"           # before anything is written into OUTDIR
##   ...check the inputs, write files into OUTDIR...
##   runInit "$OUTDIR" TOOL VERSION "$0" "$@"
##   runSubmit stepA --array=1-10 -- stepA.sh ARG...
##   runSubmit stepB --dependency=afterok:$RUN_JOBID -- stepB.sh ARG...
##   runFinish verify.sh "$OUTDIR" "$RUN_DIR/START"
##
## From runInit until runFinish has submitted the status job, an EXIT trap
## is set: if the launcher exits early, for any reason, the jobs already
## submitted are cancelled and the run is marked FAILED. The launcher must
## not set an EXIT trap of its own in that stretch.
##
## Settings, from the environment:
##   SLURMTOOLS_MAIL       address for the status job's mail. Default
##                         $USER@mskcc.org; set it empty for no mail.
##   SLURMTOOLS_PARTITION  partition(s) for the status job. Default
##                         cpushort,cmobic_short
##

SLURMTOOLS_DIR=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")
SLURMTOOLS_VERSION=$(cat "$SLURMTOOLS_DIR/VERSION")
## Job scripts find lib/jobTrailer.sh through it.
export SLURMTOOLS_DIR

## Printed by lib/jobTrailer.sh as the last line of a job's log.
SLURMTOOLS_EXIT_TAG="#SLURMTOOLS_EXIT="

##
## awk function, shared by the awk programs below. Expands a SLURM array
## spec ("1-10", "1,4,7-9", "0-20:5", with an optional "%N" limit) into
## list[1..n], in spec order and without repeats. Returns n, or -1 when it
## cannot read the spec.
##
_ST_AWK_EXPAND='
function expand(spec, list,    n, np, parts, i, r, t, a, b, s, seen) {
    split("", list)
    sub(/%[0-9]+$/, "", spec)
    n = 0
    np = split(spec, parts, ",")
    if (np == 0) return -1
    for (i = 1; i <= np; i++) {
        r = parts[i]; s = 1
        if (r ~ /^[0-9]+-[0-9]+:[0-9]+$/) { split(r, t, ":"); r = t[1]; s = t[2] + 0 }
        if (r ~ /^[0-9]+$/) { a = r + 0; b = a }
        else if (r ~ /^[0-9]+-[0-9]+$/) { split(r, t, "-"); a = t[1] + 0; b = t[2] + 0 }
        else return -1
        if (s < 1 || b < a) return -1
        for (; a <= b; a += s)
            if (!(a in seen)) { seen[a] = 1; list[++n] = a }
    }
    return n
}
'

##
## Errors. Before runInit they only stop the launcher; after it the EXIT
## trap also cancels the run's jobs and records the reason.
##
_stDie() {
    _ST_REASON=$*
    echo -e "\n    ERROR: $*\n" >&2
    exit 1
}

## Value of KEY in a KEY=VALUE file; the last line for KEY wins. Prints
## nothing when the file or the key is missing.
stInfo() {
    [ -f "$1" ] || return 0
    awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$1"
}

## Directory of the newest run in OUTDIR. Returns 1 when there is none.
stLatestRun() {
    local f latest=""
    for f in "$1"/SLM/[0-9]*_[0-9]*/RUNINFO; do
        if [ -f "$f" ]; then
            latest=${f%/RUNINFO}
        fi
    done
    [ -n "$latest" ] || return 1
    echo "$latest"
}

##
## The state of every task of every job in RUN_DIR/jobs.tsv, one line per
## task, tab separated:
##
##   job  task  name  role  state  reason  class  log
##
## task is the array index, or "-" for a job that is not an array. state
## (sacct State, e.g. "CANCELLED by 1234") and reason come from SLURM
## accounting. A task accounting does not have is looked up in the queue
## (squeue), then in its log, whose #SLURMTOOLS_EXIT line gives the exit
## status. class is one of:
##
##   DONE        completed
##   ACTIVE      pending, running, or requeued
##   FAILED      failed, timed out, out of memory, node failure, ...
##   CANCELLED   cancelled by a user
##   DEPENDENCY  cancelled by SLURM because a job it depends on failed
##   UNKNOWN     no state found, or a state not listed here
##
## Returns 3 when sacct could not be read (the lines are still printed,
## from the queue and the logs only), else 0.
##
stTaskStates() {
    local runDir=$1 ids start acct queue try acctRc=0
    local tries=${SLURMTOOLS_SACCT_TRIES:-3}
    local -a since=()
    ids=$(awk -F'\t' 'NR > 1 { printf "%s%s", (n++ ? "," : ""), $1 }' "$runDir/jobs.tsv")
    [ -n "$ids" ] || return 0
    ## Only jobs since the run started: SLURM reuses job ids once they
    ## pass MaxJobId.
    start=$(stInfo "$runDir/RUNINFO" START)
    if [ -n "$start" ]; then
        since=(-S "${start/ /T}")
    fi

    for ((try = 1; ; try++)); do
        if acct=$(sacct -X -n -P "${since[@]}" -j "$ids" -o JobID,State,Reason 2>&1); then
            acctRc=0
            break
        fi
        acctRc=3
        echo "WARNING: sacct failed (try $try of $tries): $acct" >&2
        acct=""
        [ "$try" -lt "$tries" ] || break
        sleep 10
    done
    queue=$(squeue -h -r -o '%F|%K|%T' -j "$ids" 2>/dev/null) || queue=""

    awk -v tag="$SLURMTOOLS_EXIT_TAG" "$_ST_AWK_EXPAND"'
        BEGIN { FS = "\t"; OFS = "\t" }
        ## The sacct line for one task wins over a line for a range of
        ## still-pending tasks that includes it.
        function record(job, task, st, rs, fromRange,    key) {
            key = job SUBSEP task
            if (fromRange && (key in state) && !(key in ranged)) return
            state[key] = st; reason[key] = rs
            if (fromRange) ranged[key] = 1
            else delete ranged[key]
        }
        ## st is the whole sacct State, e.g. "CANCELLED by 1234".
        function classify(st, rs,    w) {
            w = st; sub(/ .*/, "", w)
            if (w == "COMPLETED") return "DONE"
            if (w ~ /^(PENDING|RUNNING|REQUEUED|REQUEUE_FED|REQUEUE_HOLD|RESIZING|SUSPENDED|COMPLETING|CONFIGURING|STAGE_OUT|SIGNALING|RESV_DEL_HOLD|STOPPED|POWER_UP_NODE)$/)
                return "ACTIVE"
            ## A user (scancel) leaves "CANCELLED by <uid>". SLURM itself
            ## leaves a bare "CANCELLED" when it cancels a job whose
            ## dependency failed.
            if (w == "CANCELLED")
                return (st ~ / by / && rs != "DependencyNeverSatisfied") ? "CANCELLED" : "DEPENDENCY"
            if (w ~ /^(FAILED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|BOOT_FAIL|DEADLINE|PREEMPTED|REVOKED|SPECIAL_EXIT)$/)
                return "FAILED"
            return "UNKNOWN"
        }
        ## Exit status from the last exit line of a log, or "" if none.
        function exitLine(file,    line, rc) {
            rc = ""
            while ((getline line < file) > 0)
                if (index(line, tag) == 1 && substr(line, length(tag) + 1) ~ /^[0-9]+$/)
                    rc = substr(line, length(tag) + 1)
            close(file)
            return rc
        }
        FILENAME == ARGV[1] {
            if (FNR > 1 && NF >= 5) {
                n++; id[n] = $1; name[n] = $2; arr[n] = $3; logp[n] = $4; role[n] = $5
            }
            next
        }
        FILENAME == ARGV[2] {
            if (split($0, f, "|") < 3 || f[1] !~ /^[0-9]+(_[0-9]+|_\[[^]]*\])?$/) next
            st = f[2]
            p = index(f[1], "_")
            if (!p) { record(f[1], "-", st, f[3], 0); next }
            job = substr(f[1], 1, p - 1); t = substr(f[1], p + 1)
            if (t !~ /^\[/) { record(job, t + 0, st, f[3], 0); next }
            k = expand(substr(t, 2, length(t) - 2), tl)
            for (i = 1; i <= k; i++) record(job, tl[i], st, f[3], 1)
            next
        }
        FILENAME == ARGV[3] {
            if (split($0, f, "|") < 3) next
            queued[f[1] SUBSEP (f[2] ~ /^[0-9]+$/ ? f[2] + 0 : "-")] = f[3]
            next
        }
        END {
            for (j = 1; j <= n; j++) {
                if (arr[j] == "-") { k = 1; tl[1] = "-" }
                else if ((k = expand(arr[j], tl)) < 0) { k = 1; tl[1] = "?" }
                for (i = 1; i <= k; i++) {
                    t = tl[i]; key = id[j] SUBSEP t
                    lg = logp[j]; gsub(/%A/, id[j], lg); gsub(/%a/, t, lg); gsub(/%j/, id[j], lg)
                    if (key in state) { st = state[key]; rs = reason[key] }
                    else if (key in queued) { st = queued[key]; rs = "in queue, not yet in sacct" }
                    else if ((rc = exitLine(lg)) != "") {
                        st = (rc + 0 == 0) ? "COMPLETED" : "FAILED"
                        rs = "not in sacct; log exit status " rc
                    }
                    else { st = "MISSING"; rs = "not in sacct or squeue, and no exit line in its log" }
                    ## No empty fields: bash read would merge the tabs.
                    print id[j], t, name[j], role[j], st, (rs == "" ? "-" : rs), classify(st, rs), lg
                }
            }
        }
    ' "$runDir/jobs.tsv" <(printf '%s\n' "$acct") <(printf '%s\n' "$queue")
    return "$acctRc"
}

##
## Write RUN_DIR/RUNSTATUS.txt (KEY=VALUE) and, when RUN_DIR is the newest
## run of its output directory, copy it to OUTDIR/RUNSTATUS.txt. Extra
## KEY=VALUE arguments are appended. Both files are replaced in one rename,
## so a reader never sees half a file.
##
stWriteStatus() {
    local runDir=$1 status=$2 reason=$3 outdir latest kv
    shift 3
    outdir=$(dirname "$(dirname "$runDir")")
    {
        echo "STATUS=$status"
        echo "REASON=${reason//$'\n'/ }"
        echo "RUN_ID=$(basename "$runDir")"
        echo "TOOL=$(stInfo "$runDir/RUNINFO" TOOL)"
        echo "VERSION=$(stInfo "$runDir/RUNINFO" VERSION)"
        echo "RUN_DIR=$runDir"
        echo "CHECKED=$(date '+%F %T')"
        for kv in "$@"; do
            echo "$kv"
        done
    } > "$runDir/.RUNSTATUS.txt.$$"
    mv -f "$runDir/.RUNSTATUS.txt.$$" "$runDir/RUNSTATUS.txt"
    latest=$(stLatestRun "$outdir") || latest=""
    if [ "$latest" == "$runDir" ]; then
        cp "$runDir/RUNSTATUS.txt" "$outdir/.RUNSTATUS.txt.$$"
        mv -f "$outdir/.RUNSTATUS.txt.$$" "$outdir/RUNSTATUS.txt"
    fi
}

##
## runGuard OUTDIR
## Stops the launcher when the newest run in OUTDIR still has jobs in the
## queue: a new run would overwrite files those jobs read and write. Call
## it before writing anything into OUTDIR.
##
runGuard() {
    local outdir runDir ids queued
    outdir=$(readlink -m "$1")
    runDir=$(stLatestRun "$outdir") || return 0
    ids=$(awk -F'\t' 'NR > 1 { printf "%s%s", (n++ ? "," : ""), $1 }' "$runDir/jobs.tsv")
    [ -n "$ids" ] || return 0
    queued=$(squeue -h -o '%F' -j "$ids") \
        || _stDie "cannot read the SLURM queue (squeue) to check for an active run in $outdir"
    queued=$(grep -E '^[0-9]+$' <<< "$queued" | sort -u | paste -sd' ' || true)
    if [ -n "$queued" ]; then
        _stDie "run $(basename "$runDir") in $outdir is still active (job $queued).
    Wait for it to end, or cancel it: scancel $queued"
    fi
}

##
## runInit OUTDIR TOOL VERSION [COMMAND...]
## Starts a run: creates its directory and sets RUN_ID and RUN_DIR.
## COMMAND is the launcher's command line, recorded in RUNINFO.
##
runInit() {
    [ "$#" -ge 3 ] || _stDie "usage: runInit OUTDIR TOOL VERSION [COMMAND...]"
    local outdir tool=$2 version=$3 try cmd
    outdir=$(readlink -m "$1")
    shift 3
    cmd=$(printf '%q ' "$@")
    [[ "$tool" =~ ^[A-Za-z0-9._-]+$ ]] || _stDie "runInit: bad tool name [$tool]"
    command -v sbatch > /dev/null || _stDie "sbatch not on PATH"

    mkdir -p "$outdir/SLM"
    RUN_DIR=""
    ## The directory name is the start time, so a second run started in the
    ## same second waits for the next one.
    for try in 1 2 3 4 5; do
        RUN_ID=$(date +%Y%m%d_%H%M%S)
        if mkdir "$outdir/SLM/$RUN_ID" 2> /dev/null; then
            RUN_DIR=$outdir/SLM/$RUN_ID
            break
        fi
        sleep 1
    done
    [ -n "$RUN_DIR" ] || _stDie "cannot create a run directory in $outdir/SLM"

    touch "$RUN_DIR/START"
    {
        echo "RUN_ID=$RUN_ID"
        echo "TOOL=$tool"
        echo "VERSION=$version"
        echo "OUTDIR=$outdir"
        echo "USER=${USER:-$(id -un)}"
        echo "HOST=${HOSTNAME:-}"
        echo "CWD=$PWD"
        echo "COMMAND=${cmd% }"
        echo "SLURMTOOLS_DIR=$SLURMTOOLS_DIR"
        echo "SLURMTOOLS_VERSION=$SLURMTOOLS_VERSION"
        echo "START=$(date '+%F %T')"
    } > "$RUN_DIR/RUNINFO"
    printf 'job_id\tname\tarray\tlog\trole\n' > "$RUN_DIR/jobs.tsv"

    _ST_TOOL=$tool
    _ST_REASON=""
    trap _stOnExit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    stWriteStatus "$RUN_DIR" SUBMITTING "submitting jobs"
}

##
## runSubmit NAME [SBATCH_OPTION...] -- SCRIPT [ARG...]
## Submits one job of the run and sets RUN_JOBID. NAME is the job name and
## names its log, RUN_DIR/NAME.%j.out (NAME.%A_%a.out for an array). An
## array is given here (--array/-a), not by #SBATCH in the script, so that
## the run knows its tasks. Job name, log and --parsable are set here and
## may not be passed. A job with a dependency that can no longer be met is
## cancelled (--kill-on-invalid-dep), so it cannot stay pending forever.
##
runSubmit() {
    _stNeedRun runSubmit
    [ "$#" -ge 1 ] || _stDie "usage: runSubmit NAME [SBATCH_OPTION...] -- SCRIPT [ARG...]"
    local name=$1 array="-" script log out
    local -a opts=()
    shift
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || _stDie "runSubmit: bad job name [$name]"
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        case "$1" in
            -a|--array)
                [ "$#" -ge 2 ] || _stDie "runSubmit: $1 needs a value"
                array=$2
                shift 2 ;;
            --array=*) array=${1#--array=}; shift ;;
            -a?*)      array=${1#-a}; shift ;;
            -o|-o?*|--output|--output=*|-e|-e?*|--error|--error=*|-J|-J?*|--job-name|--job-name=*|--parsable|--wrap|--wrap=*)
                _stDie "runSubmit: $1 is set by slurmTools; do not pass it" ;;
            *) opts+=("$1"); shift ;;
        esac
    done
    if [ "${1:-}" != "--" ] || [ "$#" -lt 2 ]; then
        _stDie "usage: runSubmit NAME [SBATCH_OPTION...] -- SCRIPT [ARG...]"
    fi
    shift
    script=$1
    shift
    [ -f "$script" ] || _stDie "runSubmit: job script not found: $script"

    if [ "$array" != "-" ]; then
        awk -v s="$array" "$_ST_AWK_EXPAND"'BEGIN { exit !(expand(s, l) > 0) }' \
            || _stDie "runSubmit: cannot read the array spec [$array]"
        opts+=("--array=$array")
        log=$RUN_DIR/$name.%A_%a.out
    else
        log=$RUN_DIR/$name.%j.out
    fi

    out=$(sbatch --parsable --job-name="$name" --output="$log" --kill-on-invalid-dep=yes \
        "${opts[@]}" "$script" "$@") \
        || _stDie "sbatch failed for job $name"
    RUN_JOBID=$(_stJobId "$out") || _stDie "sbatch gave no job id for $name: $out"
    printf '%s\t%s\t%s\t%s\twork\n' "$RUN_JOBID" "$name" "$array" "$log" >> "$RUN_DIR/jobs.tsv"
}

##
## runFinish [VERIFY [ARG...]]
## Submits the status job, which starts when every job of the run has
## ended (afterany), and ends the submission. VERIFY is the tool's output
## check: checkRun.sh runs it once every task has completed, and the run
## is OK only when it exits 0. Sets RUN_STATUS_JOBID, and RUN_MAIL to the
## address the status job mails (empty for none).
##
runFinish() {
    _stNeedRun runFinish
    local arg deps out mail name=${_ST_TOOL}Status
    local -a opts

    : > "$RUN_DIR/verify"
    for arg in "$@"; do
        [[ "$arg" != *$'\n'* ]] || _stDie "runFinish: an argument of the output check contains a newline"
        printf '%s\n' "$arg" >> "$RUN_DIR/verify"
    done

    deps=$(awk -F'\t' 'NR > 1 { printf "%s%s", (n++ ? ":" : ""), $1 }' "$RUN_DIR/jobs.tsv")
    opts=(--parsable --job-name="$name" --output="$RUN_DIR/$name.%j.out"
          --partition="${SLURMTOOLS_PARTITION:-cpushort,cmobic_short}"
          --cpus-per-task=1 --mem=2G --time=00:30:00)
    if [ -n "$deps" ]; then
        opts+=(--dependency="afterany:$deps" --kill-on-invalid-dep=yes)
    fi
    mail=${SLURMTOOLS_MAIL-${USER:-$(id -un)}@mskcc.org}
    if [ -n "$mail" ]; then
        opts+=("--mail-type=END,FAIL" --mail-user="$mail")
    fi
    # shellcheck disable=SC2034  # read by the launcher
    RUN_MAIL=$mail

    out=$(sbatch "${opts[@]}" "$SLURMTOOLS_DIR/bin/runStatus.sh" "$RUN_DIR") \
        || _stDie "sbatch failed for the status job"
    RUN_STATUS_JOBID=$(_stJobId "$out") || _stDie "sbatch gave no job id for the status job: $out"
    printf '%s\t%s\t-\t%s\tstatus\n' "$RUN_STATUS_JOBID" "$name" "$RUN_DIR/$name.%j.out" \
        >> "$RUN_DIR/jobs.tsv"
    echo "SUBMIT_COMPLETE=$(date '+%F %T')" >> "$RUN_DIR/RUNINFO"
    trap - EXIT INT TERM
    stWriteStatus "$RUN_DIR" RUNNING "jobs submitted; status job $RUN_STATUS_JOBID checks them when they end"
}

_stNeedRun() {
    if [ -z "${RUN_DIR:-}" ] || [ ! -f "$RUN_DIR/RUNINFO" ] || [ -z "${_ST_TOOL:-}" ]; then
        _stDie "$1: call runInit first"
    fi
}

## Job id from sbatch --parsable output ("id" or "id;cluster").
_stJobId() {
    local id=${1%%$'\n'*}
    id=${id%%;*}
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    echo "$id"
}

##
## EXIT trap between runInit and runFinish: the submission did not finish.
## Cancels the jobs already submitted, so no partial run goes on, and marks
## the run FAILED.
##
_stOnExit() {
    local rc=$? ids reason
    trap - EXIT INT TERM
    set +e
    ids=$(awk -F'\t' 'NR > 1 { printf "%s%s", (n++ ? " " : ""), $1 }' "$RUN_DIR/jobs.tsv")
    if [ -n "$ids" ]; then
        echo "    Cancelling the jobs already submitted: $ids" >&2
        # shellcheck disable=SC2086
        scancel $ids || echo "    WARNING: scancel failed; cancel them by hand: scancel $ids" >&2
    fi
    reason=${_ST_REASON:-the launcher exited with status $rc before runFinish}
    echo "SUBMIT_FAILED=$(date '+%F %T') ${reason//$'\n'/ }" >> "$RUN_DIR/RUNINFO"
    stWriteStatus "$RUN_DIR" FAILED "submission failed: $reason"
    exit $((rc == 0 ? 1 : rc))
}
