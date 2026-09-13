#!/bin/sh

set -u

job_id=${SLURM_JOB_ID:-}

case "$job_id" in
''|*[!0-9]*)
	/usr/bin/printf 'smd120 payload: invalid SLURM_JOB_ID\n' >&2
	exit 65
	;;
esac

/usr/bin/printf 'payload_event=begin job_id=%s epoch=%s euid=%s egid=%s\n' \
	"$job_id" "$(/bin/date '+%s')" "$(/usr/bin/id -u)" \
	"$(/usr/bin/id -g)"
/bin/sleep 2
/usr/bin/printf 'payload_event=end job_id=%s epoch=%s\n' \
	"$job_id" "$(/bin/date '+%s')"

