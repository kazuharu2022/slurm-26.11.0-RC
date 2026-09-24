#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
probe_src="${repo_root}/contribs/macos-tests/smd301_affinity_probe.c"
mac_prefix=/opt/slurm/26.11.0
mac_conf="${mac_prefix}/etc/slurm.conf"
mac_bin="${mac_prefix}/bin"
remote_host=tera@192.168.10.180
ssh_key=/Users/tera/.ssh/id_ed25519
remote_prefix=/usr/local/slurm/26.11.0
stamp=$(/bin/date +%Y%m%dT%H%M%S)
run_dir=$(/usr/bin/mktemp -d "/private/tmp/slurm-smd301-${stamp}.XXXXXX")
payload_dir="${run_dir}/payload"
probe_bin="${payload_dir}/smd301_affinity_probe"
hash_before="${run_dir}/production-before.sha256"
hash_after="${run_dir}/production-after.sha256"
log_file=/var/log/slurm/slurmd-launchd.err.log
xsched_src="${repo_root}/src/common/xsched.c"

fail()
{
	/usr/bin/printf 'SMD301_FAIL %s run_dir=%s\n' "$1" "$run_dir" >&2
	exit 1
}

/bin/chmod 0711 "$run_dir"
/bin/mkdir -m 0755 "$payload_dir"

production_hashes()
{
	/usr/bin/shasum -a 256 \
		"${mac_prefix}/sbin/slurmd" \
		"${mac_prefix}/sbin/slurmstepd" \
		"${mac_prefix}/lib/slurm/task_affinity.so" \
		"${mac_conf}" \
		/Library/LaunchDaemons/org.schedmd.slurmd.plist
}

launchd_pid()
{
	/bin/launchctl print system/org.schedmd.slurmd |
		/usr/bin/awk '/^[[:space:]]*pid = [0-9]+$/ { print $3; exit }'
}

remote()
{
	/usr/bin/ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=10 \
		"$remote_host" "$@"
}

run_case()
{
	case_id=$1
	bind_arg=$2
	ntasks=$3
	job_name=$4
	output_file="${run_dir}/${case_id}.txt"

	remote "set +e; export LD_LIBRARY_PATH=${remote_prefix}/lib/slurm; export SLURM_CONF=${remote_prefix}/etc/slurm.conf; sudo -n -u testuser env HOME=/tmp LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/srun --chdir=/tmp --immediate=10 --nodes=1 --nodelist=PC-210 --ntasks=${ntasks} --cpus-per-task=1 --cpu-bind='${bind_arg}' --job-name='${job_name}' '${probe_bin}'; rc=\$?; echo SMD301_CASE_RC=\$rc; sleep 2; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/sacct -X -n -P -S now-30minutes --name='${job_name}' -o JobIDRaw,JobName,State,ExitCode,NodeList,AllocCPUS; exit 0" \
		>"$output_file" 2>&1 || fail "remote case ${case_id} transport failed"

	/usr/bin/grep -Eq '^SMD301_CASE_RC=[0-9]+$' "$output_file" ||
		fail "case ${case_id} did not record srun rc"
}

[ -r "$probe_src" ] || fail 'probe source is missing'
[ -r "$xsched_src" ] || fail 'xsched source is missing'
[ -r "$mac_conf" ] || fail 'production config is not readable'
[ -x "${mac_bin}/scontrol" ] || fail 'production scontrol is missing'
[ -r "$log_file" ] || fail 'launchd stderr log is not readable'

before_pid=$(launchd_pid)
case "$before_pid" in
''|*[!0-9]*) fail 'launchd PID is invalid' ;;
esac

production_hashes >"$hash_before"
log_lines_before=$(/usr/bin/wc -l <"$log_file" | /usr/bin/tr -d ' ')

/usr/bin/sed -n '126,140p' "$xsched_src" >"${run_dir}/xsched-apple-path.txt"
/usr/bin/grep -q '#elif defined(__APPLE__)' "${run_dir}/xsched-apple-path.txt" ||
	fail 'Apple xsetaffinity branch is missing'
/usr/bin/grep -q 'errno = ENOTSUP' "${run_dir}/xsched-apple-path.txt" ||
	fail 'Apple xsetaffinity does not explicitly return ENOTSUP'
if /usr/bin/grep -R -q 'thread_policy_set' \
	"${repo_root}/src/plugins/task" "${repo_root}/src/common/xsched.c"; then
	fail 'Slurm source unexpectedly uses Mach advisory thread affinity'
fi

/usr/bin/env SLURM_CONF="$mac_conf" "${mac_bin}/scontrol" show node PC-210 -o \
	>"${run_dir}/node-before.txt"
/usr/bin/grep -q 'State=IDLE' "${run_dir}/node-before.txt" ||
	fail 'Mac node is not IDLE before the test'
/usr/bin/env SLURM_CONF="$mac_conf" "${mac_bin}/squeue" -h \
	>"${run_dir}/queue-before.txt"
[ ! -s "${run_dir}/queue-before.txt" ] || fail 'queue is not empty before the test'

remote "set -eu; export LD_LIBRARY_PATH=${remote_prefix}/lib/slurm; export SLURM_CONF=${remote_prefix}/etc/slurm.conf; sudo -n true; sudo -n -u testuser id; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/scontrol show config | grep -E '^(TaskPlugin|ProctrackType|JobAcctGatherType)'; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/scontrol show node PC-210 -o; test -z \"\$(sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/squeue -h)\"" \
	>"${run_dir}/controller-preflight.txt" 2>&1 ||
	fail 'controller preflight failed'

/usr/bin/xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -O2 \
	"$probe_src" -o "$probe_bin"
/bin/chmod 0755 "$probe_bin"
/usr/bin/file "$probe_bin" >"${run_dir}/probe-file.txt"
/usr/bin/shasum -a 256 "$probe_src" "$probe_bin" >"${run_dir}/probe.sha256"
"$probe_bin" >"${run_dir}/probe-local.txt" 2>&1 || fail 'local probe failed'
/usr/bin/grep -Eq 'mach_affinity_get=NOT_SUPPORTED\(46\).*strict_set_symbol=ABSENT strict_get_symbol=ABSENT logical_cpus=18' \
	"${run_dir}/probe-local.txt" || fail 'unexpected local affinity policy'

suffix=$(/bin/date +%H%M%S)
run_case control 'none' 1 "S301N_${suffix}"
run_case map0 'verbose,map_cpu:0' 1 "S301M0_${suffix}"
run_case map1 'verbose,map_cpu:1' 1 "S301M1_${suffix}"
run_case cores2 'verbose,cores' 2 "S301C2_${suffix}"

for case_id in control map0 map1 cores2; do
	case_file="${run_dir}/${case_id}.txt"
	/usr/bin/grep -q '^SMD301_CASE_RC=0$' "$case_file" ||
		fail "case ${case_id} did not complete successfully"
	/usr/bin/grep -Eq 'mach_affinity_get=NOT_SUPPORTED\(46\).*strict_set_symbol=ABSENT strict_get_symbol=ABSENT logical_cpus=18' \
		"$case_file" || fail "case ${case_id} did not confirm affinity API absence"
	/usr/bin/grep -Eq '\|COMPLETED\|0:0\|PC-210\|' "$case_file" ||
		fail "case ${case_id} accounting is not COMPLETED 0:0"
done

[ "$(/usr/bin/grep -c '^AFFINITY_PROBE ' "${run_dir}/cores2.txt")" -eq 2 ] ||
	fail 'cores2 did not launch two probes'

if /usr/bin/grep -Eqi 'cpu-bind=.*mask .* set|binding .*set|affinity .*set' \
	"${run_dir}/map0.txt" "${run_dir}/map1.txt" "${run_dir}/cores2.txt"; then
	fail 'Slurm reported CPU binding as set on macOS'
fi

/usr/bin/grep -q 'slurm_cpu_bind=verbose,map_cpu:0' "${run_dir}/map0.txt" ||
	fail 'map0 request metadata is missing'
/usr/bin/grep -q 'slurm_cpu_bind_list=0' "${run_dir}/map0.txt" ||
	fail 'map0 list metadata is missing'
/usr/bin/grep -q 'slurm_cpu_bind=verbose,map_cpu:1' "${run_dir}/map1.txt" ||
	fail 'map1 request metadata is missing'
/usr/bin/grep -q 'slurm_cpu_bind_list=1' "${run_dir}/map1.txt" ||
	fail 'map1 list metadata is missing'
/usr/bin/grep -q 'slurm_cpu_bind=verbose,cores' "${run_dir}/cores2.txt" ||
	fail 'cores request metadata is missing'

remote "set -eu; export LD_LIBRARY_PATH=${remote_prefix}/lib/slurm; export SLURM_CONF=${remote_prefix}/etc/slurm.conf; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/scontrol show node PC-210 -o; sudo -n env LD_LIBRARY_PATH=\"\$LD_LIBRARY_PATH\" SLURM_CONF=\"\$SLURM_CONF\" ${remote_prefix}/bin/squeue -h" \
	>"${run_dir}/controller-final.txt" 2>&1 || fail 'controller final readback failed'
/usr/bin/grep -q 'State=IDLE' "${run_dir}/controller-final.txt" ||
	fail 'Mac node is not IDLE after the test'

/usr/bin/env SLURM_CONF="$mac_conf" "${mac_bin}/scontrol" show node PC-210 -o \
	>"${run_dir}/node-final.txt"
/usr/bin/grep -q 'State=IDLE' "${run_dir}/node-final.txt" ||
	fail 'local node readback is not IDLE'
/usr/bin/env SLURM_CONF="$mac_conf" "${mac_bin}/squeue" -h \
	>"${run_dir}/queue-final.txt"
[ ! -s "${run_dir}/queue-final.txt" ] || fail 'queue is not empty after the test'

after_pid=$(launchd_pid)
[ "$after_pid" = "$before_pid" ] || fail 'launchd slurmd PID changed'
production_hashes >"$hash_after"
/usr/bin/cmp -s "$hash_before" "$hash_after" || fail 'production artifact hash changed'

log_start=$((log_lines_before + 1))
/usr/bin/sed -n "${log_start},\$p" "$log_file" >"${run_dir}/launchd-log-delta.txt"
if /usr/bin/grep -Eqi 'sched_setaffinity|cpu-bind=.* set|affinity .*set' \
	"${run_dir}/launchd-log-delta.txt"; then
	fail 'daemon log claimed an affinity operation'
fi

/usr/bin/printf '%s\n' \
	"SMD301_PASS_EXPECTED_UNSUPPORTED behavior=REQUEST_METADATA_ONLY mach_affinity_get=NOT_SUPPORTED strict_affinity_symbols=ABSENT strict_cpu_pinning=NOT_ENFORCED misleading_bind_success_log=ABSENT jobs=4 initial_probe_job=666 node=IDLE queue=EMPTY launchd_pid=${after_pid} artifacts=UNCHANGED run_dir=${run_dir}"
