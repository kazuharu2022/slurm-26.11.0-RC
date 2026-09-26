#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_GUEST_STAGE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_GUEST_STAGE_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

prefix=/usr/local/slurm/26.11.0
stage_prefix=/usr/local/slurm/.smd405-26.11.0-stage
prefix_archive=/tmp/smd405-slurm-prefix.tar
config_archive=/tmp/smd405-controller-config.tar
runtime_archive=/tmp/smd405-runtime-bundle.tar
key_input=/tmp/smd405-slurm.key
service_input=/tmp/smd405-slurmctld-backup.service
service_target=/etc/systemd/system/slurmctld.service
state=/var/spool/slurm/slurmctld
fstab_line='192.168.10.180:/var/spool/slurm/slurmctld /var/spool/slurm/slurmctld nfs4 rw,_netdev,hard,timeo=600,retrans=2,nofail 0 0'
hosts_line='192.168.10.180 ubuntu2504 # SMD-405 backup controller'
expected_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
expected_config=1e6c257b82aa82e507eb710a3e37690ffcfd7b402cb2b33fde53ed9bb1651c68
expected_cgroup=33b9420a8b181fcd3ccde6ea07383cd715aaaa543d7bd6bad0301c4298eb0d62
expected_gres=08d31ac718b61395b0a452bb6700c1143352357cf505b3791c0285f55f43f1d0
expected_key=70a580ae6b21d7ddc32f41e3959b024ea180e70e5a2244fb22774dcb45c55e7b
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/var/tmp/smd405-backup-stage-${run_stamp}
isolated_runtime=/run/slurmctld
isolated_runtime_created=0

fail()
{
	printf 'SMD405_GUEST_STAGE_FAILED error=%s run_dir=%s\n' "$1" "$run_dir" >&2
	exit 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	rm -f -- "$key_input" >/dev/null 2>&1 || true
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
[ "$(uname -m)" = x86_64 ] || fail 'unexpected guest architecture'
[ "$(cat /sys/class/net/enp1s0/address)" = 52:54:00:40:05:01 ] || \
	fail 'guest MAC mismatch'
ip -4 -o addr show dev enp1s0 | grep -q ' 192.168.10.118/24 ' || \
	fail 'reserved guest address is not active'
[ ! -e "$prefix" ] || fail 'target Slurm prefix already exists'
[ ! -e "$stage_prefix" ] || fail 'staging prefix already exists'
[ ! -e "$service_target" ] || fail 'slurmctld service already exists'
[ ! -e "$state" ] || fail 'state mountpoint already exists'
for path in "$prefix_archive" "$config_archive" "$runtime_archive" \
	"$key_input" "$service_input"; do
	[ -f "$path" ] || fail "missing staged input=$path"
done
[ "$(sha256sum "$key_input" | awk '{print $1}')" = "$expected_key" ] || \
	fail 'auth key hash mismatch'
[ "$(stat -c '%u:%g:%a' "$key_input")" = 0:0:600 ] || \
	fail 'auth key staging permissions mismatch'
if tar -tf "$prefix_archive" | grep -Eq '(^|/)etc(/|$)'; then
	fail 'prefix archive unexpectedly contains etc'
fi

mkdir -m 0755 "$run_dir"
trap cleanup EXIT HUP INT TERM
cp /etc/fstab "${run_dir}/fstab.before"
cp /etc/hosts "${run_dir}/hosts.before"
dpkg-query -W >"${run_dir}/packages.before" 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive
apt-get update >"${run_dir}/apt-update.out" 2>"${run_dir}/apt-update.err" || \
	fail 'apt update failed'
apt-get install -y --no-install-recommends nfs-common \
	>"${run_dir}/apt-install.out" 2>"${run_dir}/apt-install.err" || \
	fail 'nfs-common install failed'
command -v mount.nfs >/dev/null 2>&1 || fail 'mount.nfs is still absent'

[ -z "$(getent passwd 1002 || true)" ] || fail 'UID 1002 became occupied'
[ -z "$(getent group 1002 || true)" ] || fail 'GID 1002 became occupied'
[ -z "$(getent passwd 3001 || true)" ] || fail 'UID 3001 became occupied'
[ -z "$(getent group 3001 || true)" ] || fail 'GID 3001 became occupied'
groupadd --gid 1002 slurm
useradd --uid 1002 --gid 1002 --home-dir /var/lib/slurm \
	--create-home --shell /bin/bash slurm
groupadd --gid 3001 testuser
useradd --uid 3001 --gid 3001 --home-dir /home/testuser \
	--create-home --shell /bin/bash testuser

mkdir -p /usr/local/slurm
mkdir -m 0755 "$stage_prefix"
tar --numeric-owner -xpf "$prefix_archive" -C "$stage_prefix"
[ "$(sha256sum "${stage_prefix}/sbin/slurmctld" | awk '{print $1}')" = \
	"$expected_binary" ] || fail 'extracted controller binary hash mismatch'

mkdir -m 0755 "${stage_prefix}/etc"
tar -xpf "$config_archive" -C "${stage_prefix}/etc"
[ "$(sha256sum "${stage_prefix}/etc/slurm.conf" | awk '{print $1}')" = \
	"$expected_config" ] || fail 'primary config hash mismatch'
[ "$(sha256sum "${stage_prefix}/etc/cgroup.conf" | awk '{print $1}')" = \
	"$expected_cgroup" ] || fail 'cgroup config hash mismatch'
[ "$(sha256sum "${stage_prefix}/etc/gres.conf" | awk '{print $1}')" = \
	"$expected_gres" ] || fail 'GRES config hash mismatch'
mv "${stage_prefix}/etc/slurm.conf" \
	"${stage_prefix}/etc/slurm.conf.primary"
awk '
	/^SlurmctldHost=/ {
		if (!written) {
			print "SlurmctldHost=ubuntu2504(192.168.10.180)"
			print "SlurmctldHost=slurmctld-bak(192.168.10.118)"
			written=1
		}
		next
	}
	{ print }
	END { if (!written) exit 42 }
' "${stage_prefix}/etc/slurm.conf.primary" \
	>"${stage_prefix}/etc/slurm.conf" || fail 'candidate config generation failed'
[ "$(grep -c '^SlurmctldHost=' "${stage_prefix}/etc/slurm.conf")" -eq 2 ] || \
	fail 'candidate controller count mismatch'
chown slurm:slurm "${stage_prefix}/etc/slurm.conf" \
	"${stage_prefix}/etc/slurm.conf.primary" \
	"${stage_prefix}/etc/cgroup.conf"
chmod 0644 "${stage_prefix}/etc/slurm.conf" \
	"${stage_prefix}/etc/slurm.conf.primary" \
	"${stage_prefix}/etc/cgroup.conf" \
	"${stage_prefix}/etc/gres.conf"
install -o slurm -g slurm -m 0600 "$key_input" \
	"${stage_prefix}/etc/slurm.key"

mkdir -m 0755 "${stage_prefix}/lib/smd405-runtime"
tar -xpf "$runtime_archive" -C "${stage_prefix}/lib/smd405-runtime"
(cd "${stage_prefix}/lib/smd405-runtime" && \
	sha256sum -c runtime.sha256) >"${run_dir}/runtime-verify.txt" 2>&1 || \
	fail 'private runtime hash verification failed'
runtime_lib=${stage_prefix}/lib/smd405-runtime/lib
for soname in libjwt.so.2 libb64.so.0d libjansson.so.4 \
	libhttp_parser.so.2.9; do
	[ -f "${runtime_lib}/${soname}" ] || fail "runtime library absent=$soname"
done

mv "$stage_prefix" "$prefix"
stage_prefix=
runtime_lib=${prefix}/lib/smd405-runtime/lib
install -o root -g root -m 0644 "$service_input" "$service_target"
printf '%s\n' 'd /run/slurm 0755 slurm slurm -' \
	>/etc/tmpfiles.d/slurm-smd405.conf
chown root:root /etc/tmpfiles.d/slurm-smd405.conf
chmod 0644 /etc/tmpfiles.d/slurm-smd405.conf
systemd-tmpfiles --create /etc/tmpfiles.d/slurm-smd405.conf
install -d -o slurm -g slurm -m 0755 /var/log/slurm

if ! grep -Fqx "$hosts_line" /etc/hosts; then
	printf '%s\n' "$hosts_line" >>/etc/hosts
fi
getent ahostsv4 ubuntu2504 | awk '{print $1}' | grep -Fx 192.168.10.180 \
	>/dev/null || fail 'primary hostname alias failed'

install -d -o slurm -g slurm -m 0755 /var/spool/slurm
install -d -o slurm -g slurm -m 0755 "$state"
if ! grep -Fqx "$fstab_line" /etc/fstab; then
	printf '%s\n' "$fstab_line" >>/etc/fstab
fi
mount "$state" || fail 'shared state mount failed'
[ "$(findmnt -T "$state" -no FSTYPE)" = nfs4 ] || fail 'state is not NFSv4'
findmnt -T "$state" -no SOURCE | grep -F \
	'192.168.10.180:/var/spool/slurm/slurmctld' >/dev/null || \
	fail 'shared state source mismatch'
[ "$(stat -c '%u:%g:%a' "$state")" = 1002:1002:755 ] || \
	fail 'mounted state owner or mode mismatch'
su -s /bin/sh slurm -c "test -r '$state' -a -w '$state' -a -x '$state'" || \
	fail 'slurm user lacks shared state permissions'

systemctl daemon-reload
systemctl disable slurmctld >/dev/null 2>&1 || true
[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = inactive ] || \
	fail 'staged slurmctld service is active'
[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || \
	fail 'staged slurmctld service is enabled'

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
	"${prefix}/etc/slurm.key" "$service_target" \
	>"${run_dir}/installed.sha256"
findmnt -T "$state" -no SOURCE,FSTYPE,OPTIONS \
	>"${run_dir}/state-mount.txt"
stat -c '%n|%U:%G|%a|%s' "${prefix}/etc/slurm.key" \
	"$service_target" >"${run_dir}/installed-metadata.txt"
systemctl is-active slurmctld >"${run_dir}/service-active.txt" 2>&1 || true
systemctl is-enabled slurmctld >"${run_dir}/service-enabled.txt" 2>&1 || true
dpkg-query -W >"${run_dir}/packages.after" 2>/dev/null || true
chmod -R a+rX "$run_dir"

rm -f -- "$prefix_archive" "$config_archive" "$runtime_archive" \
	"$service_input"
rm -f -- "$key_input"
trap - EXIT HUP INT TERM
printf '%s\n' \
	'SMD405_GUEST_STAGE_COMPLETE' \
	"prefix=$prefix" \
	"config=${prefix}/etc/slurm.conf" \
	"state_mount=$state" \
	'service=disabled,inactive' \
	'isolated_controller=STARTUP_PASS_TERMINATED' \
	"run_dir=$run_dir"
