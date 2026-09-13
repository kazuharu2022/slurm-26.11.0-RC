#!/bin/sh

set -u

job_id=${SLURM_JOB_ID:-}
context=${SLURM_SCRIPT_CONTEXT:-}
hook_dir=${0%/*}
event_log=${hook_dir%/*}/hook-events.log

case "$job_id" in
''|*[!0-9]*)
	/usr/bin/printf 'smd120 prolog: invalid SLURM_JOB_ID\n' >&2
	exit 65
	;;
esac

if [ "$context" != prolog_slurmd ]; then
	/usr/bin/printf 'smd120 prolog: unexpected context=%s\n' "$context" >&2
	exit 65
fi

/usr/bin/printf 'event=prolog job_id=%s epoch=%s euid=%s egid=%s context=%s\n' \
	"$job_id" "$(/bin/date '+%s')" "$(/usr/bin/id -u)" \
	"$(/usr/bin/id -g)" "$context" >>"$event_log"

