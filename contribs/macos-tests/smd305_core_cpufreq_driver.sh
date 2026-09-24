#!/bin/sh

set -eu

if [ "${SMD305_CAFFEINATED:-0}" != 1 ]; then
	exec /usr/bin/caffeinate -is /usr/bin/env SMD305_CAFFEINATED=1 "$0" "$@"
fi

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
payload_src=${repo_root}/contribs/macos-tests/smd305_metadata_payload.sh
mac_prefix=/opt/slurm/26.11.0
mac_conf=${mac_prefix}/etc/slurm.conf
mac_bin=${mac_prefix}/bin
remote_host=${SMD305_REMOTE_HOST:-tera@192.168.10.180}
ssh_key=${SMD305_SSH_KEY:-/Users/tera/.ssh/id_ed25519}
remote_prefix=${SMD305_REMOTE_PREFIX:-/usr/local/slurm/26.11.0}
node_name=${SMD305_NODE_NAME:-PC-210}
stamp=$(/bin/date +%Y%m%dT%H%M%S)
run_dir=$(/usr/bin/mktemp -d "/private/tmp/slurm-smd305-${stamp}.XXXXXX")
payload=${run_dir}/smd305_metadata_payload.sh
output_dir=${run_dir}/job-output
log_file=/var/log/slurm/slurmd-launchd.err.log
job_ids=
control_job=
core_job=
freq_job=
submitted_job_id=

fail()
{
	/usr/bin/printf 'SMD305_FAIL %s run_dir=%s\n' "$1" "$run_dir" >&2
	exit 1
}

remote()
{
	/usr/bin/ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=10 \
		"$remote_host" "$@"
}

remote_prefix_env()
{
	remote "set -eu; export LD_LIBRARY_PATH=${remote_prefix}/lib/slurm; export SLURM_CONF=${remote_prefix}/etc/slurm.conf; $*"
}

cleanup()
{
	for cleanup_job in $job_ids; do
		remote_prefix_env "sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/scancel ${cleanup_job} >/dev/null 2>&1 || true" \
			>/dev/null 2>&1 || true
	done
}

launchd_pid()
{
	/bin/launchctl print system/org.schedmd.slurmd |
		/usr/bin/awk '/^[[:space:]]*pid = [0-9]+$/ { print $3; exit }'
}

production_hashes()
{
	/usr/bin/shasum -a 256 \
		${mac_prefix}/sbin/slurmd \
		${mac_prefix}/sbin/slurmstepd \
		${mac_prefix}/lib/slurm/task_affinity.so \
		${mac_conf} \
		/Library/LaunchDaemons/org.schedmd.slurmd.plist
}

wait_for_marker()
{
	marker=$1
	case_name=$2
	i=0
	while [ ! -s "$marker" ]; do
		if [ "$i" -ge 60 ]; then
			fail "${case_name} marker did not appear within 60 seconds"
		fi
		/bin/sleep 1
		i=$((i + 1))
	done
}

wait_for_terminal()
{
	job_id=$1
	case_name=$2
	i=0
	while [ "$i" -lt 90 ]; do
		state=$(remote_prefix_env "set +e; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/sacct -X -j ${job_id} -n -P --format=State | /usr/bin/head -n 1; exit 0" |
			/usr/bin/awk -F'|' 'NR == 1 { print $1 }')
		case "$state" in
		COMPLETED)
			return 0
			;;
		FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY)
			fail "${case_name} reached unexpected state ${state}"
			;;
		esac
		/bin/sleep 1
		i=$((i + 1))
	done
	fail "${case_name} did not complete within 90 seconds"
}

submit_case()
{
	case_name=$1
	extra_option=$2
	wrap_command=$3
	job_name=S305_${case_name}_$(/bin/date +%H%M%S)
	stdout_file=${output_dir}/${case_name}.out
	stderr_file=${output_dir}/${case_name}.err
	submit_stdout=${run_dir}/${case_name}-submit.stdout
	submit_stderr=${run_dir}/${case_name}-submit.stderr

	remote_prefix_env "sudo -n -u testuser env HOME=/tmp LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/sbatch --parsable --partition=debug --nodelist=${node_name} --nodes=1 --ntasks=1 --cpus-per-task=1 --mem=128M --time=00:02:00 --chdir=/tmp --job-name=${job_name} --output=${stdout_file} --error=${stderr_file} ${extra_option} --wrap='${wrap_command}'" \
		>"$submit_stdout" 2>"$submit_stderr" || fail "${case_name} submission failed"
	job_id=$(/usr/bin/awk 'NR == 1 { sub(/;.*/, "", $1); print $1 }' "$submit_stdout")
	case "$job_id" in
	''|*[!0-9]*) fail "${case_name} returned invalid job id ${job_id}" ;;
	esac
	job_ids="${job_ids} ${job_id}"
	submitted_job_id=$job_id
}

trap cleanup EXIT HUP INT TERM

[ "$(/usr/bin/id -u)" -ne 0 ] || fail 'run without sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for macOS'
[ -r "$payload_src" ] || fail 'payload is missing'
[ -r "$mac_conf" ] || fail 'production config is not readable'
[ -x "${mac_bin}/scontrol" ] || fail 'production scontrol is missing'
[ -x "${mac_bin}/squeue" ] || fail 'production squeue is missing'
[ -r "$ssh_key" ] || fail 'SSH key is not readable'
[ -r "$log_file" ] || fail 'slurmd log is not readable'
[ ! -e /sys/devices/system/cpu/cpu0/cpufreq ] ||
	fail 'unexpected Linux cpufreq sysfs path exists on macOS'
/usr/bin/grep -Fq '#if defined(__APPLE__)' \
	"${repo_root}/src/slurmd/slurmd/slurmd.c" || fail 'macOS core-spec source guard changed'
/usr/bin/grep -Fq '#define PATH_TO_CPU' \
	"${repo_root}/src/common/cpu_frequency.c" || fail 'CPU frequency source path changed'

/bin/chmod 0711 "$run_dir"
/bin/mkdir -m 0777 "$output_dir"
/bin/cp "$payload_src" "$payload"
/bin/chmod 0755 "$payload"

before_pid=$(launchd_pid)
case "$before_pid" in
''|*[!0-9]*) fail 'invalid launchd PID before test' ;;
esac
production_hashes >"${run_dir}/production-before.sha256"
log_lines_before=$(/usr/bin/wc -l <"$log_file" | /usr/bin/tr -d ' ')

SLURM_CONF="$mac_conf" "${mac_bin}/scontrol" ping \
	>"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
SLURM_CONF="$mac_conf" "${mac_bin}/scontrol" show node "$node_name" -o \
	>"${run_dir}/node-before.txt" || fail 'node preflight failed'
/usr/bin/grep -q 'State=IDLE' "${run_dir}/node-before.txt" || fail 'node is not IDLE'
/usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-before.txt" || fail 'CPUAlloc is not zero'
/usr/bin/grep -q 'AllocMem=0' "${run_dir}/node-before.txt" || fail 'AllocMem is not zero'
SLURM_CONF="$mac_conf" "${mac_bin}/squeue" -h -w "$node_name" \
	>"${run_dir}/queue-before.txt"
[ ! -s "${run_dir}/queue-before.txt" ] || fail 'queue is not empty'

remote_prefix_env "sudo -n true; sudo -n -u testuser id; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/scontrol ping; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/scontrol show config | /usr/bin/grep -E '^(AllowSpecResourcesUsage|CpuFreqDef|CpuFreqGovernors|LaunchParameters|SelectType|TaskPlugin|TaskPluginParam)[[:space:]]*='" \
	>"${run_dir}/controller-config.txt" 2>&1 || fail 'controller config preflight failed'
/usr/bin/grep -Eq '^AllowSpecResourcesUsage[[:space:]]*=[[:space:]]*no$' \
	"${run_dir}/controller-config.txt" || fail 'AllowSpecResourcesUsage is not no'
/usr/bin/grep -Eq '^SelectType[[:space:]]*=[[:space:]]*select/cons_tres$' \
	"${run_dir}/controller-config.txt" || fail 'SelectType changed'
/usr/bin/grep -Eq '^TaskPlugin[[:space:]]*=[[:space:]]*task/affinity$' \
	"${run_dir}/controller-config.txt" || fail 'TaskPlugin changed'
/usr/bin/grep -Eq '^CpuFreqGovernors[[:space:]]*=.*Performance' \
	"${run_dir}/controller-config.txt" || fail 'Performance governor request is not allowed'

/usr/bin/awk '
/CPU frequency setting not configured for this node/ { cpu = $0 }
/_core_spec_init: not supported on macOS/ { core = $0 }
END {
	if (cpu == "" || core == "")
		exit 1
	print cpu
	print core
}' "$log_file" >"${run_dir}/last-startup-warnings.txt" ||
	fail 'expected macOS startup warnings are missing'

/usr/bin/sed -n '3232,3250p' "${repo_root}/src/slurmd/slurmd/slurmd.c" \
	>"${run_dir}/source-core-spec.txt"
/usr/bin/sed -n '288,315p' "${repo_root}/src/common/cpu_frequency.c" \
	>"${run_dir}/source-cpufreq-init.txt"
/usr/bin/sed -n '386,425p' "${repo_root}/src/common/cpu_frequency.c" \
	>"${run_dir}/source-cpufreq-transfer.txt"
/usr/bin/sed -n '5288,5308p' "${repo_root}/src/common/slurm_opt.c" \
	>"${run_dir}/source-core-spec-cli.txt"
/usr/bin/sed -n '120,140p' "${repo_root}/doc/html/core_spec.shtml" \
	>"${run_dir}/official-core-spec-contract.txt"
/usr/bin/shasum -a 256 "$payload_src" "$0" >"${run_dir}/inputs.sha256"

control_marker=${output_dir}/control.ready
submit_case control '' "${payload} control ${control_marker} 12"
control_job=$submitted_job_id
wait_for_marker "$control_marker" control
remote_prefix_env "sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/scontrol show job ${control_job} -dd; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/squeue -h -j ${control_job} -o '%i|%T|%X|%C|%R'" \
	>"${run_dir}/control-live.txt"
wait_for_terminal "$control_job" control

core_marker=${output_dir}/core.ready
submit_case core '--core-spec=1' "${payload} core ${core_marker} 12"
core_job=$submitted_job_id
wait_for_marker "$core_marker" core
remote_prefix_env "sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/scontrol show job ${core_job} -dd; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/squeue -h -j ${core_job} -o '%i|%T|%X|%C|%R'" \
	>"${run_dir}/core-live.txt"
/usr/bin/grep -Fq 'Ignoring -S since' "${run_dir}/core-submit.stderr" ||
	fail 'core specialization request was not explicitly ignored'
/usr/bin/grep -Fq 'CoreSpec=*' "${run_dir}/core-live.txt" ||
	fail 'core specialization request was not cleared'
wait_for_terminal "$core_job" core

freq_marker=${output_dir}/cpufreq.ready
submit_case cpufreq '' "${mac_bin}/srun --cpu-freq=performance ${payload} cpufreq ${freq_marker} 12"
freq_job=$submitted_job_id
wait_for_marker "$freq_marker" cpufreq
remote_prefix_env "sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/scontrol show job ${freq_job} -dd; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/scontrol show step ${freq_job}.0" \
	>"${run_dir}/cpufreq-live.txt"
/usr/bin/grep -Fq 'cpu_freq_req=Performance' "$freq_marker" ||
	fail 'CPU frequency request metadata did not reach the payload'
wait_for_terminal "$freq_job" cpufreq

remote_prefix_env "sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/sacct -j ${control_job},${core_job},${freq_job} -n -P --format=JobIDRaw,JobName,State,ExitCode,ElapsedRaw,AllocCPUS,ReqCPUFreqMin,ReqCPUFreqMax,ReqCPUFreqGov,AveCPUFreq,ReqTRES,AllocTRES" \
	>"${run_dir}/sacct-final.txt" 2>"${run_dir}/sacct-final.stderr" ||
	fail 'final sacct query failed'
[ ! -s "${run_dir}/sacct-final.stderr" ] || fail 'final sacct stderr is not empty'
for completed_job in "$control_job" "$core_job" "$freq_job"; do
	/usr/bin/grep -Eq "^${completed_job}\\|.*\\|COMPLETED\\|0:0\\|" \
		"${run_dir}/sacct-final.txt" || fail "job ${completed_job} is not COMPLETED 0:0"
	/usr/bin/grep -Eq "^${completed_job}\\.batch\\|.*\\|COMPLETED\\|0:0\\|" \
		"${run_dir}/sacct-final.txt" || fail "batch ${completed_job} is not COMPLETED 0:0"
done
/usr/bin/grep -Eq "^${freq_job}\\.0\\|.*\\|COMPLETED\\|0:0\\|" \
	"${run_dir}/sacct-final.txt" || fail 'CPU frequency step is not COMPLETED 0:0'
for output_case in control core cpufreq; do
	/usr/bin/grep -q "^SMD305_PAYLOAD case=${output_case} " \
		"${output_dir}/${output_case}.out" || fail "${output_case} payload output is missing"
	/usr/bin/grep -q "^SMD305_DONE case=${output_case} " \
		"${output_dir}/${output_case}.out" || fail "${output_case} completion output is missing"
	[ ! -s "${output_dir}/${output_case}.err" ] || fail "${output_case} job stderr is not empty"
done

SLURM_CONF="$mac_conf" "${mac_bin}/scontrol" show node "$node_name" -o \
	>"${run_dir}/node-after.txt" || fail 'final node readback failed'
/usr/bin/grep -q 'State=IDLE' "${run_dir}/node-after.txt" || fail 'node is not IDLE after test'
/usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-after.txt" || fail 'final CPUAlloc is not zero'
/usr/bin/grep -q 'AllocMem=0' "${run_dir}/node-after.txt" || fail 'final AllocMem is not zero'
SLURM_CONF="$mac_conf" "${mac_bin}/squeue" -h -w "$node_name" \
	>"${run_dir}/queue-after.txt"
[ ! -s "${run_dir}/queue-after.txt" ] || fail 'queue is not empty after test'

after_pid=$(launchd_pid)
[ "$after_pid" = "$before_pid" ] || fail 'launchd slurmd PID changed'
production_hashes >"${run_dir}/production-after.sha256"
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production artifact hash changed'

log_start=$((log_lines_before + 1))
/usr/bin/sed -n "${log_start},\$p" "$log_file" >"${run_dir}/launchd-log-delta.txt"
if /usr/bin/grep -Eqi 'fatal|segmentation|abort|slurmd initialization failed' \
	"${run_dir}/launchd-log-delta.txt"; then
	fail 'unexpected daemon failure appeared in log delta'
fi

/usr/bin/printf '%s\n' \
	"SMD305_RUNTIME_COMPLETE control_job=${control_job} core_job=${core_job} cpufreq_job=${freq_job} core_request=CLEARED cpu_freq_request=METADATA_ONLY jobs=COMPLETED node=IDLE queue=EMPTY launchd_pid=${after_pid} production=UNCHANGED run_dir=${run_dir}"
