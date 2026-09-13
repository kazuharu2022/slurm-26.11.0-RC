#!/bin/sh

set -u

mode=${1:-}
sequence=${2:-}
record_dir=${3:-}

case "$mode" in
normal|cancel) ;;
*) exit 90 ;;
esac
case "$sequence" in
''|*[!0-9]*) exit 91 ;;
esac
[ -d "$record_dir" ] || exit 92

if [ -e /proc ]; then
	proc_state=PRESENT
else
	proc_state=ABSENT
fi

if [ "${SLURMSTEPD_OOM_ADJ+x}" = x ]; then
	oom_state=$SLURMSTEPD_OOM_ADJ
else
	oom_state=UNSET
fi

/usr/bin/printf 'mode=%s\n' "$mode"
/usr/bin/printf 'sequence=%s\n' "$sequence"
/usr/bin/printf 'job_id=%s\n' "${SLURM_JOB_ID:-missing}"
/usr/bin/printf 'actual_uid=%s\n' "$(/usr/bin/id -u)"
/usr/bin/printf 'actual_gid=%s\n' "$(/usr/bin/id -g)"
/usr/bin/printf 'proc_state=%s\n' "$proc_state"
/usr/bin/printf 'oom_adj=%s\n' "$oom_state"

[ "$proc_state" = ABSENT ] || exit 80
[ "$(/usr/bin/id -u)" = 3001 ] || exit 81
[ "$(/usr/bin/id -g)" = 3001 ] || exit 82

case "$mode" in
normal)
	pids=
	for child_index in 1 2 3 4; do
		/bin/sleep 1 &
		pids="${pids} $!"
	done
	for child_pid in $pids; do
		wait "$child_pid" || exit 83
	done
	/usr/bin/printf '%s\n' \
		"SMD306_PAYLOAD_PASS sequence=$sequence children=4"
	;;
cancel)
	child_record=${record_dir}/cancel-${sequence}-child.txt
	ready_record=${record_dir}/cancel-${sequence}-ready.txt
	(
		/bin/sleep 120 &
		grandchild_pid=$!
		/usr/bin/printf 'grandchild_pid=%s\n' "$grandchild_pid" \
			>"$child_record"
		wait "$grandchild_pid"
	) &
	child_pid=$!
	/bin/sleep 120 &
	sibling_pid=$!
	/usr/bin/printf '%s\n' \
		"coordinator_pid=$$" \
		"child_pid=$child_pid" \
		"sibling_pid=$sibling_pid" >"$ready_record"
	/usr/bin/printf '%s\n' \
		"SMD306_CANCEL_READY sequence=$sequence coordinator=$$ child=$child_pid sibling=$sibling_pid"
	wait
	;;
esac
