#!/bin/sh

set -eu

mode=$1
expected_home=$2
expected_path=$3
expected_lang=$4
expected_short=$5
expected_unicode=$6
expected_long_length=$7
expected_long_sha=$8

actual_uid=$(/usr/bin/id -u)
actual_gid=$(/usr/bin/id -g)
actual_user=$(/usr/bin/id -un)
actual_cwd=$(/bin/pwd -P)
long_length=$(/usr/bin/printf '%s' "${SMD104_LONG:-}" | /usr/bin/wc -c | /usr/bin/tr -d ' ')
long_sha=$(/usr/bin/printf '%s' "${SMD104_LONG:-}" | /usr/bin/shasum -a 256 |
	/usr/bin/awk 'NR == 1 { print $1; exit }')

if [ "${SMD104_EMPTY+x}" = x ] && [ -z "$SMD104_EMPTY" ]; then
	empty_state=SET_EMPTY
else
	empty_state=INVALID
fi
if [ "${SMD104_UNSET+x}" = x ]; then
	unset_state=PRESENT
else
	unset_state=ABSENT
fi
if [ "${SMD104_PARENT_ONLY+x}" = x ]; then
	parent_only_state=PRESENT
else
	parent_only_state=ABSENT
fi

/usr/bin/printf 'mode=%s\n' "$mode"
/usr/bin/printf 'job_id=%s\n' "${SLURM_JOB_ID:-missing}"
/usr/bin/printf 'step_id=%s\n' "${SLURM_STEP_ID:-batch}"
/usr/bin/printf 'actual_user=%s\n' "$actual_user"
/usr/bin/printf 'actual_uid=%s\n' "$actual_uid"
/usr/bin/printf 'actual_gid=%s\n' "$actual_gid"
/usr/bin/printf 'home=%s\n' "${HOME:-unset}"
/usr/bin/printf 'path=%s\n' "${PATH:-unset}"
/usr/bin/printf 'lang=%s\n' "${LANG:-unset}"
/usr/bin/printf 'lc_all=%s\n' "${LC_ALL:-unset}"
/usr/bin/printf 'short=%s\n' "${SMD104_SHORT:-unset}"
/usr/bin/printf 'unicode=%s\n' "${SMD104_UNICODE:-unset}"
/usr/bin/printf 'empty_state=%s\n' "$empty_state"
/usr/bin/printf 'long_length=%s\n' "$long_length"
/usr/bin/printf 'long_sha256=%s\n' "$long_sha"
/usr/bin/printf 'unset_state=%s\n' "$unset_state"
/usr/bin/printf 'parent_only_state=%s\n' "$parent_only_state"
/usr/bin/printf 'cwd=%s\n' "$actual_cwd"

[ "$actual_user" = testuser ] || exit 71
[ "$actual_uid" = 3001 ] || exit 72
[ "$actual_gid" = 3001 ] || exit 73
[ "${HOME:-unset}" = "$expected_home" ] || exit 74
[ "${PATH:-unset}" = "$expected_path" ] || exit 75
[ "${LANG:-unset}" = "$expected_lang" ] || exit 76
[ "${LC_ALL:-unset}" = "$expected_lang" ] || exit 77
[ "${SMD104_SHORT:-unset}" = "$expected_short" ] || exit 78
[ "${SMD104_UNICODE:-unset}" = "$expected_unicode" ] || exit 79
[ "$empty_state" = SET_EMPTY ] || exit 80
[ "$long_length" = "$expected_long_length" ] || exit 81
[ "$long_sha" = "$expected_long_sha" ] || exit 82
[ "$unset_state" = ABSENT ] || exit 83
[ "$parent_only_state" = ABSENT ] || exit 84
[ "$actual_cwd" = /private/tmp ] || exit 85

/usr/bin/printf 'SMD104_PAYLOAD_PASS mode=%s\n' "$mode"
