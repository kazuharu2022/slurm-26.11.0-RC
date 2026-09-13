#!/bin/bash

set -euo pipefail

mlx_job=${1:?missing MLX job path}
heartbeat_file=${2:?missing heartbeat file}

echo "payload_pid=$$"
echo "actual_uid=$(/usr/bin/id -u)"
echo "actual_gid=$(/usr/bin/id -g)"
echo "job_gpus=${SLURM_JOB_GPUS:-unset}"

/bin/bash "$mlx_job"

sequence=0
while [ "$sequence" -lt 180 ]; do
	sequence=$((sequence + 1))
	epoch=$(/bin/date '+%s')
	/usr/bin/printf '%s %s\n' "$sequence" "$epoch" >"$heartbeat_file"
	if [ "$sequence" -eq 1 ]; then
		echo "restart_ready sequence=${sequence} epoch=${epoch}"
	fi
	/bin/sleep 1
done

echo "survivor_natural_end sequence=${sequence}"
