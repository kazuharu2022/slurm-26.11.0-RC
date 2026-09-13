#!/bin/sh

set -eu

case_name=$1
expected_umask=$2
case_dir=$3
created_file=${case_dir}/created-file.txt
created_dir=${case_dir}/created-dir
nested_file=${created_dir}/nested-file.txt

current_umask=$(umask)
case "${expected_umask}:${current_umask}" in
022:0022|022:022) normalized_umask=022 ;;
027:0027|027:027) normalized_umask=027 ;;
077:0077|077:077) normalized_umask=077 ;;
*) normalized_umask=INVALID ;;
esac

/usr/bin/printf 'created_by_job=%s\n' "${SLURM_JOB_ID:-missing}" >"$created_file"
/bin/mkdir "$created_dir"
/usr/bin/printf 'nested_by_job=%s\n' "${SLURM_JOB_ID:-missing}" >"$nested_file"

/usr/bin/printf 'case=%s\n' "$case_name"
/usr/bin/printf 'job_id=%s\n' "${SLURM_JOB_ID:-missing}"
/usr/bin/printf 'actual_user=%s\n' "$(/usr/bin/id -un)"
/usr/bin/printf 'actual_uid=%s\n' "$(/usr/bin/id -u)"
/usr/bin/printf 'actual_gid=%s\n' "$(/usr/bin/id -g)"
/usr/bin/printf 'current_umask=%s\n' "$current_umask"
/usr/bin/printf 'normalized_umask=%s\n' "$normalized_umask"
/usr/bin/printf 'created_file=%s\n' "$created_file"
/usr/bin/printf 'created_dir=%s\n' "$created_dir"
/usr/bin/printf 'nested_file=%s\n' "$nested_file"

[ "$(/usr/bin/id -un)" = testuser ] || exit 71
[ "$(/usr/bin/id -u)" = 3001 ] || exit 72
[ "$(/usr/bin/id -g)" = 3001 ] || exit 73
[ "$normalized_umask" = "$expected_umask" ] || exit 74

/usr/bin/printf 'SMD105_PAYLOAD_PASS case=%s umask=%s\n' \
	"$case_name" "$normalized_umask"
