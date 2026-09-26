#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_BACKUP_STANDBY_START_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_BACKUP_STANDBY_START_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib/smd405-runtime/lib:/usr/local/slurm/26.11.0/lib
export PATH LD_LIBRARY_PATH

prefix=/usr/local/slurm/26.11.0
config=${prefix}/etc/slurm.conf
key=${prefix}/etc/slurm.key
binary=${prefix}/sbin/slurmctld
service=/etc/systemd/system/slurmctld.service
shared_state=/var/spool/slurm/slurmctld
state_dir=/var/tmp/slurm-smd405-backup-standby-active
expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_key=70a580ae6b21d7ddc32f41e3959b024ea180e70e5a2244fb22774dcb45c55e7b
expected_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
expected_service=46e930ee24695791d809498254092516c5efde38d136fe781172766db71bf9d2
started=0
success=0
preexisting_failure_archive=NONE

fail()
{
	printf 'SMD405_BACKUP_STANDBY_START_FAILED error=%s state_dir=%s\n' \
		"$1" "$state_dir" >&2
	exit 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$started" -eq 1 ]; then
		systemctl stop slurmctld >/dev/null 2>&1 || true
		attempt=0
		while [ "$attempt" -lt 10 ] && pgrep -x slurmctld >/dev/null 2>&1; do
			attempt=$((attempt + 1))
			sleep 1
		done
		printf '%s\n' 'recovery: backup slurmctld stopped' >&2
	fi
	if [ "$success" -ne 1 ] && [ -d "$state_dir" ]; then
		failed_archive=/var/tmp/slurm-smd405-backup-standby-failed-$(date '+%Y%m%dT%H%M%S')
		mv "$state_dir" "$failed_archive" >/dev/null 2>&1 || true
		[ -d "$failed_archive" ] && chmod -R a+rX "$failed_archive" >/dev/null 2>&1 || true
		printf 'failure_evidence=%s\n' "$failed_archive" >&2
	fi
	exit "$rc"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(hostname -s)" = slurmctld-bak ] || fail 'unexpected backup hostname'
[ "$(sha256sum "$config" | awk '{print $1}')" = "$expected_config" ] || \
	fail 'backup config hash mismatch'
[ "$(sha256sum "$key" | awk '{print $1}')" = "$expected_key" ] || \
	fail 'auth key hash mismatch'
[ "$(sha256sum "$binary" | awk '{print $1}')" = "$expected_binary" ] || \
	fail 'controller binary hash mismatch'
[ "$(sha256sum "$service" | awk '{print $1}')" = "$expected_service" ] || \
	fail 'service unit hash mismatch'
[ "$(stat -c '%U:%G:%a:%s' "$key")" = slurm:slurm:600:1024 ] || \
	fail 'auth key metadata mismatch'
[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = inactive ] || \
	fail 'backup service is already active'
[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || \
	fail 'backup service is not disabled'
pgrep -x slurmctld >/dev/null 2>&1 && fail 'unexpected slurmctld process exists'
if [ -e "$state_dir" ]; then
	preexisting_failure_archive=/var/tmp/slurm-smd405-backup-standby-failed-preflight-$(date '+%Y%m%dT%H%M%S')
	mv "$state_dir" "$preexisting_failure_archive" || \
		fail 'cannot archive prior failed standby evidence'
	chmod -R a+rX "$preexisting_failure_archive" || \
		fail 'cannot make prior failure evidence readable'
fi
[ "$(findmnt -T "$shared_state" -no FSTYPE)" = nfs4 ] || fail 'shared state is not NFSv4'
findmnt -T "$shared_state" -no SOURCE | \
	grep -Fx '192.168.10.180:/var/spool/slurm/slurmctld' >/dev/null || \
	fail 'shared state source mismatch'
findmnt -T "$shared_state" -no OPTIONS | tr ',' '\n' | grep -Fx rw >/dev/null || \
	fail 'shared state is not mounted read/write'
[ "$(stat -c '%u:%g:%a' "$shared_state")" = 1002:1002:755 ] || \
	fail 'shared state metadata mismatch'
su -s /bin/sh slurm -c "test -r '$shared_state' -a -w '$shared_state' -a -x '$shared_state'" || \
	fail 'slurm lacks shared state permissions'
timeout 3 bash -c 'exec 3<>/dev/tcp/192.168.10.180/6817' || \
	fail 'primary controller port is unreachable'
timeout 3 bash -c 'exec 3<>/dev/tcp/192.168.10.180/6819' || \
	fail 'slurmdbd port is unreachable'

install -d -o root -g root -m 0700 "$state_dir"
trap cleanup EXIT HUP INT TERM
start_epoch=$(date '+%s')
printf '%s\n' \
	'primary_controller_tcp_6817=REACHABLE' \
	'slurmdbd_tcp_6819=REACHABLE' \
	'authenticated_prestart_ping=NOT_APPLICABLE_NO_LOCAL_SACK_DAEMON' \
	>"${state_dir}/before-connectivity.txt"

systemctl start slurmctld || fail 'backup service start failed'
started=1
ready=0
attempt=0
while [ "$attempt" -lt 30 ]; do
	attempt=$((attempt + 1))
	if systemctl is-active --quiet slurmctld; then
		ready=1
		break
	fi
	sleep 1
done
[ "$ready" -eq 1 ] || fail 'backup service did not become active'
backup_pid=$(systemctl show -p MainPID --value slurmctld)
case "$backup_pid" in ''|0|*[!0-9]*) fail 'backup MainPID is invalid' ;; esac
kill -0 "$backup_pid" >/dev/null 2>&1 || fail 'backup process is not alive'
[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || \
	fail 'backup service unexpectedly became enabled'

both_up=0
attempt=0
while [ "$attempt" -lt 30 ]; do
	attempt=$((attempt + 1))
	scontrol ping >"${state_dir}/after-controller.txt" 2>&1 || true
	if grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
		"${state_dir}/after-controller.txt" && \
		grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' \
		"${state_dir}/after-controller.txt"; then
		both_up=1
		break
	fi
	sleep 1
done
[ "$both_up" -eq 1 ] || fail 'primary and backup did not both report UP'
journalctl -u slurmctld --since "@${start_epoch}" --no-pager -o cat \
	>"${state_dir}/journal.txt" 2>&1 || fail 'journal readback failed'
grep -Fq 'slurmctld running in background mode' "${state_dir}/journal.txt" || \
	fail 'standby background-mode marker is absent'
if grep -Fq 'Running as primary controller' "${state_dir}/journal.txt"; then
	fail 'backup entered primary-controller mode'
fi
if grep -Ei '(^|[[:space:]])fatal:' "${state_dir}/journal.txt" \
	>"${state_dir}/unexpected-fatal.txt"; then
	fail 'backup emitted a fatal error'
fi
systemctl status slurmctld --no-pager >"${state_dir}/service-status.txt" 2>&1 || \
	fail 'backup service status readback failed'
squeue -h >"${state_dir}/after-queue.txt" 2>&1 || fail 'queue post-start probe failed'
[ ! -s "${state_dir}/after-queue.txt" ] || fail 'queue changed during backup start'
{
	printf 'phase=BACKUP_ACTIVE_STANDBY_NO_TAKEOVER\n'
	printf 'start_epoch=%s\n' "$start_epoch"
	printf 'backup_pid=%s\n' "$backup_pid"
	printf 'config_sha256=%s\n' "$expected_config"
	printf 'primary=ubuntu2504@192.168.10.180\n'
	printf 'backup=slurmctld-bak@192.168.10.118\n'
	printf 'preexisting_failure_archive=%s\n' "$preexisting_failure_archive"
} >"${state_dir}/state.env"
chmod 0600 "${state_dir}/state.env"

success=1
trap - EXIT HUP INT TERM
chmod -R a+rX "$state_dir"
printf 'SMD405_BACKUP_STANDBY_START_PASS pid=%s primary=UP backup=UP mode=BACKGROUND service_enabled=disabled queue=EMPTY state_dir=%s\n' \
	"$backup_pid" "$state_dir"
