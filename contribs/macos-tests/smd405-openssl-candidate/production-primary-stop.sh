#!/bin/sh

# Stop only the original production primary slurmctld before requesting a
# direct takeover from the already-patched backup controller.

set -u
umask 077

if [ "${SMD405_OPENSSL_PRIMARY_STOP_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_OPENSSL_PRIMARY_STOP_CONFIRMED=YES after approving primary controller stop' >&2
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
run_dir=/var/tmp/smd405-openssl-primary-stop-${run_stamp}
expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
old_libslurmfull=81b9181f4564e1e506dba91796d7f1aa11daf687fa2178744088a3b3d64d96b5
old_auth_slurm=0bbd658e95d5fe82ce172e809f3af20472610f06ce8d33ac7213032c82ae6f79
old_auth_jwt=3b9d9a5078ba51d7b0197872e54828f0ddd7ed68bf9c982ce816814dd3b89812

fail()
{
	printf 'SMD405_OPENSSL_PRIMARY_STOP_FAILED error=%s run_dir=%s\n' "$1" "$run_dir" >&2
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
[ "$(file_hash "${prefix}/lib/slurm/libslurmfull.so")" = "$old_libslurmfull" ] || \
	fail 'primary libslurmfull is not original'
[ "$(file_hash "${prefix}/lib/slurm/auth_slurm.so")" = "$old_auth_slurm" ] || \
	fail 'primary auth_slurm is not original'
[ "$(file_hash "${prefix}/lib/slurm/auth_jwt.so")" = "$old_auth_jwt" ] || \
	fail 'primary auth_jwt is not original'
[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = active ] || \
	fail 'primary slurmctld is not active'
[ "$(systemctl is-active slurmdbd 2>/dev/null || true)" = active ] || \
	fail 'slurmdbd is not active'
[ "$(systemctl is-active slurmd 2>/dev/null || true)" = active ] || \
	fail 'slurmd is not active'

scontrol ping >"${run_dir}/before-ping.txt" 2>&1 || fail 'controller ping failed before stop'
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' "${run_dir}/before-ping.txt" || \
	fail 'primary is not UP before stop'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' "${run_dir}/before-ping.txt" || \
	fail 'patched backup is not UP before stop'
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
journalctl -u slurmctld --since "@${start_epoch}" --no-pager -o cat \
	>"${run_dir}/journal.txt" 2>&1 || true

state=$(systemctl is-active slurmctld 2>/dev/null || true)
case "$state" in inactive|failed) ;; *) fail 'primary slurmctld did not stop' ;; esac
pgrep -x slurmctld >/dev/null 2>&1 && fail 'primary slurmctld process remains after stop'

shutdown=NO_ABORT_MARKER
if grep -Eiq 'double free|corruption \(fasttop\)|SIGABRT|status=6/ABRT' \
	"${run_dir}/journal.txt"; then
	shutdown=ABRT_OBSERVED_AFTER_DIRECT_STOP
fi

printf 'SMD405_OPENSSL_PRIMARY_STOP_PASS old_pid=%s stop_rc=%s service_state=%s process_absent=YES shutdown=%s slurmdbd=ACTIVE slurmd=ACTIVE run_dir=%s\n' \
	"$old_pid" "$stop_rc" "$state" "$shutdown" "$run_dir"
