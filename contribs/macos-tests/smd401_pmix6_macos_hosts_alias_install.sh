#!/bin/sh

set -u

if [ "${SMD401_PMIX6_MAC_HOST_ALIAS_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD401_PMIX6_MAC_HOST_ALIAS_CONFIRMED=YES after approval' >&2
	exit 64
fi

hosts=/etc/hosts
state_dir=/private/tmp/slurm-smd401-pmix6-host-alias-active
marker='192.168.10.180 ubuntu # SMD-401 temporary PMIx alias'
expected_before=e8595fbd163b74eb6191e76dbbaf5f7756c362a9a8c72ae63f7d0665a07a5522
mutated=0
success=0

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$mutated" -eq 1 ] && \
		[ -f "${state_dir}/hosts.before" ]; then
		/bin/cp -p "${state_dir}/hosts.before" "$hosts" || true
	fi
	exit "$rc"
}

fail()
{
	printf 'SMD401_PMIX6_MAC_HOST_ALIAS_INSTALL_FAILED error=%s\n' "$1" >&2
	exit 1
}

trap cleanup EXIT HUP INT TERM

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root'
[ -f "$hosts" ] || fail '/etc/hosts is not a regular file'
[ ! -e "$state_dir" ] || fail 'active alias state already exists'
before_sha=$(/usr/bin/shasum -a 256 "$hosts" | /usr/bin/awk '{print $1}')
[ "$before_sha" = "$expected_before" ] || fail 'unexpected /etc/hosts hash'
if /usr/bin/awk '
	$0 !~ /^[[:space:]]*#/ {
		for (i = 2; i <= NF; i++)
			if ($i == "ubuntu") found = 1
	}
	END { exit !found }
' "$hosts"; then
	fail 'ubuntu alias already exists'
fi

/bin/mkdir -m 0700 "$state_dir" || fail 'cannot create state directory'
/bin/cp -p "$hosts" "${state_dir}/hosts.before" || fail 'cannot back up /etc/hosts'
printf '%s\n' "$before_sha" >"${state_dir}/before.sha256" || \
	fail 'cannot save before hash'
printf '\n%s\n' "$marker" >>"$hosts" || fail 'cannot append temporary alias'
mutated=1
after_sha=$(/usr/bin/shasum -a 256 "$hosts" | /usr/bin/awk '{print $1}')
printf '%s\n' "$after_sha" >"${state_dir}/after.sha256" || \
	fail 'cannot save after hash'
printf '%s\n' "$marker" >"${state_dir}/marker" || fail 'cannot save marker'

/usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
/usr/bin/dscacheutil -q host -a name ubuntu | \
	/usr/bin/awk '$1 == "ip_address:" && $2 == "192.168.10.180" { found = 1 }
		END { exit !found }' || fail 'ubuntu does not resolve to 192.168.10.180'

success=1
trap - EXIT HUP INT TERM
printf '%s%s%s\n' \
	'SMD401_PMIX6_MAC_HOST_ALIAS_INSTALL_COMPLETE' \
	" before_sha256=$before_sha after_sha256=$after_sha" \
	" state_dir=$state_dir"
