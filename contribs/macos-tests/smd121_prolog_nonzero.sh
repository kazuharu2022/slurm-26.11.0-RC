#!/bin/sh

set -u

job_id=${SLURM_JOB_ID:-}
context=${SLURM_SCRIPT_CONTEXT:-}
hook_dir=${0%/*}
event_log=${hook_dir%/*}/hook-events.log

case "$job_id" in
''|*[!0-9]*) exit 65 ;;
esac
[ "$context" = prolog_slurmd ] || exit 65

/usr/bin/printf 'event=prolog_nonzero job_id=%s epoch=%s euid=%s egid=%s context=%s exit_code=42\n' \
	"$job_id" "$(/bin/date '+%s')" "$(/usr/bin/id -u)" \
	"$(/usr/bin/id -g)" "$context" >>"$event_log"
exit 42

