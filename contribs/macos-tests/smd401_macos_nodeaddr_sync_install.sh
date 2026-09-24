#!/bin/sh

set -u

if [ "${SMD401_MAC_NODEADDR_SYNC_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD401_MAC_NODEADDR_SYNC_CONFIRMED=YES after approval' >&2
	exit 64
fi

conf=/opt/slurm/26.11.0/etc/slurm.conf
scontrol=/opt/slurm/26.11.0/bin/scontrol
state_dir=/private/tmp/slurm-smd401-nodeaddr-sync-active
expected_before=70d5f437c6622b860e3eff7c029dcd713a073bfdf90395f5399c9c95f50d16a0
expected_after=62bcea15398de5f373132a1a3ef21c005c184c20f483da076b44eb5af284f157
old_line='NodeName=ubuntu CPUs=8 Boards=1 SocketsPerBoard=8 CoresPerSocket=1 ThreadsPerCore=1 RealMemory=15990'
new_line='NodeName=ubuntu NodeAddr=192.168.10.180 NodeHostName=ubuntu2504 CPUs=8 Boards=1 SocketsPerBoard=1 CoresPerSocket=4 ThreadsPerCore=2 RealMemory=64024'
mutated=0
success=0

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$mutated" -eq 1 ] && \
		[ -f "${state_dir}/slurm.conf.before" ]; then
		/bin/cp -p "${state_dir}/slurm.conf.before" "$conf" || true
	fi
	exit "$rc"
}

fail()
{
	printf 'SMD401_MAC_NODEADDR_SYNC_INSTALL_FAILED error=%s\n' "$1" >&2
	exit 1
}

trap cleanup EXIT HUP INT TERM

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root'
[ -f "$conf" ] || fail 'production slurm.conf is absent'
[ -x "$scontrol" ] || fail 'production scontrol is absent'
[ ! -e "$state_dir" ] || fail 'active node address sync state already exists'
before_sha=$(/usr/bin/shasum -a 256 "$conf" | /usr/bin/awk '{print $1}')
[ "$before_sha" = "$expected_before" ] || fail 'unexpected production slurm.conf hash'
[ "$(/usr/bin/grep -Fxc "$old_line" "$conf")" -eq 1 ] || \
	fail 'expected Ubuntu node line count is not one'
[ "$(/usr/bin/grep -Fxc "$new_line" "$conf")" -eq 0 ] || \
	fail 'candidate Ubuntu node line already exists'

/bin/mkdir -m 0700 "$state_dir" || fail 'cannot create state directory'
/bin/cp -p "$conf" "${state_dir}/slurm.conf.before" || fail 'cannot back up slurm.conf'
/usr/bin/awk -v old="$old_line" -v new="$new_line" '
	$0 == old { print new; count++; next }
	{ print }
	END { if (count != 1) exit 70 }
' "$conf" >"${state_dir}/slurm.conf.candidate" || fail 'cannot build candidate config'
candidate_sha=$(/usr/bin/shasum -a 256 "${state_dir}/slurm.conf.candidate" | \
	/usr/bin/awk '{print $1}')
[ "$candidate_sha" = "$expected_after" ] || fail 'candidate config hash mismatch'
SLURM_CONF="${state_dir}/slurm.conf.candidate" "$scontrol" ping \
	>"${state_dir}/candidate-ping.out" \
	2>"${state_dir}/candidate-ping.err" || fail 'candidate config cannot reach controller'
/usr/bin/grep -F 'Slurmctld(primary) at ubuntu2504 is UP' \
	"${state_dir}/candidate-ping.out" >/dev/null || fail 'candidate controller is not UP'
[ ! -s "${state_dir}/candidate-ping.err" ] || fail 'candidate ping emitted stderr'

/bin/cp -p "${state_dir}/slurm.conf.candidate" "$conf" || \
	fail 'cannot install candidate config'
mutated=1
[ "$(/usr/bin/shasum -a 256 "$conf" | /usr/bin/awk '{print $1}')" = \
	"$expected_after" ] || fail 'installed config hash mismatch'
printf '%s\n' "$before_sha" >"${state_dir}/before.sha256" || \
	fail 'cannot save before hash'
printf '%s\n' "$candidate_sha" >"${state_dir}/after.sha256" || \
	fail 'cannot save after hash'

success=1
trap - EXIT HUP INT TERM
printf '%s%s%s\n' \
	'SMD401_MAC_NODEADDR_SYNC_INSTALL_COMPLETE' \
	" before_sha256=$before_sha after_sha256=$candidate_sha" \
	" state_dir=$state_dir"
