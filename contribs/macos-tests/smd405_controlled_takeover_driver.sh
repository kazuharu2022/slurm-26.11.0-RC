#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_CONTROLLED_TAKEOVER_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_CONTROLLED_TAKEOVER_CONFIRMED=YES after approval' >&2
	exit 64
fi

identity=/Users/REDACTED_USER/.ssh/id_ed25519
primary=REDACTED_USER@192.168.10.180
backup=REDACTED_USER@192.168.10.118
backup_known_hosts=/private/tmp/smd405-controller-sync-known-hosts
mac_prefix=/opt/slurm/26.11.0
run_dir=/private/tmp/slurm-smd405-controlled-takeover-$(date '+%Y%m%dT%H%M%S')
expected_linux_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_mac_config=33f1bb4ef72ee0fe750df473c2b8afb103b40e95443740418408ed488325ffdb
expected_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
expected_key=70a580ae6b21d7ddc32f41e3959b024ea180e70e5a2244fb22774dcb45c55e7b
expected_service=46e930ee24695791d809498254092516c5efde38d136fe781172766db71bf9d2
takeover_attempted=0
success=0

fail()
{
	printf 'SMD405_CONTROLLED_TAKEOVER_FAILED error=%s run_dir=%s\n' \
		"$1" "$run_dir" >&2
	exit 1
}

primary_preflight()
{
	ssh -i "$identity" -o BatchMode=yes -o ConnectTimeout=10 \
		-o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$primary" \
		'/bin/sh -s' >"${run_dir}/primary-preflight.txt" 2>&1 <<'REMOTE'
set -eu
PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib
export PATH LD_LIBRARY_PATH
[ "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)" = active,active,active ]
[ "$(systemctl show -p Restart --value slurmctld)" = no ]
[ "$(sha256sum /usr/local/slurm/26.11.0/etc/slurm.conf | awk '{print $1}')" = 80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b ]
[ "$(sha256sum /usr/local/slurm/26.11.0/sbin/slurmctld | awk '{print $1}')" = 834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70 ]
scontrol ping > /tmp/smd405-takeover-primary-ping.$$
trap 'rm -f /tmp/smd405-takeover-primary-ping.$$' EXIT HUP INT TERM
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' /tmp/smd405-takeover-primary-ping.$$
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' /tmp/smd405-takeover-primary-ping.$$
cat /tmp/smd405-takeover-primary-ping.$$
[ -z "$(squeue -h)" ]
for node in ubuntu PC-210; do
	out=$(scontrol show node "$node")
	printf '%s\n' "$out" | grep -Eq '(^|[[:space:]])State=IDLE([[:space:]]|$)'
	printf '%s\n' "$out" | grep -Eq '(^|[[:space:]])CPUAlloc=0([[:space:]]|$)'
done
printf 'epoch=%s\n' "$(date '+%s')"
printf 'heartbeat_mtime=%s\n' "$(stat -c '%Y' /var/spool/slurm/slurmctld/heartbeat)"
printf 'pids=%s,%s,%s\n' \
	"$(systemctl show -p MainPID --value slurmctld)" \
	"$(systemctl show -p MainPID --value slurmdbd)" \
	"$(systemctl show -p MainPID --value slurmd)"
printf '%s\n' 'queue=EMPTY nodes=IDLE cpualloc=0'
REMOTE
}

backup_preflight()
{
	ssh -i "$identity" -o BatchMode=yes -o ConnectTimeout=10 \
		-o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
		-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$backup_known_hosts" \
		"$backup" 'sudo -n env LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib/smd405-runtime/lib:/usr/local/slurm/26.11.0/lib /bin/sh -s' \
		>"${run_dir}/backup-preflight.txt" 2>&1 <<'REMOTE'
set -eu
PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$(systemctl is-active slurmctld)" = active ]
[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ]
[ "$(systemctl show -p Restart --value slurmctld)" = no ]
[ "$(sha256sum /usr/local/slurm/26.11.0/etc/slurm.conf | awk '{print $1}')" = 80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b ]
[ "$(sha256sum /usr/local/slurm/26.11.0/sbin/slurmctld | awk '{print $1}')" = 834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70 ]
[ "$(sha256sum /usr/local/slurm/26.11.0/etc/slurm.key | awk '{print $1}')" = 70a580ae6b21d7ddc32f41e3959b024ea180e70e5a2244fb22774dcb45c55e7b ]
[ "$(sha256sum /etc/systemd/system/slurmctld.service | awk '{print $1}')" = 46e930ee24695791d809498254092516c5efde38d136fe781172766db71bf9d2 ]
[ "$(findmnt -T /var/spool/slurm/slurmctld -no FSTYPE)" = nfs4 ]
findmnt -T /var/spool/slurm/slurmctld -no SOURCE | grep -Fx '192.168.10.180:/var/spool/slurm/slurmctld' >/dev/null
invocation=$(systemctl show -p InvocationID --value slurmctld)
journalctl "_SYSTEMD_INVOCATION_ID=$invocation" --no-pager -o cat > /tmp/smd405-takeover-backup-journal.$$
trap 'rm -f /tmp/smd405-takeover-backup-journal.$$' EXIT HUP INT TERM
grep -Fq 'slurmctld running in background mode' /tmp/smd405-takeover-backup-journal.$$
if grep -Fq 'Running as primary controller' /tmp/smd405-takeover-backup-journal.$$; then
	exit 42
fi
scontrol ping
[ -z "$(squeue -h)" ]
printf 'epoch=%s\n' "$(date '+%s')"
printf 'heartbeat_mtime=%s\n' "$(stat -c '%Y' /var/spool/slurm/slurmctld/heartbeat)"
printf 'backup_pid=%s\n' "$(systemctl show -p MainPID --value slurmctld)"
printf '%s\n' 'mode=BACKGROUND queue=EMPTY service=active,disabled'
REMOTE
}

mac_health()
{
	label=$1
	"${mac_prefix}/bin/scontrol" ping >"${run_dir}/${label}-mac-ping.txt" 2>&1 || return 1
	"${mac_prefix}/bin/squeue" -h >"${run_dir}/${label}-mac-queue.txt" 2>&1 || return 1
	[ ! -s "${run_dir}/${label}-mac-queue.txt" ] || return 1
	for node in ubuntu PC-210; do
		"${mac_prefix}/bin/scontrol" show node "$node" \
			>"${run_dir}/${label}-mac-node-${node}.txt" 2>&1 || return 1
		grep -Eq '(^|[[:space:]])State=IDLE([[:space:]]|$)' \
			"${run_dir}/${label}-mac-node-${node}.txt" || return 1
		grep -Eq '(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' \
			"${run_dir}/${label}-mac-node-${node}.txt" || return 1
	done
}

recover_primary()
{
	printf '%s\n' 'recovery: starting primary slurmctld' >&2
	ssh -i "$identity" -o BatchMode=yes -o ConnectTimeout=10 "$primary" \
		'sudo -n systemctl start slurmctld' \
		>"${run_dir}/recovery-primary-start.txt" 2>&1 || return 1
	attempt=0
	while [ "$attempt" -lt 30 ]; do
		attempt=$((attempt + 1))
		if "${mac_prefix}/bin/scontrol" ping \
			>"${run_dir}/recovery-mac-ping.txt" 2>&1 && \
			grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
			"${run_dir}/recovery-mac-ping.txt" && \
			grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' \
			"${run_dir}/recovery-mac-ping.txt"; then
			return 0
		fi
		sleep 1
	done
	return 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$takeover_attempted" -eq 1 ]; then
		if recover_primary; then
			printf '%s\n' 'recovery: primary controller restored' >&2
		else
			printf '%s\n' 'fatal recovery: primary controller restore failed' >&2
		fi
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

primary_preflight || fail 'primary preflight failed'
backup_preflight || fail 'backup preflight failed'
mac_health before || fail 'Mac preflight failed'
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' "${run_dir}/before-mac-ping.txt" || \
	fail 'primary is not UP before takeover'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' "${run_dir}/before-mac-ping.txt" || \
	fail 'backup is not UP before takeover'
primary_epoch=$(awk -F= '$1 == "epoch" { print $2; exit }' "${run_dir}/primary-preflight.txt")
backup_epoch=$(awk -F= '$1 == "epoch" { print $2; exit }' "${run_dir}/backup-preflight.txt")
primary_heartbeat=$(awk -F= '$1 == "heartbeat_mtime" { print $2; exit }' "${run_dir}/primary-preflight.txt")
backup_heartbeat=$(awk -F= '$1 == "heartbeat_mtime" { print $2; exit }' "${run_dir}/backup-preflight.txt")
clock_delta=$((primary_epoch - backup_epoch))
[ "$clock_delta" -ge 0 ] || clock_delta=$((-clock_delta))
[ "$clock_delta" -le 5 ] || fail 'primary and backup clocks differ by more than five seconds'
[ "$primary_heartbeat" = "$backup_heartbeat" ] || fail 'shared heartbeat mtime differs'
[ $((primary_epoch - primary_heartbeat)) -ge 0 ] || fail 'heartbeat is in the future'
[ $((primary_epoch - primary_heartbeat)) -le 35 ] || fail 'heartbeat is stale'

takeover_epoch=$(date '+%s')
takeover_attempted=1
set +e
ssh -i "$identity" -o BatchMode=yes -o ConnectTimeout=10 \
	-o ServerAliveInterval=5 -o ServerAliveCountMax=6 "$primary" \
	'sudo -n /usr/bin/timeout 30 /usr/bin/env LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib /usr/local/slurm/26.11.0/bin/scontrol takeover 1' \
	>"${run_dir}/takeover-command.txt" 2>&1
takeover_rc=$?
set -e
printf '%s\n' "$takeover_rc" >"${run_dir}/takeover-command.rc"

primary_stopped=0
primary_service_state=unknown
attempt=0
while [ "$attempt" -lt 30 ]; do
	attempt=$((attempt + 1))
	state=$(ssh -i "$identity" -o BatchMode=yes -o ConnectTimeout=10 "$primary" \
		'systemctl is-active slurmctld 2>/dev/null || true')
	case "$state" in
	inactive|failed)
		primary_service_state=$state
		primary_stopped=1
		break
		;;
	esac
	sleep 1
done
[ "$primary_stopped" -eq 1 ] || fail 'primary slurmctld did not reach a stopped state'
printf '%s\n' "$primary_service_state" >"${run_dir}/primary-service-state.txt"

backup_has_control=0
attempt=0
while [ "$attempt" -lt 30 ]; do
	attempt=$((attempt + 1))
	"${mac_prefix}/bin/scontrol" ping >"${run_dir}/after-mac-ping.txt" 2>&1 || true
	if grep -Fq 'Slurmctld(primary) at ubuntu2504 is DOWN' \
		"${run_dir}/after-mac-ping.txt" && \
		grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' \
		"${run_dir}/after-mac-ping.txt"; then
		backup_has_control=1
		break
	fi
	sleep 1
done
[ "$backup_has_control" -eq 1 ] || fail 'backup did not become active controller'
mac_health after || fail 'Mac post-takeover health failed'

ssh -i "$identity" -o BatchMode=yes -o ConnectTimeout=10 "$primary" \
	'/bin/sh -s' >"${run_dir}/primary-after.txt" 2>&1 <<'REMOTE'
set -eu
state=$(systemctl is-active slurmctld 2>/dev/null || true)
case "$state" in inactive|failed) ;; *) exit 41 ;; esac
[ "$(systemctl is-active slurmdbd slurmd | paste -sd, -)" = active,active ]
[ "$(systemctl show -p Restart --value slurmctld)" = no ]
[ "$(systemctl show -p MainPID --value slurmctld)" = 0 ]
pgrep -x slurmctld >/dev/null 2>&1 && exit 42
systemctl show slurmctld -p ActiveState -p SubState -p Result -p ExecMainCode -p ExecMainStatus
printf 'primary_service=%s primary_process=ABSENT dbd_slurmd=active\n' "$state"
REMOTE

ssh -i "$identity" -o BatchMode=yes -o ConnectTimeout=10 \
	-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$backup_known_hosts" \
	"$backup" 'sudo -n env LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib/smd405-runtime/lib:/usr/local/slurm/26.11.0/lib TAKEOVER_EPOCH='"$takeover_epoch"' /bin/sh -s' \
	>"${run_dir}/backup-after.txt" 2>&1 <<'REMOTE'
set -eu
PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ "$(systemctl is-active slurmctld)" = active ]
[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ]
journalctl -u slurmctld --since "@${TAKEOVER_EPOCH}" --no-pager -o cat > /tmp/smd405-takeover-journal.$$
trap 'rm -f /tmp/smd405-takeover-journal.$$' EXIT HUP INT TERM
grep -Fq 'Performing background RPC: REQUEST_TAKEOVER' /tmp/smd405-takeover-journal.$$
grep -Fq 'Running as primary controller' /tmp/smd405-takeover-journal.$$
scontrol ping
[ -z "$(squeue -h)" ]
printf 'backup_pid=%s\n' "$(systemctl show -p MainPID --value slurmctld)"
printf 'heartbeat_mtime=%s\n' "$(stat -c '%Y' /var/spool/slurm/slurmctld/heartbeat)"
printf '%s\n' 'backup_role=PRIMARY_CONTROLLER service=active,disabled queue=EMPTY'
REMOTE

[ "$primary_service_state" = inactive ] || \
	fail 'primary slurmctld terminated abnormally during takeover'

{
	printf 'phase=BACKUP_HAS_CONTROL_NO_JOB_SUBMITTED\n'
	printf 'takeover_epoch=%s\n' "$takeover_epoch"
	printf 'takeover_command_rc=%s\n' "$takeover_rc"
	printf 'primary=INACTIVE\n'
	printf 'backup=UP_PRIMARY_ROLE\n'
	printf 'queue=EMPTY\n'
	printf 'nodes=IDLE\n'
} >"${run_dir}/state.env"

success=1
trap - EXIT HUP INT TERM
chmod -R a+rX "$run_dir"
printf 'SMD405_CONTROLLED_TAKEOVER_PASS primary=INACTIVE backup=UP_PRIMARY_ROLE backup_service_enabled=disabled nodes=IDLE queue=EMPTY jobs=NONE run_dir=%s\n' \
	"$run_dir"
