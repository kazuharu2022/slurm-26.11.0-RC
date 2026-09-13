#!/bin/sh

set -eu

if [ "$#" -ne 5 ]; then
	/usr/bin/printf '%s\n' \
		'usage: smd112_memory_job.sh FIXTURE RECORD_DIR MAX_MIB STAGE_MIB TIMEOUT' >&2
	exit 90
fi

fixture=$1
record_dir=$2
max_mib=$3
stage_mib=$4
timeout=$5

/usr/bin/printf 'job_id=%s\n' "${SLURM_JOB_ID:-none}"
/usr/bin/printf 'job_user=%s\n' "${SLURM_JOB_USER:-none}"
/usr/bin/printf 'actual_uid=%s\n' "$(/usr/bin/id -u)"
/usr/bin/printf 'actual_gid=%s\n' "$(/usr/bin/id -g)"
/usr/bin/printf 'slurm_mem_per_node=%s\n' "${SLURM_MEM_PER_NODE:-none}"

exec "$fixture" "$record_dir" "$max_mib" "$stage_mib" "$timeout"
