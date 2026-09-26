#!/bin/sh

# Stop the patched production primary and prove that the formerly observed
# OpenSSL shutdown ABRT is absent. Backup promotion is deliberately separate.

set -u
umask 077

if [ "${SMD405_OPENSSL_PATCHED_PRIMARY_STOP_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_OPENSSL_PATCHED_PRIMARY_STOP_CONFIRMED=YES after approving the patched-primary shutdown regression' >&2
	exit 64
fi

PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib/slurm:/usr/local/slurm/26.11.0/lib
SLURM_CONF=/usr/local/slurm/26.11.0/etc/slurm.conf
export PATH LD_LIBRARY_PATH SLURM_CONF

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
run_dir=/var/tmp/smd405-openssl-patched-primary-stop-${run_stamp}
expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
new_libslurmfull=791fa00eff4b949cfbb667fc250fc9b40e2e096f7494ad0d763138d62fea9391
new_auth_slurm=536b07689bedad94cc8e663682b85db0d4e42391a86cc499e4f5895247ff3ee9
new_auth_jwt=686057ecdca7c6476ddf44fefdb3b90014bf208fde39e759f2cf0c55e15f7167

fail()
{
	printf 'SMD405_OPENSSL_PATCHED_PRIMARY_STOP_FAILED error=%s run_dir=%s\n' "$1" "$run_dir" >&2
	exit 1
}

file_hash()
{
	sha256sum "$1" | awk '{print $1}'
}

verify_loaded_artifact()
{
	relative=$1
	target=${prefix}/${relative}
	pid=$(systemctl show -p MainPID --value slurmctld) || return 1
	[ "$pid" -gt 1 ] || return 1
	file_inode=$(stat -c '%i' "$target") || return 1
	mapped_inode=$(awk -v path="$target" '$NF == path { print $5; exit }' \
		"/proc/${pid}/maps") || return 1
	[ -n "$mapped_inode" ] || return 1
	[ "$mapped_inode" = "$file_inode" ]
}

[ ! -e "$run_dir" ] || fail 'run directory already exists'
install -d -o root -g root -m 0700 "$run_dir" || fail 'cannot create run directory'
[ "$(file_hash "${prefix}/etc/slurm.conf")" = "$expected_config" ] || \
	fail 'production config hash mismatch'
[ "$(file_hash "${prefix}/sbin/slurmctld")" = "$expected_binary" ] || \
	fail 'production slurmctld hash mismatch'
[ "$(file_hash "${prefix}/lib/slurm/libslurmfull.so")" = "$new_libslurmfull" ] || \
	fail 'primary libslurmfull is not fixed candidate'
[ "$(file_hash "${prefix}/lib/slurm/auth_slurm.so")" = "$new_auth_slurm" ] || \
	fail 'primary auth_slurm is not fixed candidate'
[ "$(file_hash "${prefix}/lib/slurm/auth_jwt.so")" = "$new_auth_jwt" ] || \
	fail 'primary auth_jwt is not fixed candidate'
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service" 2>/dev/null || true)" = active ] || \
		fail "service is not active service=${service}"
done
verify_loaded_artifact lib/slurm/libslurmfull.so || \
	fail 'slurmctld does not map current fixed libslurmfull'
verify_loaded_artifact lib/slurm/auth_slurm.so || \
	fail 'slurmctld does not map current fixed auth_slurm'

scontrol ping >"${run_dir}/before-ping.txt" 2>&1 || fail 'controller ping failed before stop'
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' "${run_dir}/before-ping.txt" || \
	fail 'primary is not UP before stop'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' "${run_dir}/before-ping.txt" || \
	fail 'backup is not UP before stop'
[ -z "$(squeue -h)" ] || fail 'queue is not empty before stop'
for node in ubuntu PC-210; do
	node_output=$(scontrol show node "$node") || fail "cannot inspect node=${node}"
	printf '%s\n' "$node_output" | grep -Eq \
		'(^|[[:space:]])State=IDLE([[:space:]]|$)' || fail "node is not IDLE node=${node}"
	printf '%s\n' "$node_output" | grep -Eq \
		'(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' || fail "node is allocated node=${node}"
done

old_pid=$(systemctl show -p MainPID --value slurmctld)
start_epoch=$(date +%s)
stop_rc=0
systemctl stop slurmctld >"${run_dir}/systemctl-stop.txt" 2>&1 || stop_rc=$?
journalctl -u slurmctld "_PID=${old_pid}" --no-pager -o cat \
	>"${run_dir}/old-process.journal" 2>&1 || true
journalctl -u slurmctld --since "@${start_epoch}" --no-pager -o cat \
	>"${run_dir}/stop-unit.journal" 2>&1 || true
systemctl show slurmctld \
	-p Result -p ExecMainCode -p ExecMainStatus -p MainPID \
	>"${run_dir}/systemd-result.txt" 2>&1 || true

state=$(systemctl is-active slurmctld 2>/dev/null || true)
case "$state" in inactive|failed) ;; *) fail 'patched primary slurmctld did not stop' ;; esac
pgrep -x slurmctld >/dev/null 2>&1 && fail 'patched primary slurmctld process remains after stop'
[ "$stop_rc" -eq 0 ] || fail "systemctl stop returned nonzero rc=${stop_rc}"
grep -Fqx 'Result=success' "${run_dir}/systemd-result.txt" || fail 'systemd result is not success'
grep -Fqx 'ExecMainStatus=0' "${run_dir}/systemd-result.txt" || fail 'slurmctld exit status is not zero'
if grep -Eiq 'double free|corruption \(fasttop\)|SIGABRT|status=6/ABRT|core dumped' \
	"${run_dir}/old-process.journal" "${run_dir}/stop-unit.journal" \
	"${run_dir}/systemd-result.txt"; then
	fail 'ABRT or heap-corruption marker observed after patched stop'
fi
[ "$(systemctl is-active slurmdbd 2>/dev/null || true)" = active ] || \
	fail 'slurmdbd is not active after controller stop'
[ "$(systemctl is-active slurmd 2>/dev/null || true)" = active ] || \
	fail 'slurmd is not active after controller stop'

printf 'SMD405_OPENSSL_PATCHED_PRIMARY_STOP_PASS old_pid=%s stop_rc=%s service_state=%s process_absent=YES result=SUCCESS exit_status=0 sigabrt=NO fasttop=NO slurmdbd=ACTIVE slurmd=ACTIVE run_dir=%s\n' \
	"$old_pid" "$stop_rc" "$state" "$run_dir"
