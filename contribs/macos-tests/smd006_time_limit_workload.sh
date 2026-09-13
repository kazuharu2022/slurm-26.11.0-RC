#!/bin/sh

set -u

run_dir=$1

on_term()
{
	printf 'term_received batch_pid=%s epoch=%s\n' "$$" "$(/bin/date '+%s')"
	exit 124
}

trap on_term TERM

/bin/sleep 180 &
child_pid=$!
printf 'batch\t%s\nchild\t%s\n' "$$" "$child_pid" >"${run_dir}/pids.tsv"
printf 'ready batch_pid=%s child_pid=%s epoch=%s\n' \
	"$$" "$child_pid" "$(/bin/date '+%s')"
printf 'ready\n' >"${run_dir}/workload.ready"

wait "$child_pid"
rc=$?
printf 'unexpected_wait_return rc=%s\n' "$rc" >&2
exit "$rc"
