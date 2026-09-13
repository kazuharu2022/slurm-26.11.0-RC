#!/bin/sh

set -u

marker=${1:-}
[ -n "$marker" ] || exit 64

/usr/bin/printf 'SMD122_PAYLOAD_EXECUTED=YES job_id=%s uid=%s gid=%s\n' \
	"${SLURM_JOB_ID:-unknown}" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)" |
	/usr/bin/tee "$marker"
/bin/sleep 2
exit 0
