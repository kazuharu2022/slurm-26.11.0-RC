#!/bin/sh

set -u
umask 077

payload_dir=${SMD123_PAYLOAD_DIR:-}
job_id=${SLURM_JOB_ID:-unknown}
step_id=${SLURM_STEP_ID:-unknown}
proc_id=${SLURM_PROCID:-unknown}
local_id=${SLURM_LOCALID:-unknown}
prolog_value=${SMD123_PROLOG_VALUE:-}
expected_value=job_${job_id}_step_${step_id}_proc_${proc_id}

[ -n "$payload_dir" ] || exit 65
[ "$prolog_value" = "$expected_value" ] || exit 69
if [ "${SMD123_SHOULD_BE_UNSET+x}" = x ]; then
	exit 70
fi

payload_file=${payload_dir}/payload.${job_id}.${step_id}.${proc_id}.txt
/usr/bin/printf 'event=payload job_id=%s step_id=%s procid=%s localid=%s euid=%s egid=%s prolog_value=%s unset_verified=YES\n' \
	"$job_id" "$step_id" "$proc_id" "$local_id" \
	"$(/usr/bin/id -u)" "$(/usr/bin/id -g)" "$prolog_value" \
	>"$payload_file" || exit 71

/bin/sleep 1
exit 0
