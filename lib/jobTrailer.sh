# shellcheck shell=bash
##
## jobTrailer.sh: sourced near the top of a SLURM job script. When the
## script exits it prints, as the last line of the job's log,
##
##   #SLURMTOOLS_EXIT=<exit status>
##
## bin/checkRun.sh reads that line only for a job SLURM accounting does not
## have. It is a fallback, and a job killed at its time limit usually
## leaves no line: SLURM sends SIGTERM to the batch shell alone, which
## cannot act on it while a command runs, and kills the job with SIGKILL
## KillWait seconds later. A SIGTERM that arrives between commands makes
## the script exit with 143, and the line is written.
##
## The script's exit status is not changed.
##

_stJobTrailer() {
    echo "#SLURMTOOLS_EXIT=$?"
}
trap _stJobTrailer EXIT
trap 'exit 143' TERM
