#!/bin/sh

trap 'trap - TERM; printf "term_received pid=%s\n" "$$"; exit 42' TERM
printf 'ready case=term pid=%s job_id=%s\n' "$$" "${SLURM_JOB_ID:-unset}"

while :; do
	/bin/sleep 1
done
