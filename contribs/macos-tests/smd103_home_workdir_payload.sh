#!/bin/sh

set -eu

case_name=$1
expected_home=$2
expected_cwd=$3
denied_dir=$4

actual_user=$(/usr/bin/id -un)
actual_uid=$(/usr/bin/id -u)
actual_gid=$(/usr/bin/id -g)
actual_home=${HOME:-unset}
actual_cwd=$(/bin/pwd -P)

/usr/bin/printf 'case=%s\n' "$case_name"
/usr/bin/printf 'job_id=%s\n' "${SLURM_JOB_ID:-missing}"
/usr/bin/printf 'job_user=%s\n' "${SLURM_JOB_USER:-missing}"
/usr/bin/printf 'actual_user=%s\n' "$actual_user"
/usr/bin/printf 'actual_uid=%s\n' "$actual_uid"
/usr/bin/printf 'actual_gid=%s\n' "$actual_gid"
/usr/bin/printf 'home=%s\n' "$actual_home"
/usr/bin/printf 'cwd=%s\n' "$actual_cwd"

[ "$actual_user" = testuser ] || exit 71
[ "$actual_uid" = 3001 ] || exit 72
[ "$actual_gid" = 3001 ] || exit 73
[ "$actual_home" = "$expected_home" ] || exit 74
[ "$actual_cwd" = "$expected_cwd" ] || exit 75

if [ "$case_name" = denied ]; then
	if /bin/test -x "$denied_dir"; then
		/usr/bin/printf 'error=denied_directory_is_searchable\n' >&2
		exit 76
	fi
	if /bin/test -r "${denied_dir}/root-only-marker"; then
		/usr/bin/printf 'error=denied_marker_is_readable\n' >&2
		exit 77
	fi
	/usr/bin/printf 'denied_directory_access=BLOCKED\n'
else
	[ "$actual_cwd" != "$denied_dir" ] || exit 78
fi

/usr/bin/printf 'SMD103_PAYLOAD_PASS case=%s home=%s cwd=%s\n' \
	"$case_name" "$actual_home" "$actual_cwd"
