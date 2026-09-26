#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_GUEST_VERIFY_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_GUEST_VERIFY_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

prefix=/usr/local/slurm/26.11.0
runtime_root=${prefix}/lib/smd405-runtime
runtime_lib=${runtime_root}/lib
state=/var/spool/slurm/slurmctld
service=/etc/systemd/system/slurmctld.service
expected_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
expected_primary_config=1e6c257b82aa82e507eb710a3e37690ffcfd7b402cb2b33fde53ed9bb1651c68
expected_key=70a580ae6b21d7ddc32f41e3959b024ea180e70e5a2244fb22774dcb45c55e7b
expected_service=46e930ee24695791d809498254092516c5efde38d136fe781172766db71bf9d2
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/var/tmp/smd405-backup-verify-${run_stamp}
isolated_runtime=/run/slurmctld
isolated_runtime_created=0

fail()
{
	printf 'SMD405_GUEST_VERIFY_FAILED error=%s run_dir=%s\n' "$1" "$run_dir" >&2
	exit 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$isolated_runtime_created" -eq 1 ]; then
		[ -S "${isolated_runtime}/sack.socket" ] && \
			rm -f -- "${isolated_runtime}/sack.socket" || true
		rmdir "$isolated_runtime" >/dev/null 2>&1 || true
	fi
	[ -d "$run_dir" ] && chmod -R a+rX "$run_dir" >/dev/null 2>&1 || true
	exit "$rc"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(hostname -s)" = slurmctld-bak ] || fail 'unexpected guest hostname'
[ "$(cat /sys/class/net/enp1s0/address)" = 52:54:00:40:05:01 ] || \
	fail 'guest MAC mismatch'
ip -4 -o addr show dev enp1s0 | grep -q ' 192.168.10.118/24 ' || \
	fail 'reserved guest address is not active'
[ "$(id -u slurm):$(id -g slurm)" = 1002:1002 ] || fail 'slurm identity mismatch'
[ "$(id -u testuser):$(id -g testuser)" = 3001:3001 ] || \
	fail 'testuser identity mismatch'
[ "$(sha256sum "${prefix}/sbin/slurmctld" | awk '{print $1}')" = \
	"$expected_binary" ] || fail 'controller binary hash mismatch'
[ "$(sha256sum "${prefix}/etc/slurm.conf.primary" | awk '{print $1}')" = \
	"$expected_primary_config" ] || fail 'primary config copy hash mismatch'
[ "$(sha256sum "${prefix}/etc/slurm.key" | awk '{print $1}')" = \
	"$expected_key" ] || fail 'auth key hash mismatch'
[ "$(stat -c '%U:%G:%a:%s' "${prefix}/etc/slurm.key")" = \
	slurm:slurm:600:1024 ] || fail 'auth key metadata mismatch'
[ "$(sha256sum "$service" | awk '{print $1}')" = "$expected_service" ] || \
	fail 'service unit hash mismatch'
[ "$(grep -c '^SlurmctldHost=' "${prefix}/etc/slurm.conf")" -eq 2 ] || \
	fail 'candidate controller count mismatch'
grep -Fx 'SlurmctldHost=ubuntu2504(192.168.10.180)' \
	"${prefix}/etc/slurm.conf" >/dev/null || fail 'primary controller entry mismatch'
grep -Fx 'SlurmctldHost=slurmctld-bak(192.168.10.118)' \
	"${prefix}/etc/slurm.conf" >/dev/null || fail 'backup controller entry mismatch'
[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = inactive ] || \
	fail 'staged slurmctld service is active'
[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || \
	fail 'staged slurmctld service is enabled'
[ "$(findmnt -T "$state" -no FSTYPE)" = nfs4 ] || fail 'state is not NFSv4'
findmnt -T "$state" -no SOURCE | grep -F \
	'192.168.10.180:/var/spool/slurm/slurmctld' >/dev/null || \
	fail 'shared state source mismatch'
[ "$(stat -c '%u:%g:%a' "$state")" = 1002:1002:755 ] || \
	fail 'mounted state owner or mode mismatch'
su -s /bin/sh slurm -c "test -r '$state' -a -w '$state' -a -x '$state'" || \
	fail 'slurm user lacks shared state permissions'

mkdir -m 0755 "$run_dir"
trap cleanup EXIT HUP INT TERM
(cd "$runtime_root" && sha256sum -c runtime.sha256) \
	>"${run_dir}/runtime-verify.txt" 2>&1 || fail 'private runtime hash mismatch'

LD_LIBRARY_PATH=${runtime_lib}:${prefix}/lib
export LD_LIBRARY_PATH
"${prefix}/sbin/slurmctld" -V >"${run_dir}/slurmctld-version.txt" 2>&1 || \
	fail 'controller version probe failed'
grep -F 'slurm 26.11.0-0rc1' "${run_dir}/slurmctld-version.txt" \
	>/dev/null || fail 'controller version mismatch'
for object in "${prefix}/sbin/slurmctld" \
	"${prefix}/lib/slurm/auth_slurm.so" \
	"${prefix}/lib/slurm/accounting_storage_slurmdbd.so" \
	"${prefix}/lib/slurm/select_cons_tres.so"; do
	ldd "$object" || fail "ldd failed=$object"
done >"${run_dir}/runtime-ldd.txt" 2>&1
if grep -Fq 'not found' "${run_dir}/runtime-ldd.txt"; then
	fail 'staged runtime dependency is missing'
fi

validation=${run_dir}/isolated
validation_state=${validation}/state
mkdir -p "$validation_state"
chown -R slurm:slurm "$validation"
chmod 0755 "$validation" "$validation_state"
install -o slurm -g slurm -m 0600 "${prefix}/etc/slurm.key" \
	"${validation}/slurm.key"
install -o slurm -g slurm -m 0644 "${prefix}/etc/cgroup.conf" \
	"${validation}/cgroup.conf"
awk -v state="$validation_state" -v root="$validation" '
	/^ClusterName=/ {
		print "ClusterName=smd405-validate"
		print "MailProg=/bin/true"
		next
	}
	/^SlurmctldHost=/ {
		if (!host_written) {
			print "SlurmctldHost=slurmctld-bak"
			print "SlurmctldAddr=127.0.0.1"
			host_written=1
		}
		next
	}
	/^SlurmctldPidFile=/ { print "SlurmctldPidFile=" root "/slurmctld.pid"; next }
	/^SlurmctldPort=/ { print "SlurmctldPort=16817"; next }
	/^SlurmdPidFile=/ { print "SlurmdPidFile=" root "/slurmd.pid"; next }
	/^SlurmdPort=/ { print "SlurmdPort=16818"; next }
	/^StateSaveLocation=/ { print "StateSaveLocation=" state; next }
	/^AccountingStorageHost=/ { next }
	/^AccountingStoragePort=/ { next }
	/^AccountingStorageType=/ { print "AccountingStorageType=accounting_storage/none"; next }
	/^AccountingStorageTRES=/ { next }
	/^JobAcctGatherType=/ { print "JobAcctGatherType=jobacct_gather/none"; next }
	/^GresTypes=/ { next }
	/^SlurmctldParameters=/ { next }
	/^NodeName=/ { next }
	/^PartitionName=/ { next }
	/^SlurmctldLogFile=/ { print "SlurmctldLogFile=" root "/slurmctld.log"; next }
	/^SlurmdLogFile=/ { print "SlurmdLogFile=" root "/slurmd.log"; next }
	{ print }
	END {
		print "NodeName=validate NodeAddr=127.0.0.1 CPUs=1 State=FUTURE"
		print "PartitionName=validate Nodes=validate Default=YES State=UP"
	}
' "${prefix}/etc/slurm.conf" >"${validation}/slurm.conf"
chown slurm:slurm "${validation}/slurm.conf"
chmod 0644 "${validation}/slurm.conf"

[ ! -e "$isolated_runtime" ] || fail 'isolated runtime directory already exists'
install -d -o slurm -g slurm -m 0755 "$isolated_runtime"
isolated_runtime_created=1
set +e
su -s /bin/sh slurm -c \
	"LD_LIBRARY_PATH='$LD_LIBRARY_PATH' timeout --signal=TERM 8 '${prefix}/sbin/slurmctld' -D -c -f '${validation}/slurm.conf'" \
	>"${validation}/stdout.txt" 2>"${validation}/stderr.txt"
validation_rc=$?
set -e
printf '%s\n' "$validation_rc" >"${validation}/rc.txt"
[ "$validation_rc" -eq 124 ] || fail "isolated controller exited unexpectedly rc=$validation_rc"
grep -Ei 'slurmctld version .* started|slurmctld.*started' \
	"${validation}/stdout.txt" "${validation}/stderr.txt" \
	>"${validation}/startup-marker.txt" || fail 'isolated startup marker absent'
if grep -Ei '\] (fatal|error):' "${validation}/stdout.txt" \
	"${validation}/stderr.txt" >"${validation}/unexpected-errors.txt"; then
	fail 'isolated controller emitted fatal or error'
fi
[ ! -e "${validation}/slurmctld.pid" ] || fail 'isolated controller PID file remains'
if pgrep -f "${prefix}/sbin/slurmctld.*${validation}/slurm.conf" \
	>"${validation}/remaining-process.txt"; then
	fail 'isolated controller process remains'
fi
[ -S "${isolated_runtime}/sack.socket" ] && \
	rm -f -- "${isolated_runtime}/sack.socket" || true
rmdir "$isolated_runtime" || fail 'isolated runtime directory is not empty'
isolated_runtime_created=0

sha256sum "${prefix}/sbin/slurmctld" \
	"${prefix}/etc/slurm.conf.primary" "${prefix}/etc/slurm.conf" \
	"${prefix}/etc/slurm.key" "$service" >"${run_dir}/installed.sha256"
findmnt -T "$state" -no SOURCE,FSTYPE,OPTIONS >"${run_dir}/state-mount.txt"
stat -c '%n|%U:%G|%a|%s' "${prefix}/etc/slurm.key" "$service" \
	>"${run_dir}/installed-metadata.txt"
systemctl is-active slurmctld >"${run_dir}/service-active.txt" 2>&1 || true
systemctl is-enabled slurmctld >"${run_dir}/service-enabled.txt" 2>&1 || true
chmod -R a+rX "$run_dir"

trap - EXIT HUP INT TERM
printf '%s\n' \
	'SMD405_GUEST_VERIFY_COMPLETE' \
	'runtime_linkage=PASS' \
	'shared_state_mount=PASS_PERMISSION_ONLY_NO_WRITE_PROBE' \
	'service=disabled,inactive' \
	'isolated_controller=STARTUP_PASS_TERMINATED' \
	"run_dir=$run_dir"
