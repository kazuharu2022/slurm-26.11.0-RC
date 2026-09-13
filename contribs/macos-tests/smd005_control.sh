#!/bin/sh

set -u

printf 'control_ready pid=%s job_id=%s\n' "$$" "${SLURM_JOB_ID:-unknown}"
exec /bin/sleep 180
