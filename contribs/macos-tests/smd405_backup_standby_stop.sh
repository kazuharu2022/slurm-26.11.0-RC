#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_BACKUP_STANDBY_STOP_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_BACKUP_STANDBY_STOP_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib/smd405-runtime/lib:/usr/local/slurm/26.11.0/lib
export PATH LD_LIBRARY_PATH

state_dir=/var/tmp/slurm-smd405-backup-standby-active
expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b

fail()
{
	printf 'SMD405_BACKUP_STANDBY_STOP_FAILED error=%s state_dir=%s\n' "$1" "$state_dir" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(hostname -s)" = slurmctld-bak ] || fail 'unexpected backup hostname'
[ -f "${state_dir}/state.env" ] || fail 'active standby state is absent'
[ "$(sha256sum /usr/local/slurm/26.11.0/etc/slurm.conf | awk '{print $1}')" = \
	"$expected_config" ] || fail 'backup config hash mismatch'
[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = active ] || \
	fail 'backup service is not active'
[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || \
	fail 'backup service is not disabled'
scontrol ping >"${state_dir}/pre-stop-controller.txt" 2>&1 || true
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
	"${state_dir}/pre-stop-controller.txt" || fail 'primary is not UP'
[ -z "$(squeue -h)" ] || fail 'queue is not empty'

backup_pid=$(systemctl show -p MainPID --value slurmctld)
systemctl stop slurmctld || fail 'backup service stop failed'
attempt=0
while [ "$attempt" -lt 20 ] && systemctl is-active --quiet slurmctld; do
	attempt=$((attempt + 1))
	sleep 1
done
[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = inactive ] || \
	fail 'backup service did not become inactive'
pgrep -x slurmctld >/dev/null 2>&1 && fail 'backup slurmctld process remains'
[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || \
	fail 'backup service enablement changed'
timeout 3 bash -c 'exec 3<>/dev/tcp/192.168.10.180/6817' || \
	fail 'primary controller port is unreachable after backup stop'
printf '%s\n' \
	'primary_controller_tcp_6817=REACHABLE' \
	'authenticated_post_stop_ping=NOT_APPLICABLE_NO_LOCAL_SACK_DAEMON' \
	>"${state_dir}/post-stop-connectivity.txt"

archive=/var/tmp/slurm-smd405-backup-standby-stopped-$(date '+%Y%m%dT%H%M%S')
mv "$state_dir" "$archive"
chmod -R a+rX "$archive"
printf 'SMD405_BACKUP_STANDBY_STOP_PASS former_pid=%s primary_tcp=REACHABLE backup=INACTIVE service_enabled=disabled pre_stop_queue=EMPTY archive=%s\n' \
	"$backup_pid" "$archive"
