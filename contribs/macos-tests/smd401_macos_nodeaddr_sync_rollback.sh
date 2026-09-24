#!/bin/sh

set -u

if [ "${SMD401_MAC_NODEADDR_SYNC_ROLLBACK_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD401_MAC_NODEADDR_SYNC_ROLLBACK_CONFIRMED=YES after approval' >&2
	exit 64
fi

conf=/opt/slurm/26.11.0/etc/slurm.conf
scontrol=/opt/slurm/26.11.0/bin/scontrol
state_dir=/private/tmp/slurm-smd401-nodeaddr-sync-active
expected_before=70d5f437c6622b860e3eff7c029dcd713a073bfdf90395f5399c9c95f50d16a0
expected_after=62bcea15398de5f373132a1a3ef21c005c184c20f483da076b44eb5af284f157
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
retained=/private/tmp/slurm-smd401-nodeaddr-sync-restored-${run_stamp}

fail()
{
	printf 'SMD401_MAC_NODEADDR_SYNC_ROLLBACK_FAILED error=%s\n' "$1" >&2
	exit 1
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root'
[ -f "${state_dir}/slurm.conf.before" ] || fail 'backup is absent'
[ "$(/usr/bin/shasum -a 256 "${state_dir}/slurm.conf.before" | \
	/usr/bin/awk '{print $1}')" = "$expected_before" ] || fail 'backup hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$conf" | /usr/bin/awk '{print $1}')" = \
	"$expected_after" ] || fail 'production config changed after sync'

/bin/cp -p "${state_dir}/slurm.conf.before" "$conf" || fail 'cannot restore slurm.conf'
[ "$(/usr/bin/shasum -a 256 "$conf" | /usr/bin/awk '{print $1}')" = \
	"$expected_before" ] || fail 'restored config hash mismatch'
SLURM_CONF="$conf" "$scontrol" ping >"${state_dir}/rollback-ping.out" \
	2>"${state_dir}/rollback-ping.err" || fail 'restored config cannot reach controller'
/usr/bin/grep -F 'Slurmctld(primary) at ubuntu2504 is UP' \
	"${state_dir}/rollback-ping.out" >/dev/null || fail 'restored controller is not UP'
[ ! -s "${state_dir}/rollback-ping.err" ] || fail 'restored ping emitted stderr'
/bin/mv "$state_dir" "$retained" || fail 'cannot retain completed state directory'

printf '%s%s\n' \
	'SMD401_MAC_NODEADDR_SYNC_ROLLBACK_COMPLETE' \
	" restored_sha256=$expected_before retained_state=$retained"
