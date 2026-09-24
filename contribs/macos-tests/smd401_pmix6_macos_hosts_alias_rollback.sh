#!/bin/sh

set -u

if [ "${SMD401_PMIX6_MAC_HOST_ALIAS_ROLLBACK_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD401_PMIX6_MAC_HOST_ALIAS_ROLLBACK_CONFIRMED=YES after approval' >&2
	exit 64
fi

hosts=/etc/hosts
state_dir=/private/tmp/slurm-smd401-pmix6-host-alias-active
expected_before=e8595fbd163b74eb6191e76dbbaf5f7756c362a9a8c72ae63f7d0665a07a5522
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
retained=/private/tmp/slurm-smd401-pmix6-host-alias-restored-${run_stamp}

fail()
{
	printf 'SMD401_PMIX6_MAC_HOST_ALIAS_ROLLBACK_FAILED error=%s\n' "$1" >&2
	exit 1
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root'
[ -f "${state_dir}/hosts.before" ] || fail 'backup is absent'
[ -f "${state_dir}/before.sha256" ] || fail 'before hash is absent'
[ -f "${state_dir}/after.sha256" ] || fail 'after hash is absent'
before_sha=$(/bin/cat "${state_dir}/before.sha256")
after_sha=$(/bin/cat "${state_dir}/after.sha256")
[ "$before_sha" = "$expected_before" ] || fail 'unexpected recorded before hash'
[ "$(/usr/bin/shasum -a 256 "${state_dir}/hosts.before" | /usr/bin/awk '{print $1}')" = \
	"$before_sha" ] || fail 'backup hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$hosts" | /usr/bin/awk '{print $1}')" = \
	"$after_sha" ] || fail 'current /etc/hosts changed after alias install'

/bin/cp -p "${state_dir}/hosts.before" "$hosts" || fail 'cannot restore /etc/hosts'
[ "$(/usr/bin/shasum -a 256 "$hosts" | /usr/bin/awk '{print $1}')" = \
	"$before_sha" ] || fail 'restored /etc/hosts hash mismatch'
/usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
/bin/mv "$state_dir" "$retained" || fail 'cannot retain completed state directory'

printf '%s%s%s\n' \
	'SMD401_PMIX6_MAC_HOST_ALIAS_ROLLBACK_COMPLETE' \
	" restored_sha256=$before_sha" \
	" retained_state=$retained"
