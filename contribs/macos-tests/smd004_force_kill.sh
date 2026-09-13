#!/bin/sh

trap '' TERM
printf 'ready case=force_kill pid=%s job_id=%s\n' "$$" "${SLURM_JOB_ID:-unset}"
exec /bin/sleep 300
