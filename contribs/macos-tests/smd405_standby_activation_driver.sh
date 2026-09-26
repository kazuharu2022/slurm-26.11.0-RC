#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_STANDBY_ACTIVATION_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_STANDBY_ACTIVATION_CONFIRMED=YES after approval' >&2
	exit 64
fi

identity=/Users/REDACTED_USER/.ssh/id_ed25519
primary=REDACTED_USER@192.168.10.180
backup=REDACTED_USER@192.168.10.118
backup_known_hosts=/private/tmp/smd405-controller-sync-known-hosts
mac_prefix=/opt/slurm/26.11.0
run_dir=/private/tmp/slurm-smd405-standby-activation-$(date '+%Y%m%dT%H%M%S')
expected_primary_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_mac_config=33f1bb4ef72ee0fe750df473c2b8afb103b40e95443740418408ed488325ffdb
backup_started=0
success=0

fail()
{
	printf 'SMD405_STANDBY_ACTIVATION_FAILED error=%s run_dir=%s\n' "$1" "$run_dir" >&2
	exit 1
}

primary_health()
{
	label=$1
	ssh -i "$identity" -o BatchMode=yes -o ConnectTimeout=10 "$primary" \
		'/bin/sh -s' >"${run_dir}/${label}-primary-health.txt" 2>&1 <<'REMOTE'
set -eu
PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib
export PATH LD_LIBRARY_PATH
[ "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)" = active,active,active ]
[ "$(sha256sum /usr/local/slurm/26.11.0/etc/slurm.conf | awk '{print $1}')" = 80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b ]
scontrol ping
scontrol ping | grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP'
[ -z "$(squeue -h)" ]
for node in ubuntu PC-210; do
	out=$(scontrol show node "$node")
	printf '%s\n' "$out"
	printf '%s\n' "$out" | grep -Eq '(^|[[:space:]])State=IDLE([[:space:]]|$)'
	printf '%s\n' "$out" | grep -Eq '(^|[[:space:]])CPUAlloc=0([[:space:]]|$)'
done
printf 'pids=%s,%s,%s\n' \
	"$(systemctl show -p MainPID --value slurmctld)" \
	"$(systemctl show -p MainPID --value slurmdbd)" \
	"$(systemctl show -p MainPID --value slurmd)"
REMOTE
}

backup_service_state()
{
	label=$1
	ssh -i "$identity" -o BatchMode=yes -o ConnectTimeout=10 \
		-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$backup_known_hosts" \
		"$backup" \
		'systemctl is-active slurmctld 2>/dev/null || true; systemctl is-enabled slurmctld 2>/dev/null || true' \
		>"${run_dir}/${label}-backup-service.txt" 2>&1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$backup_started" -eq 1 ]; then
		ssh -i "$identity" -o BatchMode=yes -o ConnectTimeout=10 \
			-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$backup_known_hosts" \
			"$backup" 'sudo -n systemctl stop slurmctld' \
			>"${run_dir}/emergency-backup-stop.txt" 2>&1 || true
		printf '%s\n' 'recovery: requested immediate backup service stop' >&2
	fi
	[ -d "$run_dir" ] && chmod -R a+rX "$run_dir" >/dev/null 2>&1 || true
	exit "$rc"
}

[ "$(uname -s)" = Darwin ] || fail 'driver must run on the Mac host'
[ "$(hostname -s)" = PC-210 ] || fail 'unexpected Mac hostname'
[ -f "$identity" ] || fail 'SSH identity is absent'
[ -f "$backup_known_hosts" ] || fail 'dedicated backup known_hosts is absent'
[ "$(shasum -a 256 "${mac_prefix}/etc/slurm.conf" | awk '{print $1}')" = \
	"$expected_mac_config" ] || fail 'Mac config hash mismatch'
mkdir -m 0755 "$run_dir"
trap cleanup EXIT HUP INT TERM

primary_health before || fail 'authenticated primary preflight failed'
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
	"${run_dir}/before-primary-health.txt" || fail 'primary is not UP immediately before start'
[ "$(grep -c '^SlurmctldHost\[' "${run_dir}/before-primary-health.txt" 2>/dev/null || true)" -eq 0 ] || \
	fail 'unexpected primary health output'
backup_service_state before || fail 'backup preflight read failed'
[ "$(sed -n '1p' "${run_dir}/before-backup-service.txt")" = inactive ] || \
	fail 'backup is not inactive before start'
[ "$(sed -n '2p' "${run_dir}/before-backup-service.txt")" = disabled ] || \
	fail 'backup is not disabled before start'

backup_started=1
ssh -i "$identity" -o BatchMode=yes -o ConnectTimeout=10 \
	-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$backup_known_hosts" \
	"$backup" \
	'sudo -n env SMD405_BACKUP_STANDBY_START_CONFIRMED=YES /bin/sh /tmp/smd405_backup_standby_start.sh' \
	>"${run_dir}/backup-start.txt" 2>&1 || fail 'backup standby start script failed'

primary_health after || fail 'authenticated primary post-start health failed'
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
	"${run_dir}/after-primary-health.txt" || fail 'primary is not UP after backup start'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' \
	"${run_dir}/after-primary-health.txt" || fail 'backup is not UP from primary view'
backup_service_state after || fail 'backup post-start service read failed'
[ "$(sed -n '1p' "${run_dir}/after-backup-service.txt")" = active ] || \
	fail 'backup is not active after start'
[ "$(sed -n '2p' "${run_dir}/after-backup-service.txt")" = disabled ] || \
	fail 'backup unexpectedly became enabled'

"${mac_prefix}/bin/scontrol" ping >"${run_dir}/mac-controller.txt" 2>&1 || \
	fail 'Mac authenticated controller ping failed'
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
	"${run_dir}/mac-controller.txt" || fail 'primary is not UP from Mac view'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' \
	"${run_dir}/mac-controller.txt" || fail 'backup is not UP from Mac view'
"${mac_prefix}/bin/squeue" -h >"${run_dir}/mac-queue.txt" 2>&1 || \
	fail 'Mac queue readback failed'
[ ! -s "${run_dir}/mac-queue.txt" ] || fail 'queue is not empty after backup start'

success=1
trap - EXIT HUP INT TERM
chmod -R a+rX "$run_dir"
printf 'SMD405_STANDBY_ACTIVATION_PASS primary=UP backup=UP backup_mode=BACKGROUND backup_enabled=disabled nodes=IDLE queue=EMPTY primary_config=%s mac_config=%s run_dir=%s\n' \
	"$expected_primary_config" "$expected_mac_config" "$run_dir"
