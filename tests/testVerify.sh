#!/bin/bash
##
## Output check for the test runs: OUTDIR must hold exactly N out.* files
## newer than the file SINCE.
##

set -euo pipefail

OUTDIR=$1
SINCE=$2
N=$3

FOUND=0
for F in "$OUTDIR"/out.*; do
    [ -f "$F" ] || continue
    if [ "$F" -nt "$SINCE" ]; then
        FOUND=$((FOUND + 1))
    else
        echo "older than the run: $F"
    fi
done
if [ "$FOUND" -ne "$N" ]; then
    echo "expected $N new output files, found $FOUND"
    exit 1
fi
echo "$FOUND new output files"
