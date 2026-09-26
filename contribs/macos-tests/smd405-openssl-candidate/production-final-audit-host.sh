#!/bin/sh

# Read-only post-deployment audit for the SMD-405 three-artifact production
# rollout. It verifies disk hashes, running mappings, controller roles, service
# state, cluster health, and protected rollback material without restarting or
# modifying a production service.

set -u
umask 077

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

run_stamp=${RUN_STAMP:-}
case "$run_stamp" in
''|*[!0-9T]*) printf 'error: invalid RUN_STAMP=%s\n' "$run_stamp" >&2; exit 64 ;;
esac

[ "$(id -u)" -eq 0 ] || {
	printf '%s\n' 'error: must run as root' >&2
	exit 64
}

host=$(hostname -s)
case "$host" in
ubuntu2504)
	role=primary
	services='slurmctld slurmdbd slurmd'
	;;
slurmctld-bak)
	role=backup
	services=slurmctld
	;;
*)
	printf 'error: unexpected hostname=%s\n' "$host" >&2
	exit 64
	;;
esac

prefix=/usr/local/slurm/26.11.0
backup_dir=${SMD405_PRODUCTION_BACKUP_DIR:-}
run_dir=/var/tmp/smd405-openssl-final-audit-${run_stamp}-${host}
production_conf=${prefix}/etc/slurm.conf
production_lib_path=${prefix}/lib/slurm:${prefix}/lib
if [ -d "${prefix}/lib/smd405-runtime/lib" ]; then
	production_lib_path=${production_lib_path}:${prefix}/lib/smd405-runtime/lib
fi

expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
old_libslurmfull=81b9181f4564e1e506dba91796d7f1aa11daf687fa2178744088a3b3d64d96b5
old_auth_slurm=0bbd658e95d5fe82ce172e809f3af20472610f06ce8d33ac7213032c82ae6f79
old_auth_jwt=3b9d9a5078ba51d7b0197872e54828f0ddd7ed68bf9c982ce816814dd3b89812
new_libslurmfull=791fa00eff4b949cfbb667fc250fc9b40e2e096f7494ad0d763138d62fea9391
new_auth_slurm=536b07689bedad94cc8e663682b85db0d4e42391a86cc499e4f5895247ff3ee9
new_auth_jwt=686057ecdca7c6476ddf44fefdb3b90014bf208fde39e759f2cf0c55e15f7167
artifact_paths='lib/slurm/libslurmfull.so lib/slurm/auth_slurm.so lib/slurm/auth_jwt.so'

fail()
{
	printf 'SMD405_OPENSSL_PRODUCTION_FINAL_AUDIT_FAILED host=%s role=%s error=%s run_dir=%s\n' \
		"$host" "$role" "$1" "$run_dir" >&2
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

production_command()
{
	env \
		PATH=${prefix}/bin:${prefix}/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
		LD_LIBRARY_PATH=$production_lib_path \
		SLURM_CONF=$production_conf \
		"$@"
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

case "$backup_dir" in
/var/backups/smd405-openssl-*-${host}) ;;
*) fail 'backup directory is outside the approved host path' ;;
esac
[ -d "$backup_dir" ] || fail 'rollback backup directory is absent'
[ "$(stat -c '%U:%G:%a' "$backup_dir")" = root:root:700 ] || \
	fail 'rollback backup directory ownership or mode mismatch'
[ "$(file_hash "$production_conf")" = "$expected_config" ] || \
	fail 'production config hash mismatch'
[ "$(file_hash "${prefix}/sbin/slurmctld")" = "$expected_binary" ] || \
	fail 'production slurmctld hash mismatch'
[ ! -e "$run_dir" ] || fail 'run directory already exists'
install -d -o root -g root -m 0700 "$run_dir" || fail 'cannot create audit directory'

for relative in $artifact_paths; do
	production=${prefix}/${relative}
	rollback=${backup_dir}/${relative}
	[ -f "$production" ] || fail "production artifact is absent artifact=${relative}"
	[ -f "$rollback" ] || fail "rollback artifact is absent artifact=${relative}"
	[ "$(file_hash "$production")" = "$(expected_hash new "$relative")" ] || \
		fail "production candidate hash mismatch artifact=${relative}"
	[ "$(file_hash "$rollback")" = "$(expected_hash old "$relative")" ] || \
		fail "rollback original hash mismatch artifact=${relative}"
done

for artifact in \
	"${prefix}/lib/slurm/libslurmfull.so" \
	"${prefix}/lib/slurm/auth_slurm.so" \
	"${prefix}/lib/slurm/auth_jwt.so"
do
	env LD_LIBRARY_PATH="$production_lib_path" ldd "$artifact" \
		>>"${run_dir}/ldd.txt" 2>&1 || fail "ldd failed artifact=${artifact}"
done
grep -Fq 'not found' "${run_dir}/ldd.txt" && fail 'runtime dependency is unresolved'

for service in $services; do
	[ "$(systemctl is-active "$service" 2>/dev/null || true)" = active ] || \
		fail "service is not active service=${service}"
	verify_loaded_artifact "$service" lib/slurm/libslurmfull.so || \
		fail "service does not map current libslurmfull service=${service}"
	verify_loaded_artifact "$service" lib/slurm/auth_slurm.so || \
		fail "service does not map current auth_slurm service=${service}"
done
if [ "$role" = backup ]; then
	[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || \
		fail 'backup slurmctld is not disabled for boot'
fi

production_command "${prefix}/bin/scontrol" ping >"${run_dir}/ping.txt" 2>&1 || \
	fail 'controller ping failed'
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' "${run_dir}/ping.txt" || \
	fail 'primary controller is not UP'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' "${run_dir}/ping.txt" || \
	fail 'backup controller is not UP'
[ -z "$(production_command "${prefix}/bin/squeue" -h)" ] || fail 'queue is not empty'
for node in ubuntu PC-210; do
	node_output=$(production_command "${prefix}/bin/scontrol" show node "$node") || \
		fail "cannot inspect node=${node}"
	printf '%s\n' "$node_output" | grep -Eq \
		'(^|[[:space:]])State=IDLE([[:space:]]|$)' || fail "node is not IDLE node=${node}"
	printf '%s\n' "$node_output" | grep -Eq \
		'(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' || fail "node is allocated node=${node}"
done

production_command "${prefix}/bin/sacctmgr" ping >"${run_dir}/slurmdbd-ping.txt" 2>&1 || \
	fail 'slurmdbd ping failed'
grep -Fq ' is UP' "${run_dir}/slurmdbd-ping.txt" || fail 'slurmdbd is not UP'

slurmctld_pid=$(systemctl show -p MainPID --value slurmctld)
journalctl -u slurmctld "_PID=${slurmctld_pid}" --no-pager -o cat \
	>"${run_dir}/slurmctld-current-process.journal" 2>&1 || \
	fail 'cannot read current slurmctld journal'
last_role_event=$(awk '
	/slurmctld running in background mode|Running as primary controller/ { last = $0 }
	END { print last }
' "${run_dir}/slurmctld-current-process.journal")
case "$role:$last_role_event" in
primary:*'Running as primary controller'*) ;;
backup:*'slurmctld running in background mode'*) ;;
*) fail "current controller role evidence mismatch last_event=${last_role_event}" ;;
esac

abrt_count=0
for service in $services; do
	service_pid=$(systemctl show -p MainPID --value "$service")
	journalctl -u "$service" "_PID=${service_pid}" --no-pager -o cat \
		>"${run_dir}/${service}-current-process.journal" 2>&1 || \
		fail "cannot read current process journal service=${service}"
	count=$(grep -Eic 'double free|corruption \(fasttop\)|SIGABRT|status=6/ABRT' \
		"${run_dir}/${service}-current-process.journal" || true)
	abrt_count=$((abrt_count + count))
done
[ "$abrt_count" -eq 0 ] || fail 'ABRT marker exists in current deployed processes'

printf 'SMD405_OPENSSL_PRODUCTION_FINAL_AUDIT_PASS host=%s role=%s artifacts=FIXED_THREE dependencies=PASS mapped=CURRENT_INODES services=ACTIVE controller_role=EXPECTED controllers=BOTH_UP slurmdbd=UP queue=EMPTY nodes=IDLE current_process_abrt=NONE rollback=ORIGINAL_PROTECTED backup=%s run_dir=%s\n' \
	"$host" "$role" "$backup_dir" "$run_dir"
