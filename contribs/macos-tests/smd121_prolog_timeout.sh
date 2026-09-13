#!/bin/sh

set -u

job_id=${SLURM_JOB_ID:-}
context=${SLURM_SCRIPT_CONTEXT:-}
hook_dir=${0%/*}
event_log=${hook_dir%/*}/hook-events.log
pid=$$
pgid=$(/bin/ps -o pgid= -p "$pid" | /usr/bin/tr -d ' ')

case "$job_id" in
''|*[!0-9]*) exit 65 ;;
esac
[ "$context" = prolog_slurmd ] || exit 65
case "$pgid" in
''|*[!0-9]*) exit 65 ;;
esac

/usr/bin/printf 'event=prolog_timeout_begin job_id=%s epoch=%s euid=%s egid=%s context=%s pid=%s pgid=%s\n' \
	"$job_id" "$(/bin/date '+%s')" "$(/usr/bin/id -u)" \
	"$(/usr/bin/id -g)" "$context" "$pid" "$pgid" >>"$event_log"

while :; do
	/bin/sleep 1
done
