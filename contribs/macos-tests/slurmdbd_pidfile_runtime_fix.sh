#!/bin/sh

set -eu

prefix=/usr/local/slurm/26.11.0
conf=${prefix}/etc/slurmdbd.conf
unit=/etc/systemd/system/slurmdbd.service
old_pidfile=/var/run/slurm/slurmdbd.pid
new_pidfile=/run/slurmdbd/slurmdbd.pid
service=slurmdbd
controller=slurmctld
node=PC-210
expected_conf_sha256=${SLURMDBD_EXPECTED_CONF_SHA256:-}
expected_unit_sha256=${SLURMDBD_EXPECTED_UNIT_SHA256:-}
stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/var/tmp/slurmdbd-pidfile-fix-${stamp}
backup=${run_dir}/slurmdbd.conf.before
candidate=${run_dir}/slurmdbd.conf.candidate
readback=${run_dir}/readback.txt
mutated=0

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

restore_on_failure()
{
	rc=$?
	if [ "$rc" -ne 0 ] && [ "$mutated" -eq 1 ] && [ -f "$backup" ]; then
		printf 'recovery: restoring original slurmdbd.conf\n' >&2
		/usr/bin/install -o slurm -g slurm -m 0640 "$backup" "${conf}.restore"
		/bin/mv -f "${conf}.restore" "$conf"
		/bin/systemctl restart "$service" || true
		printf 'recovery: restore attempted; inspect run_dir=%s\n' "$run_dir" >&2
	fi
	exit "$rc"
}

[ "${SLURMDBD_PIDFILE_FIX_CONFIRMED:-NO}" = YES ] || {
	printf 'error: set SLURMDBD_PIDFILE_FIX_CONFIRMED=YES\n' >&2
	exit 64
}
[ "$(/usr/bin/id -u)" -eq 0 ] || {
	printf 'error: run as root on the Ubuntu controller\n' >&2
	exit 77
}
[ "$(/usr/bin/uname -s)" = Linux ] || fail 'this fix must run on Linux'
[ -n "$expected_conf_sha256" ] || fail 'missing expected config hash'
[ -n "$expected_unit_sha256" ] || fail 'missing expected unit hash'

for path in "$conf" "$unit" "${prefix}/bin/scontrol" "${prefix}/bin/squeue" \
	"${prefix}/bin/sacctmgr" /bin/systemctl /usr/bin/install /usr/bin/sha256sum; do
	[ -e "$path" ] || fail "missing required path: $path"
done

actual_conf_sha256=$(/usr/bin/sha256sum "$conf" | /usr/bin/awk '{ print $1 }')
actual_unit_sha256=$(/usr/bin/sha256sum "$unit" | /usr/bin/awk '{ print $1 }')
[ "$actual_conf_sha256" = "$expected_conf_sha256" ] || \
	fail "config hash mismatch: $actual_conf_sha256"
[ "$actual_unit_sha256" = "$expected_unit_sha256" ] || \
	fail "unit hash mismatch: $actual_unit_sha256"

[ "$(/bin/systemctl is-active "$service")" = active ] || fail 'slurmdbd is not active'
[ "$(/bin/systemctl is-active "$controller")" = active ] || fail 'slurmctld is not active'
[ "$(/bin/systemctl show "$service" -p User --value)" = slurm ] || fail 'unexpected service user'
[ "$(/bin/systemctl show "$service" -p Group --value)" = slurm ] || fail 'unexpected service group'
[ "$(/bin/systemctl show "$service" -p RuntimeDirectory --value)" = slurmdbd ] || \
	fail 'unexpected RuntimeDirectory'
[ "$(/usr/bin/stat -c '%U:%G:%a' /run/slurmdbd)" = slurm:slurm:755 ] || \
	fail 'unexpected /run/slurmdbd ownership or mode'

"${prefix}/bin/scontrol" ping | /bin/grep -q ' is UP$' || fail 'controller ping failed'
"${prefix}/bin/scontrol" show node "$node" >"${run_dir}.node" 2>/dev/null || \
	fail 'node readback failed'
/bin/grep -q 'State=IDLE' "${run_dir}.node" || fail 'PC-210 is not IDLE'
/bin/grep -q 'CPUAlloc=0' "${run_dir}.node" || fail 'PC-210 CPU allocation is not zero'
/bin/grep -q 'AllocMem=0' "${run_dir}.node" || fail 'PC-210 memory allocation is not zero'
[ -z "$("${prefix}/bin/squeue" -h)" ] || fail 'queue is not empty'
/bin/rm -f "${run_dir}.node"

[ "$(/bin/grep -Fxc "PidFile=${old_pidfile}" "$conf")" -eq 1 ] || \
	fail 'expected old PidFile line is not unique'
[ ! -e "$new_pidfile" ] || fail "target PID file already exists: $new_pidfile"

/bin/mkdir -m 0700 "$run_dir"
/usr/bin/install -o root -g root -m 0600 "$conf" "$backup"
/bin/sed "s#^PidFile=${old_pidfile}\$#PidFile=${new_pidfile}#" "$conf" >"$candidate"
[ "$(/bin/grep -Fxc "PidFile=${new_pidfile}" "$candidate")" -eq 1 ] || \
	fail 'candidate PidFile replacement failed'
[ "$(/bin/grep -Fxc "PidFile=${old_pidfile}" "$candidate")" -eq 0 ] || \
	fail 'candidate retained old PidFile line'

start_epoch=$(/bin/date '+%s')
trap restore_on_failure EXIT HUP INT TERM
/usr/bin/install -o slurm -g slurm -m 0640 "$candidate" "${conf}.new"
/bin/mv -f "${conf}.new" "$conf"
mutated=1
/bin/systemctl restart "$service"

attempt=0
while [ "$attempt" -lt 30 ]; do
	main_pid=$(/bin/systemctl show "$service" -p MainPID --value)
	if [ "$(/bin/systemctl is-active "$service" 2>/dev/null || true)" = active ] && \
	   [ -f "$new_pidfile" ] && [ "$(/bin/cat "$new_pidfile")" = "$main_pid" ]; then
		break
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
[ "$attempt" -lt 30 ] || fail 'slurmdbd did not return with a matching PID file'

new_conf_sha256=$(/usr/bin/sha256sum "$conf" | /usr/bin/awk '{ print $1 }')
[ "$(/usr/bin/stat -c '%U:%G:%a' "$conf")" = slurm:slurm:640 ] || \
	fail 'slurmdbd.conf metadata changed unexpectedly'
[ "$(/usr/bin/stat -c '%U:%G' "$new_pidfile")" = slurm:slurm ] || \
	fail 'new PID file ownership mismatch'
/bin/kill -0 "$main_pid" || fail 'slurmdbd MainPID is not alive'
"${prefix}/bin/sacctmgr" -nP show cluster >"${run_dir}/sacctmgr-cluster.txt" || \
	fail 'accounting database read failed'
[ -s "${run_dir}/sacctmgr-cluster.txt" ] || fail 'accounting database read was empty'
"${prefix}/bin/scontrol" ping >"${run_dir}/controller-ping.txt" || fail 'controller ping failed after restart'
"${prefix}/bin/scontrol" show node "$node" >"${run_dir}/node-after.txt" || fail 'node readback failed after restart'
[ -z "$("${prefix}/bin/squeue" -h)" ] || fail 'queue is not empty after restart'

/bin/journalctl -u "$service" --since "@${start_epoch}" --no-pager >"${run_dir}/journal.txt"
if /bin/grep -F 'Unable to open pidfile' "${run_dir}/journal.txt" >/dev/null; then
	fail 'PID file error remained after restart'
fi

{
	printf 'SLURMDBD_PIDFILE_FIX_PASS\n'
	printf 'config_before_sha256=%s\n' "$actual_conf_sha256"
	printf 'config_after_sha256=%s\n' "$new_conf_sha256"
	printf 'unit_sha256=%s\n' "$actual_unit_sha256"
	printf 'pidfile=%s\n' "$new_pidfile"
	printf 'pidfile_identity=%s\n' "$(/usr/bin/stat -c '%U:%G:%a' "$new_pidfile")"
	printf 'main_pid=%s\n' "$main_pid"
	printf 'accounting_read=PASS\n'
	printf 'controller_ping=PASS\n'
	printf 'queue=EMPTY\n'
	printf 'run_dir=%s\n' "$run_dir"
} | /usr/bin/tee "$readback"

mutated=0
trap - EXIT HUP INT TERM
