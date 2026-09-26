#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_PRIMARY_EXPORT_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_PRIMARY_EXPORT_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib
export PATH LD_LIBRARY_PATH

export_dir=/etc/exports.d
export_file=${export_dir}/smd405-slurmctld.exports
state=/var/spool/slurm/slurmctld
expected_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
expected_config=1e6c257b82aa82e507eb710a3e37690ffcfd7b402cb2b33fde53ed9bb1651c68
expected_line='/var/spool/slurm/slurmctld 192.168.10.118(rw,sync,root_squash,no_subtree_check)'
temporary=
installed=0
export_dir_created=0

fail()
{
	printf 'SMD405_PRIMARY_EXPORT_FAILED error=%s\n' "$1" >&2
	exit 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	[ -n "$temporary" ] && rm -f -- "$temporary" >/dev/null 2>&1 || true
	if [ "$rc" -ne 0 ] && [ "$installed" -eq 1 ] && \
		[ -f "$export_file" ] && \
		[ "$(cat "$export_file")" = "$expected_line" ]; then
		rm -f -- "$export_file"
		exportfs -ra >/dev/null 2>&1 || true
	fi
	if [ "$rc" -ne 0 ] && [ "$export_dir_created" -eq 1 ]; then
		rmdir "$export_dir" >/dev/null 2>&1 || true
	fi
	exit "$rc"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(hostname -s)" = ubuntu2504 ] || fail 'unexpected primary hostname'
[ ! -e "$export_file" ] || fail 'target export file already exists'
[ "$(sha256sum /usr/local/slurm/26.11.0/sbin/slurmctld | awk '{print $1}')" = \
	"$expected_binary" ] || fail 'production binary hash mismatch'
[ "$(sha256sum /usr/local/slurm/26.11.0/etc/slurm.conf | awk '{print $1}')" = \
	"$expected_config" ] || fail 'production config hash mismatch'
[ "$(stat -c '%u:%g:%a' "$state")" = 1002:1002:755 ] || \
	fail 'state owner or mode mismatch'
[ "$(findmnt -T "$state" -no FSTYPE)" = xfs ] || fail 'state is not local XFS'
[ "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)" = \
	active,active,active ] || fail 'production Slurm service is not active'
scontrol ping | grep -q ' is UP$' || fail 'primary controller is not UP'
[ -z "$(squeue -h)" ] || fail 'queue is not empty'

ctld_pid=$(systemctl show -p MainPID --value slurmctld)
dbd_pid=$(systemctl show -p MainPID --value slurmdbd)
slurmd_pid=$(systemctl show -p MainPID --value slurmd)
before_exports=$(exportfs -v 2>/dev/null | sha256sum | awk '{print $1}')

if [ ! -d "$export_dir" ]; then
	[ ! -e "$export_dir" ] || fail 'exports.d exists but is not a directory'
	install -d -o root -g root -m 0755 "$export_dir"
	export_dir_created=1
fi
temporary=$(mktemp "${export_dir}/.smd405-slurmctld.XXXXXX")
trap cleanup EXIT HUP INT TERM
printf '%s\n' "$expected_line" >"$temporary"
chown root:root "$temporary"
chmod 0644 "$temporary"
mv "$temporary" "$export_file"
temporary=
installed=1
exportfs -ra || fail 'exportfs reload failed'
exportfs -v | grep -F "$state" >/dev/null || fail 'state export is not active'
exportfs -v | grep -A1 -F "$state" | grep -F '192.168.10.118' >/dev/null || \
	fail 'guest-limited export is not active'

[ "$(systemctl show -p MainPID --value slurmctld)" = "$ctld_pid" ] || \
	fail 'slurmctld PID changed'
[ "$(systemctl show -p MainPID --value slurmdbd)" = "$dbd_pid" ] || \
	fail 'slurmdbd PID changed'
[ "$(systemctl show -p MainPID --value slurmd)" = "$slurmd_pid" ] || \
	fail 'slurmd PID changed'
scontrol ping | grep -q ' is UP$' || fail 'primary controller changed state'
[ -z "$(squeue -h)" ] || fail 'queue changed during export staging'

installed=0
trap - EXIT HUP INT TERM
printf '%s\n' \
	'SMD405_PRIMARY_EXPORT_COMPLETE' \
	"export_file=$export_file" \
	"export_line=$expected_line" \
	"exports_before_sha256=$before_exports" \
	"production_pids=${ctld_pid},${dbd_pid},${slurmd_pid}" \
	'production_unchanged=PASS'
