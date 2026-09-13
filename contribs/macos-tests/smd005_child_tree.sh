#!/bin/sh

set -u

run_dir=$1

/bin/sleep 180 &
grandchild_pid=$!
printf 'grandchild\t%s\n' "$grandchild_pid" >"${run_dir}/grandchild.pid"
printf 'child_ready child_pid=%s grandchild_pid=%s\n' "$$" "$grandchild_pid"

wait "$grandchild_pid"
