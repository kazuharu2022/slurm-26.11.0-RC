#!/bin/sh

set -eu

mode=$1
sequence=$2
record_dir=$3
job_id=${SLURM_JOB_ID:-missing}

/usr/bin/printf 'mode=%s\n' "$mode"
/usr/bin/printf 'sequence=%s\n' "$sequence"
/usr/bin/printf 'job_id=%s\n' "$job_id"
/usr/bin/printf 'uid=%s\n' "$(/usr/bin/id -u)"
/usr/bin/printf 'gid=%s\n' "$(/usr/bin/id -g)"

[ "$(/usr/bin/id -u)" = 3001 ] || exit 71
[ "$(/usr/bin/id -g)" = 3001 ] || exit 72

case "$mode" in
quick)
	;;
hold)
	tmp=${record_dir}/ready.${job_id}.tmp.$$
	ready=${record_dir}/ready.${job_id}
	{
		/usr/bin/printf 'job_id=%s\n' "$job_id"
		/usr/bin/printf 'sequence=%s\n' "$sequence"
		/usr/bin/printf 'pid=%s\n' "$$"
	} >"$tmp"
	/bin/mv "$tmp" "$ready"
	attempt=0
	while [ ! -f "${record_dir}/release" ]; do
		[ "$attempt" -lt 900 ] || exit 75
		/bin/sleep 0.1
		attempt=$((attempt + 1))
	done
	;;
*)
	/usr/bin/printf 'error: invalid mode=%s\n' "$mode" >&2
	exit 90
	;;
esac

/usr/bin/printf 'SMD111_PAYLOAD_PASS mode=%s job_id=%s sequence=%s\n' \
	"$mode" "$job_id" "$sequence"
