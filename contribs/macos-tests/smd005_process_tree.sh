#!/bin/sh

set -u

run_dir=$1
stage_dir=$2

"${stage_dir}/smd005_child_tree.sh" "$run_dir" &
child_pid=$!

/bin/sleep 180 &
background_pid=$!

printf 'batch\t%s\nchild\t%s\nbackground\t%s\n' \
	"$$" "$child_pid" "$background_pid" >"${run_dir}/target-pids.tsv"

attempt=0
while [ ! -s "${run_dir}/grandchild.pid" ] && [ "$attempt" -lt 100 ]; do
	/bin/sleep 0.1
	attempt=$((attempt + 1))
done

if [ ! -s "${run_dir}/grandchild.pid" ]; then
	printf 'grandchild pid was not recorded\n' >&2
	exit 1
fi

/bin/cat "${run_dir}/grandchild.pid" >>"${run_dir}/target-pids.tsv"
printf 'tree_ready batch_pid=%s child_pid=%s background_pid=%s\n' \
	"$$" "$child_pid" "$background_pid"
printf 'ready\n' >"${run_dir}/target.ready"

wait
