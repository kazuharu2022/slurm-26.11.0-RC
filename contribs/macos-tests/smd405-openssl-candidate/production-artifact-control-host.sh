#!/bin/sh

# Approval-gated production artifact install/rollback for the three SMD-405
# OpenSSL shutdown candidate files. Service stop/start is deliberately external.

set -u
umask 077

mode=${MODE:-}
run_stamp=${RUN_STAMP:-}
case "$mode" in
preflight|install_stopped|verify_running|rollback_stopped|verify_rollback_running) ;;
*) printf 'error: unsupported MODE=%s\n' "$mode" >&2; exit 64 ;;
esac
case "$run_stamp" in
''|*[!0-9T]*) printf 'error: invalid RUN_STAMP=%s\n' "$run_stamp" >&2; exit 64 ;;
esac
if [ "$mode" = install_stopped ] && \
	[ "${SMD405_OPENSSL_PRODUCTION_INSTALL_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_OPENSSL_PRODUCTION_INSTALL_CONFIRMED=YES after approving the production artifact install' >&2
	exit 64
fi
if [ "$mode" = rollback_stopped ] && \
	[ "${SMD405_OPENSSL_PRODUCTION_ROLLBACK_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_OPENSSL_PRODUCTION_ROLLBACK_CONFIRMED=YES after approving the production artifact rollback' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

host=$(hostname -s)
case "$host" in
ubuntu2504) role=primary; services='slurmctld slurmdbd slurmd' ;;
slurmctld-bak) role=backup; services=slurmctld ;;
*) printf 'error: unexpected hostname=%s\n' "$host" >&2; exit 64 ;;
esac

prefix=/usr/local/slurm/26.11.0
candidate_prefix=${SMD405_CANDIDATE_STAGE_PREFIX:-}
backup_dir=${SMD405_PRODUCTION_BACKUP_DIR:-/var/backups/smd405-openssl-${run_stamp}-${host}}
run_dir=/var/tmp/smd405-openssl-production-${mode}-${run_stamp}-${host}
production_conf=${prefix}/etc/slurm.conf
production_binary=${prefix}/sbin/slurmctld
production_lib_path=${prefix}/lib/slurm:${prefix}/lib
if [ "$role" = backup ]; then
	production_lib_path=${production_lib_path}:${prefix}/lib/smd405-runtime/lib
fi

expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_production_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
old_libslurmfull=81b9181f4564e1e506dba91796d7f1aa11daf687fa2178744088a3b3d64d96b5
old_auth_slurm=0bbd658e95d5fe82ce172e809f3af20472610f06ce8d33ac7213032c82ae6f79
old_auth_jwt=3b9d9a5078ba51d7b0197872e54828f0ddd7ed68bf9c982ce816814dd3b89812
new_libslurmfull=791fa00eff4b949cfbb667fc250fc9b40e2e096f7494ad0d763138d62fea9391
new_auth_slurm=536b07689bedad94cc8e663682b85db0d4e42391a86cc499e4f5895247ff3ee9
new_auth_jwt=686057ecdca7c6476ddf44fefdb3b90014bf208fde39e759f2cf0c55e15f7167
artifact_paths='lib/slurm/libslurmfull.so lib/slurm/auth_slurm.so lib/slurm/auth_jwt.so'

success=0
mutation=0
forensic_dir=

fail()
{
	printf 'SMD405_OPENSSL_PRODUCTION_ARTIFACT_FAILED host=%s role=%s mode=%s error=%s backup=%s run_dir=%s\n' \
		"$host" "$role" "$mode" "$1" "$backup_dir" "$run_dir" >&2
	exit 1
}

file_hash()
{
	sha256sum "$1" | awk '{print $1}'
}

expected_hash()
{
	set_name=$1
	relative=$2
	case "${set_name}:${relative}" in
	old:lib/slurm/libslurmfull.so) printf '%s\n' "$old_libslurmfull" ;;
	old:lib/slurm/auth_slurm.so) printf '%s\n' "$old_auth_slurm" ;;
	old:lib/slurm/auth_jwt.so) printf '%s\n' "$old_auth_jwt" ;;
	new:lib/slurm/libslurmfull.so) printf '%s\n' "$new_libslurmfull" ;;
	new:lib/slurm/auth_slurm.so) printf '%s\n' "$new_auth_slurm" ;;
	new:lib/slurm/auth_jwt.so) printf '%s\n' "$new_auth_jwt" ;;
	*) return 1 ;;
	esac
}

atomic_install()
{
	source_file=$1
	target_file=$2
	reference_file=$3
	tmp_file=${target_file}.smd405-openssl.$$
	uid=$(stat -c '%u' "$reference_file") || return 1
	gid=$(stat -c '%g' "$reference_file") || return 1
	file_mode=$(stat -c '%a' "$reference_file") || return 1
	if ! install -o "$uid" -g "$gid" -m "$file_mode" \
		"$source_file" "$tmp_file"; then
		rm -f -- "$tmp_file"
		return 1
	fi
	if ! mv -f -- "$tmp_file" "$target_file"; then
		rm -f -- "$tmp_file"
		return 1
	fi
}

verify_artifact_set()
{
	set_name=$1
	for relative in $artifact_paths; do
		target=${prefix}/${relative}
		[ -f "$target" ] || return 1
		[ "$(file_hash "$target")" = "$(expected_hash "$set_name" "$relative")" ] || \
			return 1
	done
}

services_are_active()
{
	for service in $services; do
		[ "$(systemctl is-active "$service" 2>/dev/null || true)" = active ] || \
			return 1
	done
	if [ "$role" = backup ]; then
		[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || \
			return 1
	fi
}

services_are_inactive()
{
	for service in $services; do
		state=$(systemctl is-active "$service" 2>/dev/null || true)
		case "$state" in
		inactive|failed) ;;
		*) return 1 ;;
		esac
	done
}

production_command()
{
	env \
		PATH=${prefix}/bin:${prefix}/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
		LD_LIBRARY_PATH=$production_lib_path \
		SLURM_CONF=$production_conf \
		"$@"
}

cluster_health()
{
	ping_output=$(production_command "${prefix}/bin/scontrol" ping 2>&1) || return 1
	printf '%s\n' "$ping_output" | \
		grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' || return 1
	printf '%s\n' "$ping_output" | \
		grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' || return 1
	[ -z "$(production_command "${prefix}/bin/squeue" -h)" ] || return 1
	for node in ubuntu PC-210; do
		node_output=$(production_command "${prefix}/bin/scontrol" show node "$node") || \
			return 1
		printf '%s\n' "$node_output" | grep -Eq \
			'(^|[[:space:]])State=IDLE([[:space:]]|$)' || return 1
		printf '%s\n' "$node_output" | grep -Eq \
			'(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' || return 1
	done
}

verify_loaded_artifact()
{
	service=$1
	relative=$2
	target=${prefix}/${relative}
	pid=$(systemctl show -p MainPID --value "$service") || return 1
	[ "$pid" -gt 1 ] || return 1
	file_inode=$(stat -c '%i' "$target") || return 1
	mapped_inode=$(awk -v path="$target" '$NF == path { print $5; exit }' \
		"/proc/${pid}/maps") || return 1
	[ -n "$mapped_inode" ] || return 1
	[ "$mapped_inode" = "$file_inode" ]
}

configured_debug_level()
{
	service=$1
	case "$service" in
	slurmctld) config_file=$production_conf; config_key=SlurmctldDebug ;;
	slurmd) config_file=$production_conf; config_key=SlurmdDebug ;;
	slurmdbd) config_file=${prefix}/etc/slurmdbd.conf; config_key=DebugLevel ;;
	*) return 1 ;;
	esac
	level=$(awk -F= -v key="$config_key" '
		{
			name = $1
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
			if (name == key) {
				value = $2
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
				print tolower(value)
				exit
			}
		}' "$config_file") || return 1
	[ -n "$level" ] || level=default_info
	printf '%s\n' "$level"
}

restore_from_directory()
{
	source_root=$1
	for relative in $artifact_paths; do
		[ -f "${source_root}/${relative}" ] || return 1
		atomic_install "${source_root}/${relative}" "${prefix}/${relative}" \
			"${source_root}/${relative}" || return 1
	done
}

recover_on_exit()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$mutation" -eq 1 ]; then
		if [ "$mode" = install_stopped ]; then
			if restore_from_directory "$backup_dir" && verify_artifact_set old; then
				printf 'recovery=ORIGINAL_ARTIFACTS_RESTORED backup=%s\n' "$backup_dir" >&2
			else
				printf 'fatal_recovery=ORIGINAL_ARTIFACT_RESTORE_FAILED backup=%s\n' "$backup_dir" >&2
			fi
		elif [ "$mode" = rollback_stopped ] && [ -n "$forensic_dir" ]; then
			if restore_from_directory "$forensic_dir" && verify_artifact_set new; then
				printf 'recovery=CANDIDATE_ARTIFACTS_RESTORED forensic=%s\n' "$forensic_dir" >&2
			else
				printf 'fatal_recovery=CANDIDATE_ARTIFACT_RESTORE_FAILED forensic=%s\n' "$forensic_dir" >&2
			fi
		fi
	fi
	exit "$rc"
}

trap recover_on_exit EXIT HUP INT TERM

[ "$(id -u)" -eq 0 ] || fail 'must run as root'
[ "$(uname -s)" = Linux ] || fail 'this control is for Linux'
case "$backup_dir" in
/var/backups/smd405-openssl-*) ;;
*) fail 'backup directory is outside the approved path' ;;
esac
[ "$(file_hash "$production_conf")" = "$expected_config" ] || \
	fail 'production config hash mismatch'
[ "$(file_hash "$production_binary")" = "$expected_production_binary" ] || \
	fail 'production slurmctld hash mismatch'
[ ! -e "$run_dir" ] || fail 'run directory already exists'
install -d -o root -g root -m 0700 "$run_dir" || fail 'cannot create run directory'

case "$mode" in
preflight|install_stopped)
	[ -n "$candidate_prefix" ] || fail 'candidate stage prefix is required'
	[ -d "$candidate_prefix" ] || fail 'candidate stage prefix is absent'
	for relative in $artifact_paths; do
		candidate=${candidate_prefix}/${relative}
		[ -f "$candidate" ] || fail "candidate artifact is absent artifact=${relative}"
		[ "$(file_hash "$candidate")" = "$(expected_hash new "$relative")" ] || \
			fail "candidate artifact hash mismatch artifact=${relative}"
	done
	;;
esac

case "$mode" in
preflight)
	verify_artifact_set old || fail 'production artifact set is not the expected original set'
	services_are_active || fail 'production services are not active'
	cluster_health || fail 'cluster health check failed'
	[ ! -e "$backup_dir" ] || fail 'planned backup directory already exists'
	printf 'SMD405_OPENSSL_PRODUCTION_ARTIFACT_PREFLIGHT_PASS host=%s role=%s current=ORIGINAL candidate=FIXED_THREE services=ACTIVE queue=EMPTY nodes=IDLE backup=%s\n' \
		"$host" "$role" "$backup_dir"
	;;
install_stopped)
	verify_artifact_set old || fail 'production artifact set is not the expected original set'
	services_are_inactive || fail 'all host production services must be inactive before install'
	[ ! -e "$backup_dir" ] || fail 'backup directory already exists'
	for directory in "$backup_dir" "${backup_dir}/lib" "${backup_dir}/lib/slurm"; do
		install -d -o root -g root -m 0700 "$directory" || \
			fail "cannot create protected backup directory=${directory}"
	done
	for relative in $artifact_paths; do
		cp -p -- "${prefix}/${relative}" "${backup_dir}/${relative}" || \
			fail "cannot back up artifact=${relative}"
		[ "$(file_hash "${backup_dir}/${relative}")" = \
			"$(expected_hash old "$relative")" ] || \
			fail "backup hash mismatch artifact=${relative}"
	done
	date +%s >"${backup_dir}/install-epoch"
	mutation=1
	for relative in $artifact_paths; do
		atomic_install "${candidate_prefix}/${relative}" "${prefix}/${relative}" \
			"${backup_dir}/${relative}" || fail "candidate install failed artifact=${relative}"
	done
	verify_artifact_set new || fail 'installed candidate artifact set verification failed'
	{
		printf 'host=%s\nrole=%s\nrun_stamp=%s\n' "$host" "$role" "$run_stamp"
		printf 'state=CANDIDATE_INSTALLED_SERVICES_STOPPED\n'
	} >"${backup_dir}/install-state.env" || fail 'cannot write install state'
	chmod 0600 "${backup_dir}/install-epoch" "${backup_dir}/install-state.env" || \
		fail 'cannot protect install metadata'
	success=1
	printf 'SMD405_OPENSSL_PRODUCTION_ARTIFACT_INSTALL_PASS host=%s role=%s artifacts=THREE services=INACTIVE backup=%s\n' \
		"$host" "$role" "$backup_dir"
	;;
verify_running)
	verify_artifact_set new || fail 'production artifact set is not the candidate set'
	services_are_active || fail 'production services are not active after install'
	cluster_health || fail 'cluster health check failed after install'
	[ -f "${backup_dir}/install-epoch" ] || fail 'install epoch is absent'
	helper_runtime=DIRECT_DEBUG2_LOG
	for service in $services; do
		verify_loaded_artifact "$service" lib/slurm/libslurmfull.so || \
			fail "service does not map installed libslurmfull service=${service}"
		verify_loaded_artifact "$service" lib/slurm/auth_slurm.so || \
			fail "service does not map installed auth_slurm service=${service}"
		journalctl -u "$service" --since "@$(sed -n '1p' "${backup_dir}/install-epoch")" \
			--no-pager -o cat >"${run_dir}/${service}.journal" 2>&1 || \
			fail "cannot read service journal service=${service}"
		debug_level=$(configured_debug_level "$service") || \
			fail "cannot determine configured debug level service=${service}"
		if grep -Fq 'disabled OpenSSL atexit cleanup' "${run_dir}/${service}.journal"; then
			observation=DIRECT_DEBUG2_LOG
		else
			case "$debug_level" in
			debug2|debug3|debug4|debug5)
				fail "OpenSSL helper debug2 log is absent at visible debug level service=${service}"
				;;
			*)
				observation=AUTH_PLUGIN_CURRENT_INODE_AND_AUTHENTICATED_LIFECYCLE_DEBUG2_FILTERED
				helper_runtime=DEBUG2_FILTERED_LIFECYCLE_CONFIRMED
				;;
			esac
		fi
		printf 'service=%s configured_debug=%s helper_observation=%s\n' \
			"$service" "$debug_level" "$observation" | \
			tee "${run_dir}/${service}.helper-observation"
	done
	success=1
	printf 'SMD405_OPENSSL_PRODUCTION_ARTIFACT_VERIFY_PASS host=%s role=%s artifacts=THREE mapped=CURRENT_INODES helper_runtime=%s services=ACTIVE queue=EMPTY nodes=IDLE backup=%s\n' \
		"$host" "$role" "$helper_runtime" "$backup_dir"
	;;
rollback_stopped)
	verify_artifact_set new || fail 'production artifact set is not the candidate set'
	services_are_inactive || fail 'all host production services must be inactive before rollback'
	for relative in $artifact_paths; do
		[ "$(file_hash "${backup_dir}/${relative}")" = \
			"$(expected_hash old "$relative")" ] || \
			fail "rollback backup hash mismatch artifact=${relative}"
	done
	forensic_dir=${backup_dir}/failed-candidate-${run_stamp}
	[ ! -e "$forensic_dir" ] || fail 'forensic candidate directory already exists'
	for directory in "$forensic_dir" "${forensic_dir}/lib" "${forensic_dir}/lib/slurm"; do
		install -d -o root -g root -m 0700 "$directory" || \
			fail "cannot create forensic candidate directory=${directory}"
	done
	for relative in $artifact_paths; do
		cp -p -- "${prefix}/${relative}" "${forensic_dir}/${relative}" || \
			fail "cannot preserve candidate artifact=${relative}"
	done
	mutation=1
	restore_from_directory "$backup_dir" || fail 'original artifact restore failed'
	verify_artifact_set old || fail 'restored original artifact set verification failed'
	printf 'state=ORIGINAL_RESTORED_SERVICES_STOPPED\n' \
		>"${backup_dir}/rollback-state-${run_stamp}.env" || fail 'cannot write rollback state'
	chmod 0600 "${backup_dir}/rollback-state-${run_stamp}.env" || \
		fail 'cannot protect rollback metadata'
	success=1
	printf 'SMD405_OPENSSL_PRODUCTION_ARTIFACT_ROLLBACK_PASS host=%s role=%s artifacts=THREE services=INACTIVE backup=%s forensic=%s\n' \
		"$host" "$role" "$backup_dir" "$forensic_dir"
	;;
verify_rollback_running)
	verify_artifact_set old || fail 'production artifact set is not the restored original set'
	services_are_active || fail 'production services are not active after rollback'
	cluster_health || fail 'cluster health check failed after rollback'
	for service in $services; do
		verify_loaded_artifact "$service" lib/slurm/libslurmfull.so || \
			fail "service does not map restored libslurmfull service=${service}"
		verify_loaded_artifact "$service" lib/slurm/auth_slurm.so || \
			fail "service does not map restored auth_slurm service=${service}"
	done
	success=1
	printf 'SMD405_OPENSSL_PRODUCTION_ARTIFACT_ROLLBACK_VERIFY_PASS host=%s role=%s artifacts=ORIGINAL mapped=CURRENT_INODES services=ACTIVE queue=EMPTY nodes=IDLE backup=%s\n' \
		"$host" "$role" "$backup_dir"
	;;
esac

trap - EXIT HUP INT TERM
