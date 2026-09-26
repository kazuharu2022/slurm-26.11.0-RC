#!/bin/sh

# Install the fixed SMD-405 three-artifact set on the original primary after
# its slurmctld is stopped and the patched backup has assumed control.

set -u
umask 077

if [ "${SMD405_OPENSSL_PRIMARY_DEPLOYMENT_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_OPENSSL_PRIMARY_DEPLOYMENT_CONFIRMED=YES after approving primary production deployment' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

run_stamp=${RUN_STAMP:-}
case "$run_stamp" in
''|*[!0-9T]*) printf 'error: invalid RUN_STAMP=%s\n' "$run_stamp" >&2; exit 64 ;;
esac

[ "$(hostname -s)" = ubuntu2504 ] || {
	printf 'error: unexpected hostname=%s\n' "$(hostname -s)" >&2
	exit 64
}
[ "$(id -u)" -eq 0 ] || {
	printf '%s\n' 'error: must run as root' >&2
	exit 64
}

prefix=/usr/local/slurm/26.11.0
candidate_prefix=${SMD405_CANDIDATE_STAGE_PREFIX:-}
control=${SMD405_PRODUCTION_CONTROL:-}
backup_dir=${SMD405_PRODUCTION_BACKUP_DIR:-}
run_dir=/var/tmp/smd405-openssl-primary-deploy-${run_stamp}
expected_control_sha=6ca01fb39aa34909f15c5f6349d92cdc537333c70c26cfc2ae7f3ab032b83b97
expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70

old_libslurmfull=81b9181f4564e1e506dba91796d7f1aa11daf687fa2178744088a3b3d64d96b5
old_auth_slurm=0bbd658e95d5fe82ce172e809f3af20472610f06ce8d33ac7213032c82ae6f79
old_auth_jwt=3b9d9a5078ba51d7b0197872e54828f0ddd7ed68bf9c982ce816814dd3b89812
new_libslurmfull=791fa00eff4b949cfbb667fc250fc9b40e2e096f7494ad0d763138d62fea9391
new_auth_slurm=536b07689bedad94cc8e663682b85db0d4e42391a86cc499e4f5895247ff3ee9
new_auth_jwt=686057ecdca7c6476ddf44fefdb3b90014bf208fde39e759f2cf0c55e15f7167

success=0
needs_recovery=0
recovering=0

file_hash()
{
	sha256sum "$1" | awk '{print $1}'
}

artifact_state()
{
	libslurmfull=$(file_hash "${prefix}/lib/slurm/libslurmfull.so") || return 1
	auth_slurm=$(file_hash "${prefix}/lib/slurm/auth_slurm.so") || return 1
	auth_jwt=$(file_hash "${prefix}/lib/slurm/auth_jwt.so") || return 1
	if [ "$libslurmfull" = "$old_libslurmfull" ] && \
		[ "$auth_slurm" = "$old_auth_slurm" ] && \
		[ "$auth_jwt" = "$old_auth_jwt" ]; then
		printf '%s\n' ORIGINAL
	elif [ "$libslurmfull" = "$new_libslurmfull" ] && \
		[ "$auth_slurm" = "$new_auth_slurm" ] && \
		[ "$auth_jwt" = "$new_auth_jwt" ]; then
		printf '%s\n' CANDIDATE
	else
		printf '%s\n' MIXED_OR_UNKNOWN
	fi
}

run_control()
{
	requested_mode=$1
	SMD405_OPENSSL_PRODUCTION_INSTALL_CONFIRMED=YES \
	SMD405_OPENSSL_PRODUCTION_ROLLBACK_CONFIRMED=YES \
	MODE="$requested_mode" \
	RUN_STAMP="$run_stamp" \
	SMD405_CANDIDATE_STAGE_PREFIX="$candidate_prefix" \
	SMD405_PRODUCTION_BACKUP_DIR="$backup_dir" \
		/bin/sh "$control"
}

production_command()
{
	env \
		PATH=${prefix}/bin:${prefix}/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
		LD_LIBRARY_PATH=${prefix}/lib/slurm:${prefix}/lib \
		SLURM_CONF=${prefix}/etc/slurm.conf \
		"$@"
}

wait_cluster()
{
	label=$1
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		attempt=$((attempt + 1))
		production_command "${prefix}/bin/scontrol" ping \
			>"${run_dir}/${label}-ping.txt" 2>&1 || true
		if grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
			"${run_dir}/${label}-ping.txt" && \
			grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' \
			"${run_dir}/${label}-ping.txt"; then
			if queue_output=$(production_command "${prefix}/bin/squeue" -h 2>/dev/null) && \
				[ -z "$queue_output" ]; then
				all_idle=1
				for node in ubuntu PC-210; do
					node_output=$(production_command "${prefix}/bin/scontrol" show node "$node" 2>/dev/null || true)
					printf '%s\n' "$node_output" | grep -Eq \
						'(^|[[:space:]])State=IDLE([[:space:]]|$)' || all_idle=0
					printf '%s\n' "$node_output" | grep -Eq \
						'(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' || all_idle=0
				done
				[ "$all_idle" -eq 1 ] && return 0
			fi
		fi
		sleep 1
	done
	return 1
}

start_primary_stack()
{
	systemctl start slurmdbd || return 1
	systemctl start slurmctld || return 1
	systemctl start slurmd || return 1
	wait_cluster "$1"
}

recover_original()
{
	recovering=1
	printf 'SMD405_OPENSSL_PRIMARY_DEPLOYMENT_RECOVERY_BEGIN backup=%s\n' \
		"$backup_dir" >&2
	systemctl stop slurmctld slurmd slurmdbd >/dev/null 2>&1 || true
	state=$(artifact_state) || state=MIXED_OR_UNKNOWN
	case "$state" in
	CANDIDATE)
		if ! run_control rollback_stopped; then
			printf 'SMD405_OPENSSL_PRIMARY_DEPLOYMENT_FATAL recovery=ROLLBACK_COMMAND_FAILED backup=%s\n' \
				"$backup_dir" >&2
			return 1
		fi
		;;
	ORIGINAL) ;;
	*)
		printf 'SMD405_OPENSSL_PRIMARY_DEPLOYMENT_FATAL recovery=MIXED_ARTIFACT_SET_SERVICES_LEFT_STOPPED backup=%s\n' \
			"$backup_dir" >&2
		return 1
		;;
	esac
	if ! start_primary_stack recovery; then
		printf 'SMD405_OPENSSL_PRIMARY_DEPLOYMENT_FATAL recovery=ORIGINAL_STACK_START_OR_HEALTH_FAILED backup=%s\n' \
			"$backup_dir" >&2
		return 1
	fi
	if ! run_control verify_rollback_running; then
		printf 'SMD405_OPENSSL_PRIMARY_DEPLOYMENT_FATAL recovery=ORIGINAL_VERIFY_FAILED backup=%s\n' \
			"$backup_dir" >&2
		return 1
	fi
	printf 'SMD405_OPENSSL_PRIMARY_DEPLOYMENT_RECOVERY_PASS artifacts=ORIGINAL services=ACTIVE backup=%s\n' \
		"$backup_dir" >&2
	needs_recovery=0
	return 0
}

on_exit()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$needs_recovery" -eq 1 ] && \
		[ "$recovering" -eq 0 ]; then
		recover_original || true
	fi
	exit "$rc"
}

fail()
{
	printf 'SMD405_OPENSSL_PRIMARY_DEPLOYMENT_FAILED error=%s backup=%s run_dir=%s\n' \
		"$1" "$backup_dir" "$run_dir" >&2
	exit 1
}

case "$control" in
/*) ;;
*) fail 'production control path must be absolute' ;;
esac
case "$candidate_prefix" in
/var/tmp/smd405-openssl-minimal-stage-*) ;;
*) fail 'candidate stage prefix is outside the approved path' ;;
esac
case "$backup_dir" in
/var/backups/smd405-openssl-*-ubuntu2504) ;;
*) fail 'backup directory is outside the approved primary path' ;;
esac
[ -x "$control" ] || fail 'production control is absent or not executable'
[ "$(file_hash "$control")" = "$expected_control_sha" ] || \
	fail 'production control hash mismatch'
[ "$(file_hash "${prefix}/etc/slurm.conf")" = "$expected_config" ] || \
	fail 'production config hash mismatch'
[ "$(file_hash "${prefix}/sbin/slurmctld")" = "$expected_binary" ] || \
	fail 'production slurmctld hash mismatch'
[ "$(artifact_state)" = ORIGINAL ] || fail 'primary artifact set is not original'
primary_state=$(systemctl is-active slurmctld 2>/dev/null || true)
case "$primary_state" in inactive|failed) ;; *) fail 'primary slurmctld must already be stopped' ;; esac
pgrep -x slurmctld >/dev/null 2>&1 && fail 'a slurmctld process still exists on primary'
[ "$(systemctl is-active slurmdbd 2>/dev/null || true)" = active ] || \
	fail 'slurmdbd must be active before controlled install'
[ "$(systemctl is-active slurmd 2>/dev/null || true)" = active ] || \
	fail 'slurmd must be active before controlled install'
[ ! -e "$backup_dir" ] || fail 'backup directory already exists'
[ ! -e "$run_dir" ] || fail 'wrapper run directory already exists'
install -d -o root -g root -m 0700 "$run_dir" || fail 'cannot create wrapper run directory'

production_command "${prefix}/bin/scontrol" ping >"${run_dir}/backup-control-ping.txt" 2>&1 || true
grep -Fq 'Slurmctld(primary) at ubuntu2504 is DOWN' "${run_dir}/backup-control-ping.txt" || \
	fail 'original primary is not reported DOWN'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' "${run_dir}/backup-control-ping.txt" || \
	fail 'promoted backup is not reachable'
[ -z "$(production_command "${prefix}/bin/squeue" -h)" ] || \
	fail 'queue is not empty under backup control'

trap on_exit EXIT HUP INT TERM

printf 'SMD405_OPENSSL_PRIMARY_DEPLOYMENT_BEGIN host=ubuntu2504 backup=%s\n' "$backup_dir"
needs_recovery=1
systemctl stop slurmd slurmdbd || fail 'slurmd/slurmdbd stop failed'
for service in slurmctld slurmdbd slurmd; do
	state=$(systemctl is-active "$service" 2>/dev/null || true)
	case "$state" in inactive|failed) ;; *) fail "service did not stop service=${service}" ;; esac
done

run_control install_stopped || fail 'three-artifact install failed'
[ "$(artifact_state)" = CANDIDATE ] || fail 'candidate artifact set is incomplete after install'

start_primary_stack candidate || fail 'candidate primary stack start or cluster recovery failed'
run_control verify_running || fail 'candidate primary runtime verification failed'
production_command "${prefix}/bin/sacctmgr" ping >"${run_dir}/slurmdbd-ping.txt" 2>&1 || \
	fail 'slurmdbd ping failed after candidate start'
grep -Fq ' is UP' "${run_dir}/slurmdbd-ping.txt" || \
	fail 'slurmdbd did not report UP after candidate start'

success=1
needs_recovery=0
trap - EXIT HUP INT TERM
printf 'SMD405_OPENSSL_PRIMARY_DEPLOYMENT_PASS host=ubuntu2504 artifacts=THREE mapped=CURRENT_INODES helper_runtime=DEBUG2_FILTER_AWARE_LIFECYCLE_GATE_PASS services=ACTIVE controllers=BOTH_UP slurmdbd=UP queue=EMPTY nodes=IDLE backup=%s\n' \
	"$backup_dir"
