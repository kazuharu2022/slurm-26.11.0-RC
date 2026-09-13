#!/bin/sh

set -u

marker=${1:-}
job_id=${SLURM_JOB_ID:-}

case "$marker" in
/tmp/slurm-smd121-*/output/*.marker) ;;
*)
	/usr/bin/printf 'invalid marker path\n' >&2
	exit 65
	;;
esac
case "$job_id" in
''|*[!0-9]*) exit 65 ;;
esac

umask 077
/usr/bin/printf 'SMD121_PAYLOAD_EXECUTED=YES job_id=%s uid=%s gid=%s\n' \
	"$job_id" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)" | \
	/usr/bin/tee "$marker"
