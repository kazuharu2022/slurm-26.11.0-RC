#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu
umask 077

if [ "${SMD405_ISOLATED_TAKEOVER_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_ISOLATED_TAKEOVER_CONFIRMED=YES after approval' >&2
	exit 64
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
primary_helper=${script_dir}/smd405_isolated_takeover_primary_remote.sh
backup_helper=${script_dir}/smd405_isolated_takeover_backup_remote.sh
identity=/Users/REDACTED_USER/.ssh/id_ed25519
backup_known_hosts=/private/tmp/smd405-controller-sync-known-hosts
primary=REDACTED_USER@192.168.10.180
backup=REDACTED_USER@192.168.10.118
mac_prefix=/opt/slurm/26.11.0
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/private/tmp/smd405-isolated-takeover-${run_stamp}
primary_prepared=0
backup_prepared=0
cleanup_complete=0

fail()
{
	printf 'SMD405_ISOLATED_TAKEOVER_FAILED error=%s run_dir=%s\n' \
		"$1" "$run_dir" >&2
	exit 1
}

run_primary()
{
	remote_mode=$1
	/usr/bin/ssh -i "$identity" -o BatchMode=yes -o ConnectTimeout=10 \
		-o ServerAliveInterval=5 -o ServerAliveCountMax=6 \
		-o StrictHostKeyChecking=yes "$primary" \
		"sudo -n /usr/bin/env MODE=${remote_mode} RUN_STAMP=${run_stamp} /bin/sh -s" \
		<"$primary_helper"
}

run_backup()
{
	remote_mode=$1
	/usr/bin/ssh -i "$identity" -o BatchMode=yes -o ConnectTimeout=10 \
		-o ServerAliveInterval=5 -o ServerAliveCountMax=6 \
		-o StrictHostKeyChecking=yes \
		-o "UserKnownHostsFile=${backup_known_hosts}" "$backup" \
		"sudo -n /usr/bin/env MODE=${remote_mode} RUN_STAMP=${run_stamp} /bin/sh -s" \
		<"$backup_helper"
}

mac_health()
{
	label=$1
	"${mac_prefix}/bin/scontrol" ping >"${run_dir}/${label}-mac-ping.txt" 2>&1 || return 1
	grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
		"${run_dir}/${label}-mac-ping.txt" || return 1
	grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' \
		"${run_dir}/${label}-mac-ping.txt" || return 1
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

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$cleanup_complete" -ne 1 ]; then
		if [ "$backup_prepared" -eq 1 ]; then
			run_backup cleanup >"${run_dir}/backup-cleanup.txt" 2>&1 || \
				printf '%s\n' 'warning: isolated backup cleanup failed' >&2
		fi
		if [ "$primary_prepared" -eq 1 ]; then
			run_primary cleanup >"${run_dir}/primary-cleanup.txt" 2>&1 || \
				printf '%s\n' 'warning: isolated primary cleanup failed' >&2
		fi
	fi
	exit "$rc"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root on the Mac host'
[ "$(uname -s)" = Darwin ] || fail 'driver must run on macOS'
[ "$(hostname -s)" = PC-210 ] || fail 'unexpected Mac hostname'
[ -f "$identity" ] || fail 'SSH identity is absent'
[ -f "$backup_known_hosts" ] || fail 'dedicated backup known_hosts is absent'
[ -r "$primary_helper" ] || fail 'primary helper is absent'
[ -r "$backup_helper" ] || fail 'backup helper is absent'
[ -x "${mac_prefix}/bin/scontrol" ] || fail 'Mac scontrol is absent'
[ -x "${mac_prefix}/bin/squeue" ] || fail 'Mac squeue is absent'

mkdir -m 0700 "$run_dir"
trap cleanup EXIT HUP INT TERM
{
	date '+started_at=%Y-%m-%dT%H:%M:%S%z'
	shasum -a 256 "$0" "$primary_helper" "$backup_helper"
} >"${run_dir}/driver-metadata.txt"

mac_health before || fail 'Mac production preflight failed'
run_primary preflight >"${run_dir}/primary-preflight.txt" 2>&1 || \
	fail 'primary preflight failed'
run_backup preflight >"${run_dir}/backup-preflight.txt" 2>&1 || \
	fail 'backup preflight failed'

primary_pid_before=$(sed -n 's/.*production_pid=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/primary-preflight.txt" | tail -n 1)
backup_pid_before=$(sed -n 's/.*production_pid=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/backup-preflight.txt" | tail -n 1)
[ -n "$primary_pid_before" ] || fail 'primary production PID was not captured'
[ -n "$backup_pid_before" ] || fail 'backup production PID was not captured'

primary_prepared=1
run_primary prepare >"${run_dir}/primary-prepare.txt" 2>&1 || \
	fail 'primary prepare failed'
backup_prepared=1
run_backup prepare >"${run_dir}/backup-prepare.txt" 2>&1 || \
	fail 'backup prepare failed'

primary_config=$(sed -n 's/.*config_sha256=\([0-9a-f][0-9a-f]*\).*/\1/p' \
	"${run_dir}/primary-prepare.txt" | tail -n 1)
backup_config=$(sed -n 's/.*config_sha256=\([0-9a-f][0-9a-f]*\).*/\1/p' \
	"${run_dir}/backup-prepare.txt" | tail -n 1)
[ -n "$primary_config" ] || fail 'primary isolated config hash is absent'
[ "$primary_config" = "$backup_config" ] || fail 'isolated controller configs differ'

run_primary start >"${run_dir}/primary-start.txt" 2>&1 || \
	fail 'isolated primary start failed'
run_backup start >"${run_dir}/backup-start.txt" 2>&1 || \
	fail 'isolated backup start failed'

run_primary takeover >"${run_dir}/takeover.txt" 2>&1 || \
	fail 'isolated takeover command or primary wait failed'
run_primary collect >"${run_dir}/primary-result.env" 2>&1 || \
	fail 'primary result collection failed'
run_backup collect >"${run_dir}/backup-result.env" 2>&1 || \
	fail 'backup result collection failed'

primary_result=$(sed -n 's/^result=//p' "${run_dir}/primary-result.env" | tail -n 1)
takeover_observed=$(sed -n 's/^takeover_observed=//p' \
	"${run_dir}/backup-result.env" | tail -n 1)
backup_role=$(sed -n 's/^primary_role=//p' "${run_dir}/backup-result.env" | tail -n 1)
backup_alive=$(sed -n 's/^process_alive=//p' "${run_dir}/backup-result.env" | tail -n 1)

case "$primary_result" in
REPRODUCED_FASTTOP_WITH_BACKTRACE|REPRODUCED_OTHER_SIGABRT_WITH_BACKTRACE|REPRODUCED_SIGABRT_BACKTRACE_MISSING)
	result=$primary_result
	;;
PRIMARY_CLEAN_AFTER_ISOLATED_TAKEOVER)
	if [ "$takeover_observed" = YES ] && [ "$backup_role" = YES ] && \
		[ "$backup_alive" = YES ]; then
		result=NOT_REPRODUCED_CLEAN_ISOLATED_TAKEOVER
	else
		result=INCONCLUSIVE_BACKUP_ROLE_NOT_OBSERVED
	fi
	;;
*)
	result=INCONCLUSIVE_ISOLATED_TAKEOVER
	;;
esac

run_backup cleanup >"${run_dir}/backup-cleanup.txt" 2>&1 || \
	fail 'isolated backup cleanup failed'
run_primary cleanup >"${run_dir}/primary-cleanup.txt" 2>&1 || \
	fail 'isolated primary cleanup failed'
cleanup_complete=1

run_primary postflight >"${run_dir}/primary-postflight.txt" 2>&1 || \
	fail 'primary production postflight failed'
run_backup postflight >"${run_dir}/backup-postflight.txt" 2>&1 || \
	fail 'backup production postflight failed'
mac_health after || fail 'Mac production postflight failed'

primary_pid_after=$(sed -n 's/.*production_pid=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/primary-postflight.txt" | tail -n 1)
backup_pid_after=$(sed -n 's/.*production_pid=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/backup-postflight.txt" | tail -n 1)
[ "$primary_pid_after" = "$primary_pid_before" ] || \
	fail 'production primary PID changed'
[ "$backup_pid_after" = "$backup_pid_before" ] || \
	fail 'production backup PID changed'

{
	printf 'result=%s\n' "$result"
	printf 'isolated_config_sha256=%s\n' "$primary_config"
	printf 'primary_production_pid=%s\n' "$primary_pid_after"
	printf 'backup_production_pid=%s\n' "$backup_pid_after"
	printf 'takeover_observed=%s\n' "$takeover_observed"
	printf 'backup_primary_role=%s\n' "$backup_role"
	printf 'queue=EMPTY\n'
	printf 'nodes=IDLE\n'
	printf 'jobs=NONE\n'
} >"${run_dir}/result.env"

trap - EXIT HUP INT TERM
printf 'SMD405_ISOLATED_TAKEOVER_COMPLETE result=%s production=UNCHANGED queue=EMPTY nodes=IDLE jobs=NONE run_dir=%s\n' \
	"$result" "$run_dir"
