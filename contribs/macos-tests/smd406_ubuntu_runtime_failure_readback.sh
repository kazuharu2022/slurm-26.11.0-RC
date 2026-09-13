#!/bin/sh

set -u

job_id=${1:-}
case "$job_id" in
''|*[!0-9]*) printf 'usage: %s JOB_ID\n' "$0" >&2; exit 64 ;;
esac

prefix=/usr/local/slurm/26.11.0
state_file=${prefix}/.smd406-ipv6-runtime.env
slurm_conf=${prefix}/etc/slurm.conf

[ "$(id -u)" -eq 0 ] || {
	printf 'error: run as root with sudo\n' >&2
	exit 1
}
[ "$(uname -s)" = Linux ] || {
	printf 'error: this readback is for Ubuntu\n' >&2
	exit 1
}
[ -f "$state_file" ] || {
	printf 'error: missing active state=%s\n' "$state_file" >&2
	exit 1
}
[ "$(stat -c '%U:%G:%a' "$state_file")" = root:root:600 ] || {
	printf 'error: state owner/mode mismatch\n' >&2
	exit 1
}

. "$state_file"
case "${apply_run_dir:-}" in
/tmp/slurm-smd406-ubuntu-runtime-apply-*) ;;
*) printf 'error: invalid apply_run_dir=%s\n' "${apply_run_dir:-}" >&2; exit 1 ;;
esac

export SLURM_CONF="$slurm_conf"

printf '%s\n' '[state-network-services]'
stat -c '%U:%G:%a %s %n' "$state_file"
cat "$state_file"
ip -6 -o addr show dev br0 | grep -F 'fd40:534d:4406:1::180/64' || \
	printf 'ubuntu_ula=ABSENT\n'
systemctl is-active slurmdbd slurmctld slurmd
systemctl show slurmdbd slurmctld slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp
ss -6 -ltnp | grep -E ':6817([[:space:]]|$)|:6818([[:space:]]|$)|:6819([[:space:]]|$)' || true

printf '%s\n' '[queue-job-nodes]'
"${prefix}/bin/squeue" -j "$job_id" -o '%i|%T|%R|%N' || true
"${prefix}/bin/scontrol" show job "$job_id" || true
"${prefix}/bin/scontrol" show node PC-210 || true
"${prefix}/bin/scontrol" show node ubuntu || true

printf '%s\n' '[accounting]'
"${prefix}/bin/sacct" -j "$job_id" -n -P \
	--format=JobIDRaw,JobName,User,State,ExitCode,NodeList,ReqTRES,AllocTRES || true

printf '%s\n' '[apply-evidence]'
for name in ipv6-controller-ping.txt ipv6-dbd-ping.txt listeners-ipv6.txt \
	controller-config-ipv6.txt ipv6-ubuntu.txt; do
	printf '===== %s\n' "$name"
	if [ -f "${apply_run_dir}/${name}" ]; then
		cat "${apply_run_dir}/${name}"
	else
		printf 'MISSING\n'
	fi
done

printf '%s\n' '[controller-log-job]'
journalctl -u slurmctld --since '2026-09-12 15:38:00' --no-pager -o short-iso |
	grep -E "JobId=${job_id}|job ${job_id}|PC-210|error:|sched: Allocate" |
	tail -n 260 || true

printf '%s\n' '[worker-log-job]'
journalctl -u slurmd --since '2026-09-12 15:38:00' --no-pager -o short-iso |
	grep -E "JobId=${job_id}|${job_id}[.]batch|error:|REQUEST_BATCH_JOB_LAUNCH|REQUEST_TERMINATE_JOB" |
	tail -n 220 || true

printf '%s\n' '[current-and-before-hashes]'
sha256sum "$slurm_conf" "${prefix}/etc/slurmdbd.conf" "${prefix}/etc/gres.conf" \
	"${prefix}/sbin/slurmd"
cat "${apply_run_dir}/production-before.sha256"

printf 'SMD406_UBUNTU_FAILURE_READBACK_COMPLETE job_id=%s apply_run_dir=%s\n' \
	"$job_id" "$apply_run_dir"
