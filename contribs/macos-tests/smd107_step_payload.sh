#!/bin/sh

set -u

label=${1:-}
mode=${2:-}
record_dir=${3:-}
release_file=${4:-}

[ -n "$label" ] || exit 90
[ -n "$mode" ] || exit 91
[ -d "$record_dir" ] || exit 92

job_id=${SLURM_JOB_ID:-unset}
step_id=${SLURM_STEP_ID:-unset}
proc_id=${SLURM_PROCID:-unset}
local_id=${SLURM_LOCALID:-unset}
pid=$$
start_epoch=$(/bin/date '+%s')
ready_tmp=${record_dir}/.${label}.ready.${pid}
ready_file=${record_dir}/${label}.ready
done_file=${record_dir}/${label}.done

for value in "$job_id" "$step_id" "$proc_id" "$local_id" "$pid" "$start_epoch"; do
	case "$value" in
	''|*[!0-9]*) exit 93 ;;
	esac
done

{
	/usr/bin/printf 'label=%s\n' "$label"
	/usr/bin/printf 'mode=%s\n' "$mode"
	/usr/bin/printf 'job_id=%s\n' "$job_id"
	/usr/bin/printf 'step_id=%s\n' "$step_id"
	/usr/bin/printf 'proc_id=%s\n' "$proc_id"
	/usr/bin/printf 'local_id=%s\n' "$local_id"
	/usr/bin/printf 'pid=%s\n' "$pid"
	/usr/bin/printf 'uid=%s\n' "$(/usr/bin/id -u)"
	/usr/bin/printf 'gid=%s\n' "$(/usr/bin/id -g)"
	/usr/bin/printf 'node=%s\n' "$(/bin/hostname)"
	/usr/bin/printf 'start_epoch=%s\n' "$start_epoch"
} >"$ready_tmp" || exit 94
/bin/mv "$ready_tmp" "$ready_file" || exit 95

/usr/bin/printf '%s%s%s%s\n' \
	"record=step label=${label} mode=${mode}" \
	" job_id=${job_id} step_id=${step_id}" \
	" procid=${proc_id} localid=${local_id} pid=${pid}" \
	" uid=$(/usr/bin/id -u) gid=$(/usr/bin/id -g) node=$(/bin/hostname)"

case "$mode" in
success)
	;;
fail7)
	/usr/bin/printf 'controlled_failure label=%s exit=7\n' "$label" >&2
	exit 7
	;;
hold)
	attempt=0
	while [ ! -f "$release_file" ]; do
		[ "$attempt" -lt 300 ] || exit 96
		/bin/sleep 0.1
		attempt=$((attempt + 1))
	done
	;;
*)
	exit 97
	;;
esac

end_epoch=$(/bin/date '+%s')
{
	/usr/bin/printf 'label=%s\n' "$label"
	/usr/bin/printf 'step_id=%s\n' "$step_id"
	/usr/bin/printf 'pid=%s\n' "$pid"
	/usr/bin/printf 'end_epoch=%s\n' "$end_epoch"
} >"$done_file" || exit 98
/usr/bin/printf 'complete label=%s step_id=%s exit=0\n' "$label" "$step_id"

exit 0
