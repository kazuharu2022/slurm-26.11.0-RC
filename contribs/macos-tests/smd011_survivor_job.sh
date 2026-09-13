#!/bin/sh

set -u

result_dir=$1
finish_file=${result_dir}/finish-requested.txt
heartbeat_file=${result_dir}/heartbeat.txt
child_pid=

worker_loop()
{
	count=0
	while [ "$count" -lt 840 ]; do
		if [ -f "$finish_file" ]; then
			printf 'finish_seen count=%s epoch=%s\n' \
				"$count" "$(/bin/date '+%s')"
			return 0
		fi
		printf 'count=%s epoch=%s child_pid=%s\n' \
			"$count" "$(/bin/date '+%s')" "$$" \
			>"${heartbeat_file}.tmp"
		/bin/mv "${heartbeat_file}.tmp" "$heartbeat_file"
		/bin/sleep 1
		count=$((count + 1))
	done
	printf 'finish_request_timeout count=%s epoch=%s\n' \
		"$count" "$(/bin/date '+%s')" >&2
	return 124
}

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

worker_loop &
child_pid=$!
printf 'batch_pid=%s\nchild_pid=%s\nstart_epoch=%s\n' \
	"$$" "$child_pid" "$(/bin/date '+%s')" >"${result_dir}/ready.txt"
printf 'ready batch_pid=%s child_pid=%s job_id=%s\n' \
	"$$" "$child_pid" "${SLURM_JOB_ID:-unknown}"

wait "$child_pid"
rc=$?
printf 'survivor_complete batch_pid=%s child_pid=%s rc=%s epoch=%s\n' \
	"$$" "$child_pid" "$rc" "$(/bin/date '+%s')"
exit "$rc"
