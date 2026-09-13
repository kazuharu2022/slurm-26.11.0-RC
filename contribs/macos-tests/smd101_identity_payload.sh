#!/bin/sh

set -eu

expected_user=$1
expected_uid=$2
expected_gid=$3
shared_gid=$4
marker_path=$5

actual_user=$(/usr/bin/id -un)
actual_uid=$(/usr/bin/id -u)
actual_gid=$(/usr/bin/id -g)
actual_groups=$(/usr/bin/id -G)

printf 'job_id=%s\n' "${SLURM_JOB_ID:-missing}"
printf 'job_user=%s\n' "${SLURM_JOB_USER:-missing}"
printf 'actual_user=%s\n' "$actual_user"
printf 'actual_uid=%s\n' "$actual_uid"
printf 'actual_gid=%s\n' "$actual_gid"
printf 'actual_groups=%s\n' "$actual_groups"
printf 'home=%s\n' "${HOME:-unset}"
printf 'cwd=%s\n' "$(/bin/pwd -P)"

[ "$actual_user" = "$expected_user" ] || exit 71
[ "$actual_uid" = "$expected_uid" ] || exit 72
[ "$actual_gid" = "$expected_gid" ] || exit 73

case " $actual_groups " in
*" $shared_gid "*) ;;
*) exit 74 ;;
esac

umask 077
printf 'created_by=%s uid=%s gid=%s job_id=%s\n' \
	"$actual_user" "$actual_uid" "$actual_gid" "${SLURM_JOB_ID:-missing}" \
	>"$marker_path"
/bin/chmod 0600 "$marker_path"

printf 'marker_path=%s\n' "$marker_path"
marker_identity_mode=$(/usr/bin/stat -f '%u:%g:%Lp' "$marker_path")
printf 'marker_identity_mode=%s\n' "$marker_identity_mode"
[ "$marker_identity_mode" = "$expected_uid:$expected_gid:600" ] || exit 75
printf 'SMD101_PAYLOAD_PASS user=%s uid=%s gid=%s shared_gid=%s\n' \
	"$actual_user" "$actual_uid" "$actual_gid" "$shared_gid"
