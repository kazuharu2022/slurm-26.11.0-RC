#!/bin/sh

# Restart the patched primary after the backup has assumed control, then prove
# controller failback, daemon mappings, accounting, queue, and node health.

set -u
umask 077

if [ "${SMD405_OPENSSL_PATCHED_PRIMARY_RESUME_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_OPENSSL_PATCHED_PRIMARY_RESUME_CONFIRMED=YES after approving primary restart' >&2
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
run_dir=/var/tmp/smd405-openssl-patched-primary-resume-${run_stamp}
expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
new_libslurmfull=791fa00eff4b949cfbb667fc250fc9b40e2e096f7494ad0d763138d62fea9391
new_auth_slurm=536b07689bedad94cc8e663682b85db0d4e42391a86cc499e4f5895247ff3ee9
new_auth_jwt=686057ecdca7c6476ddf44fefdb3b90014bf208fde39e759f2cf0c55e15f7167

fail()
{
	printf 'SMD405_OPENSSL_PATCHED_PRIMARY_RESUME_FAILED error=%s run_dir=%s\n' "$1" "$run_dir" >&2
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
state=$(systemctl is-active slurmctld 2>/dev/null || true)
case "$state" in inactive|failed) ;; *) fail 'primary slurmctld must be stopped before resume' ;; esac
pgrep -x slurmctld >/dev/null 2>&1 && fail 'a slurmctld process remains before resume'
[ "$(systemctl is-active slurmdbd 2>/dev/null || true)" = active ] || \
	fail 'slurmdbd is not active before resume'
[ "$(systemctl is-active slurmd 2>/dev/null || true)" = active ] || \
	fail 'slurmd is not active before resume'

scontrol ping >"${run_dir}/before-ping.txt" 2>&1 || true
grep -Fq 'Slurmctld(primary) at ubuntu2504 is DOWN' "${run_dir}/before-ping.txt" || \
	fail 'original primary is not reported DOWN before resume'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' "${run_dir}/before-ping.txt" || \
	fail 'promoted backup is not reachable before resume'
[ -z "$(squeue -h)" ] || fail 'queue is not empty before resume'

start_epoch=$(date +%s)
systemctl start slurmctld || fail 'cannot start patched primary slurmctld'
ready=0
attempt=0
while [ "$attempt" -lt 90 ]; do
	attempt=$((attempt + 1))
	scontrol ping >"${run_dir}/after-ping.txt" 2>&1 || true
	if grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' "${run_dir}/after-ping.txt" && \
		grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' "${run_dir}/after-ping.txt"; then
		ready=1
		break
	fi
	sleep 1
done
[ "$ready" -eq 1 ] || fail 'both controllers did not become ready after primary resume'
[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = active ] || \
	fail 'primary slurmctld is not active after resume'
verify_loaded_artifact lib/slurm/libslurmfull.so || \
	fail 'resumed slurmctld does not map current fixed libslurmfull'
verify_loaded_artifact lib/slurm/auth_slurm.so || \
	fail 'resumed slurmctld does not map current fixed auth_slurm'
[ -z "$(squeue -h)" ] || fail 'queue is not empty after resume'
for node in ubuntu PC-210; do
	node_output=$(scontrol show node "$node") || fail "cannot inspect node=${node}"
	printf '%s\n' "$node_output" | grep -Eq \
		'(^|[[:space:]])State=IDLE([[:space:]]|$)' || fail "node is not IDLE node=${node}"
	printf '%s\n' "$node_output" | grep -Eq \
		'(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' || fail "node is allocated node=${node}"
done
sacctmgr ping >"${run_dir}/slurmdbd-ping.txt" 2>&1 || fail 'slurmdbd ping failed'
grep -Fq ' is UP' "${run_dir}/slurmdbd-ping.txt" || fail 'slurmdbd is not UP'
journalctl -u slurmctld --since "@${start_epoch}" --no-pager -o cat \
	>"${run_dir}/restart.journal" 2>&1 || fail 'cannot read restart journal'
if grep -Eiq 'double free|corruption \(fasttop\)|SIGABRT|status=6/ABRT|core dumped' \
	"${run_dir}/restart.journal"; then
	fail 'ABRT marker observed during patched primary resume'
fi

printf 'SMD405_OPENSSL_PATCHED_PRIMARY_RESUME_PASS pid=%s artifacts=FIXED_THREE mapped=CURRENT_INODES controllers=BOTH_UP slurmdbd=UP queue=EMPTY nodes=IDLE restart_abrt=NONE run_dir=%s\n' \
	"$(systemctl show -p MainPID --value slurmctld)" "$run_dir"
