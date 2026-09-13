#!/bin/sh

set -u

sequence=${1:-unknown}

printf 'sequence=%s\n' "$sequence"
printf 'job_id=%s\n' "${SLURM_JOB_ID:-unknown}"
printf 'node=%s\n' "$(/bin/hostname)"
printf 'uid=%s gid=%s\n' "$(/usr/bin/id -u)" "$(/usr/bin/id -g)"
printf 'start_epoch=%s\n' "$(/bin/date '+%s')"
/bin/sleep 2
printf 'end_epoch=%s\n' "$(/bin/date '+%s')"

