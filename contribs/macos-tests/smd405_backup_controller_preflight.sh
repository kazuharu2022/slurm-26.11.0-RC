#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -u

if [ "${SMD405_BACKUP_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_BACKUP_PREFLIGHT_CONFIRMED=YES after confirming this read-only preflight' >&2
	exit 64
fi

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

identity_file=${SMD405_IDENTITY_FILE:-/Users/REDACTED_USER/.ssh/id_ed25519}
primary=REDACTED_USER@192.168.10.180
guest=REDACTED_USER@192.168.10.118
expected_identity_fingerprint='SHA256:Va4B52U2du/kpndyUhPAAlKPcCYCvTu+Vl/9T3S740M'
expected_binary_sha256=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
expected_config_sha256=1e6c257b82aa82e507eb710a3e37690ffcfd7b402cb2b33fde53ed9bb1651c68
expected_auth_key_sha256=70a580ae6b21d7ddc32f41e3959b024ea180e70e5a2244fb22774dcb45c55e7b
expected_domain_uuid=603e9b61-d0cc-44b0-86ee-c2165d98698c
expected_mac=52:54:00:40:05:01
work_dir=

fail()
{
	printf 'SMD405_BACKUP_PREFLIGHT_FAILED error=%s\n' "$1" >&2
	exit 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	[ -n "$work_dir" ] && rm -rf -- "$work_dir" >/dev/null 2>&1 || true
	exit "$rc"
}

get_value()
{
	key=$1
	file=$2
	sed -n "s/^${key}=//p" "$file" | tail -n 1
}

assert_value()
{
	key=$1
	expected=$2
	file=$3
	actual=$(get_value "$key" "$file")
	[ "$actual" = "$expected" ] || \
		fail "$key mismatch expected=$expected actual=${actual:-missing}"
}

for command in ssh ssh-keygen mktemp sed tail grep awk; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command=$command"
done
[ -f "$identity_file" ] || fail 'SSH identity file is absent'
[ "$(ssh-keygen -lf "$identity_file" | awk '{print $2}')" = \
	"$expected_identity_fingerprint" ] || fail 'SSH identity fingerprint mismatch'

work_dir=$(mktemp -d /private/tmp/smd405-backup-preflight.XXXXXX) || \
	fail 'cannot create temporary work directory'
trap cleanup EXIT HUP INT TERM
known_hosts=${work_dir}/known_hosts
primary_before=${work_dir}/primary-before.txt
primary_after=${work_dir}/primary-after.txt
guest_report=${work_dir}/guest.txt

ssh -i "$identity_file" -o BatchMode=yes \
	-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known_hosts" \
	-o ConnectTimeout=10 "$primary" 'sudo -n sh -s' >"$primary_before" <<'PRIMARY'
set -eu
PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib
export PATH LD_LIBRARY_PATH

prefix=/usr/local/slurm/26.11.0
config=${prefix}/etc/slurm.conf
key=${prefix}/etc/slurm.key
state=/var/spool/slurm/slurmctld

printf 'host=%s\n' "$(hostname -s)"
. /etc/os-release
printf 'os_id=%s\n' "$ID"
printf 'os_version=%s\n' "$VERSION_ID"
printf 'arch=%s\n' "$(uname -m)"
printf 'glibc=%s\n' "$(ldd --version | awk 'NR == 1 {print $NF}')"
printf 'slurm_version=%s\n' "$(slurmctld -V | awk '{print $2}')"
printf 'slurmctld_sha256=%s\n' "$(sha256sum "${prefix}/sbin/slurmctld" | awk '{print $1}')"
printf 'config_sha256=%s\n' "$(sha256sum "$config" | awk '{print $1}')"
printf 'auth_key_sha256=%s\n' "$(sha256sum "$key" | awk '{print $1}')"
stat -c 'auth_key_owner=%U:%G' "$key"
stat -c 'auth_key_mode=%a' "$key"
stat -c 'auth_key_size=%s' "$key"
printf 'slurm_uid=%s\n' "$(id -u slurm)"
printf 'slurm_gid=%s\n' "$(id -g slurm)"
printf 'testuser_uid=%s\n' "$(id -u testuser)"
printf 'testuser_gid=%s\n' "$(id -g testuser)"
printf 'controller_entries=%s\n' "$(scontrol show config | grep -c '^[[:space:]]*SlurmctldHost\[')"
printf 'controller_0=%s\n' "$(scontrol show config | awk -F= '/^[[:space:]]*SlurmctldHost\[0\]/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')"
printf 'auth_type=%s\n' "$(scontrol show config | awk -F= '/^[[:space:]]*AuthType[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')"
printf 'cred_type=%s\n' "$(scontrol show config | awk -F= '/^[[:space:]]*CredType[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')"
printf 'auth_info=%s\n' "$(scontrol show config | awk -F= '/^[[:space:]]*AuthInfo[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')"
printf 'state_path=%s\n' "$state"
stat -c 'state_owner=%U:%G' "$state"
stat -c 'state_mode=%a' "$state"
printf 'state_fstype=%s\n' "$(findmnt -T "$state" -no FSTYPE)"
printf 'state_source=%s\n' "$(findmnt -T "$state" -no SOURCE)"
printf 'state_bytes=%s\n' "$(du -sb "$state" | awk '{print $1}')"
printf 'state_entries=%s\n' "$(find "$state" -mindepth 1 -maxdepth 1 -printf x | wc -c)"
if exportfs -v 2>/dev/null | grep -Fq "$state"; then
	printf '%s\n' 'state_exported=YES'
else
	printf '%s\n' 'state_exported=NO'
fi
if grep -Ev '^[[:space:]]*(#|$)' /etc/exports | grep -Eq '\*[[:space:]]*\([^)]*no_root_squash'; then
	printf '%s\n' 'existing_broad_nfs_export=YES'
else
	printf '%s\n' 'existing_broad_nfs_export=NO'
fi
printf 'nfs_server_active=%s\n' "$(systemctl is-active nfs-server 2>/dev/null || true)"
printf 'nfs_server_enabled=%s\n' "$(systemctl is-enabled nfs-server 2>/dev/null || true)"
if ss -lnt | grep -Eq ':(2049)[[:space:]]'; then
	printf '%s\n' 'nfs_port=LISTEN'
else
	printf '%s\n' 'nfs_port=NOT_LISTEN'
fi
if command -v virtiofsd >/dev/null 2>&1 ||
	find /usr/lib /usr/libexec -maxdepth 3 -type f -name virtiofsd -print -quit 2>/dev/null | grep -q .; then
	printf '%s\n' 'virtiofsd=PRESENT'
else
	printf '%s\n' 'virtiofsd=ABSENT'
fi
if getent ahostsv4 slurmctld-bak >/dev/null 2>&1; then
	printf '%s\n' 'backup_name_resolution=RESOLVED'
else
	printf '%s\n' 'backup_name_resolution=UNRESOLVED'
fi
printf 'slurmctld_pid=%s\n' "$(systemctl show -p MainPID --value slurmctld)"
printf 'slurmdbd_pid=%s\n' "$(systemctl show -p MainPID --value slurmdbd)"
printf 'slurmd_pid=%s\n' "$(systemctl show -p MainPID --value slurmd)"
printf 'service_states=%s\n' "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)"
scontrol ping | grep -q ' is UP$'
printf '%s\n' 'controller_ping=UP'
printf 'queue_count=%s\n' "$(squeue -h | wc -l)"
printf 'domain_uuid=%s\n' "$(virsh domuuid smd405-controller)"
printf 'domain_state=%s\n' "$(virsh domstate smd405-controller | tr -d '\r')"
printf 'domain_autostart=%s\n' "$(virsh dominfo smd405-controller | awk -F: '/^Autostart:/ {gsub(/^[[:space:]]+/, "", $2); print $2}')"
printf 'domain_mac=%s\n' "$(virsh domiflist smd405-controller --inactive | awk '$3 == "br0" {print tolower($5); exit}')"
PRIMARY
[ "$?" -eq 0 ] || fail 'primary read-only probe failed'

ssh -i "$identity_file" -o BatchMode=yes \
	-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known_hosts" \
	-o ConnectTimeout=10 "$guest" 'sudo -n sh -s' >"$guest_report" <<'GUEST'
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

printf 'host=%s\n' "$(hostname -s)"
. /etc/os-release
printf 'os_id=%s\n' "$ID"
printf 'os_version=%s\n' "$VERSION_ID"
printf 'arch=%s\n' "$(uname -m)"
printf 'glibc=%s\n' "$(ldd --version | awk 'NR == 1 {print $NF}')"
printf 'ipv4=%s\n' "$(ip -4 -o addr show dev enp1s0 | awk '{sub(/\/.*/, "", $4); print $4; exit}')"
printf 'mac=%s\n' "$(cat /sys/class/net/enp1s0/address)"
if ip -4 -o addr show dev enp1s0 | grep -q ' scope global dynamic '; then
	printf '%s\n' 'address_mode=DHCP'
else
	printf '%s\n' 'address_mode=NOT_DYNAMIC'
fi
if getent passwd 1002 >/dev/null 2>&1; then
	printf '%s\n' 'uid1002=OCCUPIED'
else
	printf '%s\n' 'uid1002=FREE'
fi
if getent group 1002 >/dev/null 2>&1; then
	printf '%s\n' 'gid1002=OCCUPIED'
else
	printf '%s\n' 'gid1002=FREE'
fi
if getent passwd 3001 >/dev/null 2>&1; then
	printf '%s\n' 'uid3001=OCCUPIED'
else
	printf '%s\n' 'uid3001=FREE'
fi
if getent group 3001 >/dev/null 2>&1; then
	printf '%s\n' 'gid3001=OCCUPIED'
else
	printf '%s\n' 'gid3001=FREE'
fi
printf 'nss_passwd=%s\n' "$(awk -F: '$1 == "passwd" {gsub(/^[[:space:]]+/, "", $2); print $2}' /etc/nsswitch.conf)"
printf 'nss_group=%s\n' "$(awk -F: '$1 == "group" {gsub(/^[[:space:]]+/, "", $2); print $2}' /etc/nsswitch.conf)"
for path in /usr/local/slurm/26.11.0 /usr/local/slurm/26.11.0/etc/slurm.key \
	/var/spool/slurm/slurmctld; do
	key=$(printf '%s' "$path" | tr '/' '_')
	if [ -e "$path" ]; then
		printf 'path%s=PRESENT\n' "$key"
	else
		printf 'path%s=ABSENT\n' "$key"
	fi
done
missing_tools=
for tool in gcc make pkg-config autoconf automake libtool; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		missing_tools="${missing_tools}${missing_tools:+,}${tool}"
	fi
done
printf 'missing_build_tools=%s\n' "$missing_tools"
missing_libs=
for soname in libjwt.so.2 libb64.so.0d libjansson.so.4 libhttp_parser.so.2.9 \
	libnuma.so.1; do
	if ! ldconfig -p | grep -Fq "$soname"; then
		missing_libs="${missing_libs}${missing_libs:+,}${soname}"
	fi
done
printf 'missing_runtime_libs=%s\n' "$missing_libs"
if command -v mount.nfs >/dev/null 2>&1; then
	printf '%s\n' 'nfs_client=PRESENT'
else
	printf '%s\n' 'nfs_client=ABSENT'
fi
if grep -Eq 'virtiofs\.ko' /lib/modules/"$(uname -r)"/modules.dep 2>/dev/null; then
	printf '%s\n' 'virtiofs_kernel=MODULE_PRESENT'
else
	printf '%s\n' 'virtiofs_kernel=NOT_CONFIRMED'
fi
if findmnt -rn -t nfs,nfs4,virtiofs | grep -q .; then
	printf '%s\n' 'shared_state_mount=PRESENT'
else
	printf '%s\n' 'shared_state_mount=ABSENT'
fi
if getent ahostsv4 ubuntu2504 >/dev/null 2>&1; then
	printf '%s\n' 'primary_name_resolution=RESOLVED'
else
	printf '%s\n' 'primary_name_resolution=UNRESOLVED'
fi
for port in 6817 6819 2049; do
	if timeout 2 bash -c "</dev/tcp/192.168.10.180/${port}" 2>/dev/null; then
		printf 'primary_port_%s=PASS\n' "$port"
	else
		printf 'primary_port_%s=FAIL\n' "$port"
	fi
done
printf 'ntp_synchronized=%s\n' "$(timedatectl show -p NTPSynchronized --value)"
printf 'ssh_socket=%s\n' "$(systemctl is-active ssh.socket),$(systemctl is-enabled ssh.socket)"
GUEST
[ "$?" -eq 0 ] || fail 'guest read-only probe failed'

ssh -i "$identity_file" -o BatchMode=yes \
	-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known_hosts" \
	-o ConnectTimeout=10 "$primary" 'sudo -n sh -s' >"$primary_after" <<'PRIMARY_AFTER'
set -eu
PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib
export PATH LD_LIBRARY_PATH
printf 'slurmctld_pid=%s\n' "$(systemctl show -p MainPID --value slurmctld)"
printf 'slurmdbd_pid=%s\n' "$(systemctl show -p MainPID --value slurmdbd)"
printf 'slurmd_pid=%s\n' "$(systemctl show -p MainPID --value slurmd)"
printf 'service_states=%s\n' "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)"
printf 'config_sha256=%s\n' "$(sha256sum /usr/local/slurm/26.11.0/etc/slurm.conf | awk '{print $1}')"
printf 'slurmctld_sha256=%s\n' "$(sha256sum /usr/local/slurm/26.11.0/sbin/slurmctld | awk '{print $1}')"
scontrol ping | grep -q ' is UP$'
printf '%s\n' 'controller_ping=UP'
printf 'queue_count=%s\n' "$(squeue -h | wc -l)"
PRIMARY_AFTER
[ "$?" -eq 0 ] || fail 'primary final readback failed'

assert_value host ubuntu2504 "$primary_before"
assert_value os_id ubuntu "$primary_before"
assert_value os_version 24.04 "$primary_before"
assert_value arch x86_64 "$primary_before"
assert_value glibc 2.39 "$primary_before"
assert_value slurm_version 26.11.0-0rc1 "$primary_before"
assert_value slurmctld_sha256 "$expected_binary_sha256" "$primary_before"
assert_value config_sha256 "$expected_config_sha256" "$primary_before"
assert_value auth_key_sha256 "$expected_auth_key_sha256" "$primary_before"
assert_value auth_key_owner slurm:slurm "$primary_before"
assert_value auth_key_mode 600 "$primary_before"
assert_value auth_key_size 1024 "$primary_before"
assert_value slurm_uid 1002 "$primary_before"
assert_value slurm_gid 1002 "$primary_before"
assert_value testuser_uid 3001 "$primary_before"
assert_value testuser_gid 3001 "$primary_before"
assert_value controller_entries 1 "$primary_before"
assert_value controller_0 ubuntu2504 "$primary_before"
assert_value auth_type auth/slurm "$primary_before"
assert_value cred_type cred/slurm "$primary_before"
assert_value auth_info '(null)' "$primary_before"
assert_value state_owner slurm:slurm "$primary_before"
assert_value state_mode 755 "$primary_before"
assert_value state_fstype xfs "$primary_before"
assert_value state_exported NO "$primary_before"
assert_value nfs_server_active active "$primary_before"
assert_value nfs_server_enabled enabled "$primary_before"
assert_value nfs_port LISTEN "$primary_before"
assert_value virtiofsd ABSENT "$primary_before"
assert_value backup_name_resolution UNRESOLVED "$primary_before"
assert_value service_states active,active,active "$primary_before"
assert_value controller_ping UP "$primary_before"
assert_value queue_count 0 "$primary_before"
assert_value domain_uuid "$expected_domain_uuid" "$primary_before"
assert_value domain_state running "$primary_before"
assert_value domain_autostart disable "$primary_before"
assert_value domain_mac "$expected_mac" "$primary_before"

assert_value host slurmctld-bak "$guest_report"
assert_value os_id ubuntu "$guest_report"
assert_value os_version 24.04 "$guest_report"
assert_value arch x86_64 "$guest_report"
assert_value glibc 2.39 "$guest_report"
assert_value ipv4 192.168.10.118 "$guest_report"
assert_value mac "$expected_mac" "$guest_report"
assert_value address_mode DHCP "$guest_report"
assert_value uid1002 FREE "$guest_report"
assert_value gid1002 FREE "$guest_report"
assert_value uid3001 FREE "$guest_report"
assert_value gid3001 FREE "$guest_report"
assert_value path_usr_local_slurm_26.11.0 ABSENT "$guest_report"
assert_value path_usr_local_slurm_26.11.0_etc_slurm.key ABSENT "$guest_report"
assert_value path_var_spool_slurm_slurmctld ABSENT "$guest_report"
assert_value missing_build_tools gcc,make,pkg-config,autoconf,automake,libtool "$guest_report"
assert_value missing_runtime_libs \
	libjwt.so.2,libb64.so.0d,libjansson.so.4,libhttp_parser.so.2.9 \
	"$guest_report"
assert_value nfs_client ABSENT "$guest_report"
assert_value virtiofs_kernel MODULE_PRESENT "$guest_report"
assert_value shared_state_mount ABSENT "$guest_report"
assert_value primary_name_resolution UNRESOLVED "$guest_report"
assert_value primary_port_6817 PASS "$guest_report"
assert_value primary_port_6819 PASS "$guest_report"
assert_value primary_port_2049 PASS "$guest_report"
assert_value ntp_synchronized yes "$guest_report"
assert_value ssh_socket active,enabled "$guest_report"

for key in slurmctld_pid slurmdbd_pid slurmd_pid service_states config_sha256 \
	slurmctld_sha256 controller_ping queue_count; do
	[ "$(get_value "$key" "$primary_before")" = \
		"$(get_value "$key" "$primary_after")" ] || \
		fail "production changed during preflight key=$key"
done

printf '%s\n' '--- primary readback ---'
grep -E '^(host|os_.*|arch|glibc|slurm_version|controller_entries|controller_0|auth_type|cred_type|auth_info|slurm_uid|slurm_gid|testuser_uid|testuser_gid|state_.*|nfs_.*|virtiofsd|backup_name_resolution|service_states|controller_ping|queue_count|domain_.*)=' "$primary_before"
printf '%s\n' '--- backup VM readback ---'
grep -E '^(host|os_.*|arch|glibc|ipv4|mac|address_mode|uid.*|gid.*|nss_.*|path_.*|missing_.*|nfs_client|virtiofs_kernel|shared_state_mount|primary_name_resolution|primary_port_.*|ntp_synchronized|ssh_socket)=' "$guest_report"
printf '%s\n' \
	'binary_abi=BASE_OS_COMPATIBLE_RUNTIME_LIBRARIES_MISSING' \
	'authentication=AUTH_SLURM_KEY_REQUIRED_MUNGE_NOT_REQUIRED' \
	'identity=SLURM_AND_TESTUSER_UID_GID_CREATION_REQUIRED' \
	'user_namespace=INCOMPLETE_ON_BACKUP' \
	'shared_state=ABSENT_PRIMARY_LOCAL_XFS' \
	'addressing=DHCP_RESERVATION_OR_STATIC_ADDRESS_REQUIRED' \
	'name_resolution=EXPLICIT_SLURMCTLDHOST_ADDRESSES_REQUIRED' \
	'architecture_scope=FUNCTIONAL_FAILOVER_ONLY_SAME_HYPERVISOR' \
	'next_change=APPROVAL_REQUIRED'
printf '%s\n' \
	'SMD405_BACKUP_PREFLIGHT_COMPLETE result=BLOCKED_CHANGE_APPROVAL_REQUIRED production_unchanged=PASS'
