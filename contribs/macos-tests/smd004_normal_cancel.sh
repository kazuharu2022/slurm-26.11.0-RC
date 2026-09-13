#!/bin/sh

printf 'ready case=normal_cancel pid=%s job_id=%s\n' "$$" "${SLURM_JOB_ID:-unset}"
exec /bin/sleep 300
