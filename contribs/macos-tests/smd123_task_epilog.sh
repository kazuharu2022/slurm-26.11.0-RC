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

[ -n "$event_dir" ] || exit 65
[ -n "$payload_dir" ] || exit 65
[ "$context" = epilog_task ] || exit 66

payload_file=${payload_dir}/payload.${job_id}.${step_id}.${proc_id}.txt
[ -f "$payload_file" ] || exit 68

event_file=${event_dir}/epilog.${job_id}.${step_id}.${proc_id}.txt
/usr/bin/printf 'event=task_epilog job_id=%s step_id=%s procid=%s localid=%s euid=%s egid=%s context=%s payload_seen=YES\n' \
	"$job_id" "$step_id" "$proc_id" "$local_id" \
	"$(/usr/bin/id -u)" "$(/usr/bin/id -g)" "$context" \
	>"$event_file" || exit 67

exit 0
