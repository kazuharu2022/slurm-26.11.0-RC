#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_PRIMARY_RECONFIGURE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_PRIMARY_RECONFIGURE_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib
export PATH LD_LIBRARY_PATH

config=/usr/local/slurm/26.11.0/etc/slurm.conf
state_dir=/var/tmp/slurm-smd405-controller-sync-active
expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b

fail()
{
	printf 'SMD405_PRIMARY_RECONFIGURE_FAILED error=%s state_dir=%s\n' "$1" "$state_dir" >&2
	exit 1
}

node_is_idle()
{
	node=$1
	label=$2
	out=${state_dir}/${label}-node-${node}.txt
	scontrol show node "$node" >"$out" 2>&1 || return 1
	grep -Eq '(^|[[:space:]])State=IDLE([[:space:]]|$)' "$out" || return 1
	grep -Eq '(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' "$out"
}

restart_counts()
{
	printf '%s,%s,%s\n' \
		"$(systemctl show -p NRestarts --value slurmctld)" \
		"$(systemctl show -p NRestarts --value slurmdbd)" \
		"$(systemctl show -p NRestarts --value slurmd)"
}

active_stamps()
{
	printf '%s,%s,%s\n' \
		"$(systemctl show -p ActiveEnterTimestampMonotonic --value slurmctld)" \
		"$(systemctl show -p ActiveEnterTimestampMonotonic --value slurmdbd)" \
		"$(systemctl show -p ActiveEnterTimestampMonotonic --value slurmd)"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(hostname -s)" = ubuntu2504 ] || fail 'unexpected primary hostname'
[ -d "$state_dir" ] || fail 'active state directory is absent'
[ "$(sha256sum "$config" | awk '{print $1}')" = "$expected_config" ] || \
	fail 'installed config hash mismatch'
[ "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)" = \
	active,active,active ] || fail 'production service is not fully active'

scontrol ping >"${state_dir}/pre-reconfigure-controller.txt" 2>&1 || \
	fail 'primary controller preflight failed'
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
	"${state_dir}/pre-reconfigure-controller.txt" || fail 'primary identity mismatch'
squeue -h >"${state_dir}/pre-reconfigure-queue.txt" 2>&1 || fail 'queue probe failed'
[ ! -s "${state_dir}/pre-reconfigure-queue.txt" ] || fail 'queue is not empty'
node_is_idle ubuntu pre-reconfigure || fail 'ubuntu node is not idle'
node_is_idle PC-210 pre-reconfigure || fail 'PC-210 node is not idle'

ctld_pid=$(systemctl show -p MainPID --value slurmctld)
dbd_pid=$(systemctl show -p MainPID --value slurmdbd)
slurmd_pid=$(systemctl show -p MainPID --value slurmd)
restart_counts_before=$(restart_counts)
active_stamps_before=$(active_stamps)
scontrol show config >"${state_dir}/pre-reconfigure-config.txt" 2>&1 || \
	fail 'effective config pre-read failed'
if grep -Eq '^SlurmctldHost\[0\][[:space:]]*=[[:space:]]*ubuntu2504\(192\.168\.10\.180\)$' \
	"${state_dir}/pre-reconfigure-config.txt" && \
	grep -Eq '^SlurmctldHost\[1\][[:space:]]*=[[:space:]]*slurmctld-bak\(192\.168\.10\.118\)$' \
	"${state_dir}/pre-reconfigure-config.txt"; then
	reconfigure_action=ALREADY_EFFECTIVE_NO_REPEAT
	printf '%s\n' "$reconfigure_action" >"${state_dir}/reconfigure.txt"
else
	reconfigure_action=EXECUTED
	scontrol reconfigure >"${state_dir}/reconfigure.txt" 2>&1 || \
		fail 'scontrol reconfigure failed'
fi

ready=0
attempt=0
while [ "$attempt" -lt 20 ]; do
	attempt=$((attempt + 1))
	if scontrol ping >"${state_dir}/post-reconfigure-controller.txt" 2>&1 && \
		grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
		"${state_dir}/post-reconfigure-controller.txt"; then
		ready=1
		break
	fi
	sleep 1
done
[ "$ready" -eq 1 ] || fail 'primary did not return UP after reconfigure'
scontrol show config >"${state_dir}/post-reconfigure-config.txt" 2>&1 || \
	fail 'effective config readback failed'
grep -Eq '^SlurmctldHost\[0\][[:space:]]*=[[:space:]]*ubuntu2504\(192\.168\.10\.180\)$' \
	"${state_dir}/post-reconfigure-config.txt" || fail 'effective primary entry mismatch'
grep -Eq '^SlurmctldHost\[1\][[:space:]]*=[[:space:]]*slurmctld-bak\(192\.168\.10\.118\)$' \
	"${state_dir}/post-reconfigure-config.txt" || fail 'effective backup entry mismatch'
[ "$(grep -c '^SlurmctldHost\[' "${state_dir}/post-reconfigure-config.txt")" -eq 2 ] || \
	fail 'effective controller count mismatch'
[ "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)" = \
	active,active,active ] || fail 'production service changed state'
restart_counts_after=$(restart_counts)
active_stamps_after=$(active_stamps)
[ "$restart_counts_after" = "$restart_counts_before" ] || \
	fail 'systemd restart count changed'
[ "$active_stamps_after" = "$active_stamps_before" ] || \
	fail 'systemd active timestamp changed'
ctld_pid_after=$(systemctl show -p MainPID --value slurmctld)
dbd_pid_after=$(systemctl show -p MainPID --value slurmdbd)
slurmd_pid_after=$(systemctl show -p MainPID --value slurmd)
squeue -h >"${state_dir}/post-reconfigure-queue.txt" 2>&1 || fail 'queue probe failed'
[ ! -s "${state_dir}/post-reconfigure-queue.txt" ] || fail 'queue changed'
node_is_idle ubuntu post-reconfigure || fail 'ubuntu node changed state'
node_is_idle PC-210 post-reconfigure || fail 'PC-210 node changed state'

sed -i 's/^phase=.*/phase=PRIMARY_RECONFIGURED_BACKUP_NOT_STARTED/' \
	"${state_dir}/state.env"
{
	printf 'reconfigure_action=%s\n' "$reconfigure_action"
	printf 'reconfigure_pids_before=%s,%s,%s\n' "$ctld_pid" "$dbd_pid" "$slurmd_pid"
	printf 'reconfigure_pids_after=%s,%s,%s\n' "$ctld_pid_after" "$dbd_pid_after" "$slurmd_pid_after"
	printf 'systemd_restart_counts=%s\n' "$restart_counts_after"
} >>"${state_dir}/state.env"
printf 'SMD405_PRIMARY_RECONFIGURE_PASS config=%s action=%s pids_before=%s,%s,%s pids_after=%s,%s,%s systemd_restarts=%s controllers=2 nodes=IDLE queue=EMPTY state_dir=%s\n' \
	"$expected_config" "$reconfigure_action" "$ctld_pid" "$dbd_pid" "$slurmd_pid" \
	"$ctld_pid_after" "$dbd_pid_after" "$slurmd_pid_after" \
	"$restart_counts_after" "$state_dir"
