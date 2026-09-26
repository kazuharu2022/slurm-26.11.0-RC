#!/bin/sh

# Promote the already-patched production backup only after the original
# primary slurmctld has been stopped and is no longer reachable.

set -u
umask 077

if [ "${SMD405_OPENSSL_BACKUP_PROMOTION_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_OPENSSL_BACKUP_PROMOTION_CONFIRMED=YES after approving primary handoff' >&2
	exit 64
fi

PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib/slurm:/usr/local/slurm/26.11.0/lib:/usr/local/slurm/26.11.0/lib/smd405-runtime/lib
SLURM_CONF=/usr/local/slurm/26.11.0/etc/slurm.conf
export PATH LD_LIBRARY_PATH SLURM_CONF

run_stamp=${RUN_STAMP:-}
case "$run_stamp" in
''|*[!0-9T]*) printf 'error: invalid RUN_STAMP=%s\n' "$run_stamp" >&2; exit 64 ;;
esac

[ "$(hostname -s)" = slurmctld-bak ] || {
	printf 'error: unexpected hostname=%s\n' "$(hostname -s)" >&2
	exit 64
}
[ "$(id -u)" -eq 0 ] || {
	printf '%s\n' 'error: must run as root' >&2
	exit 64
}

prefix=/usr/local/slurm/26.11.0
run_dir=/var/tmp/smd405-openssl-backup-promote-${run_stamp}
expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
new_libslurmfull=791fa00eff4b949cfbb667fc250fc9b40e2e096f7494ad0d763138d62fea9391
new_auth_slurm=536b07689bedad94cc8e663682b85db0d4e42391a86cc499e4f5895247ff3ee9
new_auth_jwt=686057ecdca7c6476ddf44fefdb3b90014bf208fde39e759f2cf0c55e15f7167

fail()
{
	printf 'SMD405_OPENSSL_BACKUP_PROMOTION_FAILED error=%s run_dir=%s\n' \
		"$1" "$run_dir" >&2
	exit 1
}

file_hash()
{
	sha256sum "$1" | awk '{print $1}'
}

[ ! -e "$run_dir" ] || fail 'run directory already exists'
install -d -o root -g root -m 0700 "$run_dir" || fail 'cannot create run directory'
[ "$(file_hash "${prefix}/etc/slurm.conf")" = "$expected_config" ] || \
	fail 'production config hash mismatch'
[ "$(file_hash "${prefix}/sbin/slurmctld")" = "$expected_binary" ] || \
	fail 'production slurmctld hash mismatch'
[ "$(file_hash "${prefix}/lib/slurm/libslurmfull.so")" = "$new_libslurmfull" ] || \
	fail 'backup libslurmfull is not candidate'
[ "$(file_hash "${prefix}/lib/slurm/auth_slurm.so")" = "$new_auth_slurm" ] || \
	fail 'backup auth_slurm is not candidate'
[ "$(file_hash "${prefix}/lib/slurm/auth_jwt.so")" = "$new_auth_jwt" ] || \
	fail 'backup auth_jwt is not candidate'
[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = active ] || \
	fail 'backup slurmctld is not active'
[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || \
	fail 'backup slurmctld is not disabled for boot'

scontrol ping >"${run_dir}/before-ping.txt" 2>&1 || true
grep -Fq 'Slurmctld(primary) at ubuntu2504 is DOWN' "${run_dir}/before-ping.txt" || \
	fail 'primary must be DOWN before backup promotion'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' "${run_dir}/before-ping.txt" || \
	fail 'backup is not reachable before promotion'

promoted=0
backup_pid=$(systemctl show -p MainPID --value slurmctld)
[ "$backup_pid" -gt 1 ] || fail 'backup slurmctld MainPID is invalid'
scontrol takeover 1 >"${run_dir}/takeover.txt" 2>&1 || fail 'takeover request failed'
attempt=0
while [ "$attempt" -lt 60 ]; do
	attempt=$((attempt + 1))
	journalctl -u slurmctld "_PID=${backup_pid}" --no-pager -o cat \
		>"${run_dir}/journal.txt" 2>&1 || true
	if grep -Fq 'Running as primary controller' "${run_dir}/journal.txt" && \
		[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = active ]; then
		promoted=1
		break
	fi
	sleep 1
done
[ "$promoted" -eq 1 ] || fail 'backup did not enter primary-controller role'

scontrol ping >"${run_dir}/after-ping.txt" 2>&1 || true
grep -Fq 'Slurmctld(primary) at ubuntu2504 is DOWN' "${run_dir}/after-ping.txt" || \
	fail 'original primary unexpectedly became reachable'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' "${run_dir}/after-ping.txt" || \
	fail 'promoted backup is not reachable'
[ -z "$(squeue -h)" ] || fail 'queue changed during promotion'
for node in ubuntu PC-210; do
	node_output=$(scontrol show node "$node") || fail "cannot inspect node=${node}"
	printf '%s\n' "$node_output" | grep -Eq \
		'(^|[[:space:]])State=IDLE([[:space:]]|$)' || fail "node is not IDLE node=${node}"
	printf '%s\n' "$node_output" | grep -Eq \
		'(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' || fail "node is allocated node=${node}"
done

printf 'SMD405_OPENSSL_BACKUP_PROMOTION_PASS pid=%s role=PRIMARY takeover_action=%s original_primary=DOWN queue=EMPTY nodes=IDLE run_dir=%s\n' \
	"$backup_pid" REQUEST_SENT_OR_ALREADY_PRIMARY "$run_dir"
