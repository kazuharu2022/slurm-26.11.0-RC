#!/bin/sh

set -u
umask 077

event_dir=${SMD123_EVENT_DIR:-}
payload_dir=${SMD123_PAYLOAD_DIR:-}
job_id=${SLURM_JOB_ID:-unknown}
step_id=${SLURM_STEP_ID:-unknown}
proc_id=${SLURM_PROCID:-unknown}
local_id=${SLURM_LOCALID:-unknown}
context=${SLURM_SCRIPT_CONTEXT:-unknown}
task_pid=${SLURM_TASK_PID:-unknown}

[ -n "$event_dir" ] || exit 65
[ -n "$payload_dir" ] || exit 65
[ "$context" = prolog_task ] || exit 66

event_file=${event_dir}/prolog.${job_id}.${step_id}.${proc_id}.txt
/usr/bin/printf 'event=task_prolog job_id=%s step_id=%s procid=%s localid=%s euid=%s egid=%s context=%s task_pid=%s\n' \
	"$job_id" "$step_id" "$proc_id" "$local_id" \
	"$(/usr/bin/id -u)" "$(/usr/bin/id -g)" "$context" "$task_pid" \
	>"$event_file" || exit 67

/usr/bin/printf 'export SMD123_PROLOG_VALUE=job_%s_step_%s_proc_%s\n' \
	"$job_id" "$step_id" "$proc_id"
/usr/bin/printf 'unset SMD123_SHOULD_BE_UNSET\n'
/usr/bin/printf 'print SMD123_TASK_PROLOG_PRINT job_id=%s step_id=%s procid=%s\n' \
	"$job_id" "$step_id" "$proc_id"

exit 0
