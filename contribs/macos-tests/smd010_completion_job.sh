#!/bin/sh

set -u

result_dir=$1
child_pid=

on_term()
{
	if [ -n "$child_pid" ]; then
		/bin/kill -TERM "$child_pid" >/dev/null 2>&1 || true
		wait "$child_pid" 2>/dev/null || true
	fi
	printf 'term_received batch_pid=%s epoch=%s\n' "$$" "$(/bin/date '+%s')"
	exit 143
}

trap on_term TERM INT HUP

/bin/sleep 8 &
child_pid=$!
printf 'batch_pid=%s\nchild_pid=%s\nstart_epoch=%s\n' \
	"$$" "$child_pid" "$(/bin/date '+%s')" >"${result_dir}/ready.txt"
printf 'ready batch_pid=%s child_pid=%s job_id=%s\n' \
	"$$" "$child_pid" "${SLURM_JOB_ID:-unknown}"

wait "$child_pid"
rc=$?
printf 'workload_complete batch_pid=%s child_pid=%s rc=%s epoch=%s\n' \
	"$$" "$child_pid" "$rc" "$(/bin/date '+%s')"
printf 'complete\n' >"${result_dir}/complete.txt"
exit "$rc"
