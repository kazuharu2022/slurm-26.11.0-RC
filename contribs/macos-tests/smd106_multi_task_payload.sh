#!/bin/sh

set -u

record_dir=${1:-}

[ -n "$record_dir" ] || exit 90
[ -d "$record_dir" ] || exit 91

job_id=${SLURM_JOB_ID:-unset}
step_id=${SLURM_STEP_ID:-unset}
proc_id=${SLURM_PROCID:-unset}
local_id=${SLURM_LOCALID:-unset}
node_id=${SLURM_NODEID:-unset}
task_count=${SLURM_NTASKS:-unset}
step_task_count=${SLURM_STEP_NUM_TASKS:-unset}
node_count=${SLURM_NNODES:-unset}
pid=$$
start_epoch=$(/bin/date '+%s')
ready_tmp=${record_dir}/.ready.${proc_id}.${pid}
ready_file=${record_dir}/ready.${proc_id}
done_file=${record_dir}/done.${proc_id}
release_file=${record_dir}/release

for value in "$job_id" "$step_id" "$proc_id" "$local_id" "$node_id" \
	"$task_count" "$step_task_count" "$node_count" "$pid" "$start_epoch"; do
	case "$value" in
	''|*[!0-9]*) exit 92 ;;
	esac
done

{
	/usr/bin/printf 'job_id=%s\n' "$job_id"
	/usr/bin/printf 'step_id=%s\n' "$step_id"
	/usr/bin/printf 'proc_id=%s\n' "$proc_id"
	/usr/bin/printf 'local_id=%s\n' "$local_id"
	/usr/bin/printf 'node_id=%s\n' "$node_id"
	/usr/bin/printf 'task_count=%s\n' "$task_count"
	/usr/bin/printf 'step_task_count=%s\n' "$step_task_count"
	/usr/bin/printf 'node_count=%s\n' "$node_count"
	/usr/bin/printf 'pid=%s\n' "$pid"
	/usr/bin/printf 'start_epoch=%s\n' "$start_epoch"
	/usr/bin/printf 'uid=%s\n' "$(/usr/bin/id -u)"
	/usr/bin/printf 'gid=%s\n' "$(/usr/bin/id -g)"
	/usr/bin/printf 'node=%s\n' "$(/bin/hostname)"
} >"$ready_tmp" || exit 93
/bin/mv "$ready_tmp" "$ready_file" || exit 94

attempt=0
while [ ! -f "$release_file" ]; do
	[ "$attempt" -lt 300 ] || exit 95
	/bin/sleep 0.1
	attempt=$((attempt + 1))
done

release_epoch=$(/bin/date '+%s')
/usr/bin/printf '%s%s%s%s%s%s%s\n' \
	"record=task job_id=${job_id} step_id=${step_id}" \
	" procid=${proc_id} localid=${local_id} nodeid=${node_id}" \
	" ntasks=${task_count} step_ntasks=${step_task_count}" \
	" nnodes=${node_count} pid=${pid}" \
	" uid=$(/usr/bin/id -u) gid=$(/usr/bin/id -g)" \
	" node=$(/bin/hostname) start=${start_epoch}" \
	" release=${release_epoch}"

/bin/sleep 2
end_epoch=$(/bin/date '+%s')
{
	/usr/bin/printf 'proc_id=%s\n' "$proc_id"
	/usr/bin/printf 'pid=%s\n' "$pid"
	/usr/bin/printf 'end_epoch=%s\n' "$end_epoch"
} >"$done_file" || exit 96

exit 0
