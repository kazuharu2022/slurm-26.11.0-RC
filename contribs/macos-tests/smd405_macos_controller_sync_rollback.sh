#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_MAC_CONFIG_ROLLBACK_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD405_MAC_CONFIG_ROLLBACK_CONFIRMED=YES after approval' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
config=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
pid_file=/var/run/slurmd.pid
service_target=system/org.schedmd.slurmd
state_dir=/private/tmp/slurm-smd405-controller-sync-active
expected_before=62bcea15398de5f373132a1a3ef21c005c184c20f483da076b44eb5af284f157
expected_after=33f1bb4ef72ee0fe750df473c2b8afb103b40e95443740418408ed488325ffdb

fail()
{
	/usr/bin/printf 'SMD405_MAC_CONFIG_ROLLBACK_FAILED error=%s state_dir=%s\n' \
		"$1" "$state_dir" >&2
	exit 1
}

file_hash()
{
	/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

managed_slurmd_pid()
{
	[ -f "$pid_file" ] || return 1
	pid=$(/bin/cat "$pid_file")
	case "$pid" in ''|*[!0-9]*) return 1 ;; esac
	/bin/kill -0 "$pid" >/dev/null 2>&1 || return 1
	/bin/launchctl procinfo "$pid" 2>/dev/null | \
		/usr/bin/grep -Fq "$service_target = {" || return 1
	/usr/bin/printf '%s\n' "$pid"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root'
[ "$(/bin/hostname -s)" = PC-210 ] || fail 'unexpected Mac hostname'
[ -f "${state_dir}/slurm.conf.before" ] || fail 'rollback backup is absent'
[ "$(file_hash "$config")" = "$expected_after" ] || fail 'active config hash mismatch'
[ "$(file_hash "${state_dir}/slurm.conf.before")" = "$expected_before" ] || \
	fail 'rollback backup hash mismatch'
[ -z "$("$squeue" -h)" ] || fail 'queue is not empty'
initial_pid=$(managed_slurmd_pid) || fail 'launchd slurmd identity mismatch'
tmp=${config}.smd405-rollback.$$
trap '/bin/rm -f -- "$tmp"' EXIT HUP INT TERM
/usr/bin/install -o root -g wheel -m 0644 "${state_dir}/slurm.conf.before" "$tmp" || \
	fail 'rollback staging failed'
/bin/mv -f -- "$tmp" "$config"
trap - EXIT HUP INT TERM
[ "$(file_hash "$config")" = "$expected_before" ] || fail 'restored config hash mismatch'
/bin/kill -HUP "$initial_pid" || fail 'slurmd rollback HUP failed'
/bin/sleep 2
[ "$(managed_slurmd_pid)" = "$initial_pid" ] || fail 'launchd slurmd PID changed'
"$scontrol" ping >"${state_dir}/rollback-controller.txt" 2>&1 || \
	fail 'controller ping after rollback failed'
/usr/bin/grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
	"${state_dir}/rollback-controller.txt" || fail 'primary is not UP after rollback'
[ -z "$("$squeue" -h)" ] || fail 'queue changed during rollback'

archive=/private/tmp/slurm-smd405-controller-sync-rolled-back-$(/bin/date '+%Y%m%dT%H%M%S')
/bin/mv "$state_dir" "$archive"
/bin/chmod -R a+rX "$archive"
/usr/bin/printf 'SMD405_MAC_CONFIG_ROLLBACK_PASS config=%s slurmd_pid_unchanged=%s archive=%s\n' \
	"$expected_before" "$initial_pid" "$archive"
