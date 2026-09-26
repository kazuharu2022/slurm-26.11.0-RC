#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_PRIMARY_CONFIG_ROLLBACK_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_PRIMARY_CONFIG_ROLLBACK_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib
export PATH LD_LIBRARY_PATH

config=/usr/local/slurm/26.11.0/etc/slurm.conf
state_dir=/var/tmp/slurm-smd405-controller-sync-active
expected_before=1e6c257b82aa82e507eb710a3e37690ffcfd7b402cb2b33fde53ed9bb1651c68
expected_after=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b

fail()
{
	printf 'SMD405_PRIMARY_CONFIG_ROLLBACK_FAILED error=%s state_dir=%s\n' "$1" "$state_dir" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(hostname -s)" = ubuntu2504 ] || fail 'unexpected primary hostname'
[ -f "${state_dir}/slurm.conf.before" ] || fail 'rollback backup is absent'
[ "$(sha256sum "$config" | awk '{print $1}')" = "$expected_after" ] || \
	fail 'active config hash mismatch'
[ "$(sha256sum "${state_dir}/slurm.conf.before" | awk '{print $1}')" = "$expected_before" ] || \
	fail 'rollback backup hash mismatch'
[ "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)" = \
	active,active,active ] || fail 'production service is not fully active'
[ -z "$(squeue -h)" ] || fail 'queue is not empty'
scontrol ping >"${state_dir}/rollback-pre-controller.txt" 2>&1 || true
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
	"${state_dir}/rollback-pre-controller.txt" || fail 'primary is not UP before rollback'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is DOWN' \
	"${state_dir}/rollback-pre-controller.txt" || \
	fail 'backup must be stopped before primary config rollback'

ctld_pid=$(systemctl show -p MainPID --value slurmctld)
dbd_pid=$(systemctl show -p MainPID --value slurmdbd)
slurmd_pid=$(systemctl show -p MainPID --value slurmd)
restart_counts_before=$(printf '%s,%s,%s' \
	"$(systemctl show -p NRestarts --value slurmctld)" \
	"$(systemctl show -p NRestarts --value slurmdbd)" \
	"$(systemctl show -p NRestarts --value slurmd)")
active_stamps_before=$(printf '%s,%s,%s' \
	"$(systemctl show -p ActiveEnterTimestampMonotonic --value slurmctld)" \
	"$(systemctl show -p ActiveEnterTimestampMonotonic --value slurmdbd)" \
	"$(systemctl show -p ActiveEnterTimestampMonotonic --value slurmd)")
tmp=${config}.smd405-rollback.$$
trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
install -o slurm -g slurm -m 0755 "${state_dir}/slurm.conf.before" "$tmp" || \
	fail 'rollback staging failed'
mv -f -- "$tmp" "$config"
trap - EXIT HUP INT TERM
[ "$(sha256sum "$config" | awk '{print $1}')" = "$expected_before" ] || \
	fail 'restored config hash mismatch'
scontrol reconfigure >"${state_dir}/rollback-reconfigure.txt" 2>&1 || \
	fail 'rollback reconfigure failed'
sleep 2
scontrol ping >"${state_dir}/rollback-controller.txt" 2>&1 || \
	fail 'primary controller did not return'
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
	"${state_dir}/rollback-controller.txt" || fail 'restored primary identity mismatch'
scontrol show config >"${state_dir}/rollback-config.txt" 2>&1 || \
	fail 'restored effective config readback failed'
[ "$(grep -c '^SlurmctldHost\[' "${state_dir}/rollback-config.txt")" -eq 1 ] || \
	fail 'restored effective controller count mismatch'
[ "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)" = \
	active,active,active ] || fail 'production service changed state during rollback'
restart_counts_after=$(printf '%s,%s,%s' \
	"$(systemctl show -p NRestarts --value slurmctld)" \
	"$(systemctl show -p NRestarts --value slurmdbd)" \
	"$(systemctl show -p NRestarts --value slurmd)")
active_stamps_after=$(printf '%s,%s,%s' \
	"$(systemctl show -p ActiveEnterTimestampMonotonic --value slurmctld)" \
	"$(systemctl show -p ActiveEnterTimestampMonotonic --value slurmdbd)" \
	"$(systemctl show -p ActiveEnterTimestampMonotonic --value slurmd)")
[ "$restart_counts_after" = "$restart_counts_before" ] || \
	fail 'systemd restart count changed during rollback'
[ "$active_stamps_after" = "$active_stamps_before" ] || \
	fail 'systemd active timestamp changed during rollback'
ctld_pid_after=$(systemctl show -p MainPID --value slurmctld)
dbd_pid_after=$(systemctl show -p MainPID --value slurmdbd)
slurmd_pid_after=$(systemctl show -p MainPID --value slurmd)
[ -z "$(squeue -h)" ] || fail 'queue changed during rollback'

archive=/var/tmp/slurm-smd405-controller-sync-rolled-back-$(date '+%Y%m%dT%H%M%S')
mv "$state_dir" "$archive"
chmod -R a+rX "$archive"
printf 'SMD405_PRIMARY_CONFIG_ROLLBACK_PASS config=%s pids_before=%s,%s,%s pids_after=%s,%s,%s systemd_restarts=%s archive=%s\n' \
	"$expected_before" "$ctld_pid" "$dbd_pid" "$slurmd_pid" \
	"$ctld_pid_after" "$dbd_pid_after" "$slurmd_pid_after" \
	"$restart_counts_after" "$archive"
