#!/bin/sh

set -u

mode=${1:-}
case "$mode" in
success)
	probe=${2:-}
	[ -x "$probe" ] || exit 90
	/usr/bin/printf 'job_id=%s rank=%s task_count=%s\n' \
		"${SLURM_JOB_ID:-missing}" "${SLURM_PROCID:-missing}" \
		"${SLURM_NTASKS:-missing}"
	exec "$probe"
	;;
*) exit 93 ;;
esac
