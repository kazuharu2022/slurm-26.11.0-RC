#!/bin/sh

set -u

run_dir=${1:-}
job_id=${2:-}
case "$run_dir" in
/tmp/slurm-smd406-mac-runtime-run-*) ;;
*) printf 'usage: %s /tmp/slurm-smd406-mac-runtime-run-* JOB_ID\n' "$0" >&2; exit 64 ;;
esac
case "$job_id" in
''|*[!0-9]*) printf 'error: invalid job id=%s\n' "$job_id" >&2; exit 64 ;;
esac

prefix=/opt/slurm/26.11.0
state_file=${prefix}/.smd406-ipv6-runtime.env
slurm_conf=${prefix}/etc/slurm.conf
service_target=system/org.schedmd.slurmd

[ "$(/usr/bin/id -u)" -eq 0 ] || {
	printf 'error: run as root with sudo\n' >&2
	exit 1
}
[ "$(/usr/bin/uname -s)" = Darwin ] || {
	printf 'error: this readback is for macOS\n' >&2
	exit 1
}
[ -d "$run_dir" ] || {
	printf 'error: missing run directory=%s\n' "$run_dir" >&2
	exit 1
}

export SLURM_CONF="$slurm_conf"

printf '%s\n' '[state-and-runtime]'
if [ -f "$state_file" ]; then
	/usr/bin/stat -f '%Su:%Sg:%Lp %z %N' "$state_file"
	/bin/cat "$state_file"
else
	printf 'state_file=ABSENT\n'
fi
/sbin/ifconfig en0 | /usr/bin/grep -F 'fd40:534d:4406:1::128' || \
	printf 'mac_ula=ABSENT\n'
/bin/launchctl print "$service_target" |
	/usr/bin/grep -E 'state =|pid =|last exit code|runs ='
printf 'pidfile='
/bin/cat /var/run/slurmd.pid

printf '%s\n' '[job-output]'
if [ -d "${run_dir}/job-output" ]; then
	/usr/bin/find "${run_dir}/job-output" -maxdepth 1 -type f -print |
	while IFS= read -r file; do
		/usr/bin/stat -f '%Su:%Sg:%Lp %z %N' "$file"
		/bin/cat "$file"
	done
else
	printf 'job_output_directory=ABSENT\n'
fi

printf '%s\n' '[queue-job-node]'
"${prefix}/bin/squeue" -j "$job_id" -o '%i|%T|%R|%N' || true
"${prefix}/bin/scontrol" show job "$job_id" || true
"${prefix}/bin/scontrol" show node PC-210 || true

printf '%s\n' '[accounting]'
"${prefix}/bin/sacct" -j "$job_id" -n -P \
	--format=JobIDRaw,JobName,User,State,ExitCode,NodeList,ReqTRES,AllocTRES || true

printf '%s\n' '[runtime-evidence]'
for name in candidate-C.out candidate-C.err candidate-G.out candidate-G.err \
	controller-6817.err controller-6819.err sacctmgr-ping.txt sacctmgr-ping.err \
	slurmd-6818-listener.txt ipv6-node.txt local-restore-node.txt tcpdump.err; do
	printf '===== %s\n' "$name"
	if [ -f "${run_dir}/${name}" ]; then
		/bin/cat "${run_dir}/${name}"
	else
		printf 'MISSING\n'
	fi
done

printf '%s\n' '[packet-summary]'
if [ -f "${run_dir}/ipv6-packets.txt" ]; then
	/usr/bin/wc -l -c "${run_dir}/ipv6-packets.txt"
	for port in 6817 6818 6819; do
		count=$(/usr/bin/grep -Ec "\\.${port}([: >]|$)" \
			"${run_dir}/ipv6-packets.txt" || true)
		printf 'port=%s packet_lines=%s\n' "$port" "$count"
	done
fi

printf '%s\n' '[slurmd-log-job]'
/usr/bin/grep -nE \
	"JobId=${job_id}|${job_id}[.]batch|job0*${job_id}|REQUEST_BATCH_JOB_LAUNCH|REQUEST_TERMINATE_JOB" \
	/var/log/slurm/slurmd.log | /usr/bin/tail -n 240 || true

printf '%s\n' '[processes]'
/bin/ps -axo pid,ppid,pgid,state,user,command |
	/usr/bin/grep -E "[j]ob0*${job_id}|[s]lurmstepd.*${job_id}|[c]pu[.]sh" || true

printf '%s\n' '[production-hashes]'
/usr/bin/shasum -a 256 "$slurm_conf" "${prefix}/etc/gres.conf" \
	"${prefix}/sbin/slurmd" /Library/LaunchDaemons/org.schedmd.slurmd.plist
/bin/cat "${run_dir}/production-before.sha256"

printf 'SMD406_MAC_FAILURE_READBACK_COMPLETE job_id=%s run_dir=%s\n' \
	"$job_id" "$run_dir"
