#!/bin/sh

set -u

prefix=${SMD303_PREFIX:-/opt/slurm/26.11.0}
production_conf=${SMD303_PRODUCTION_CONF:-${prefix}/etc/slurm.conf}
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
plugin_dir=${prefix}/lib/slurm
node_name=${SMD303_NODE_NAME:-PC-210}
pid_file=${SMD303_PID_FILE:-/var/run/slurmd.pid}
plist=${SMD303_PLIST:-/Library/LaunchDaemons/org.schedmd.slurmd.plist}
service_target=${SMD303_SERVICE_TARGET:-system/org.schedmd.slurmd}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "${script_dir}/../.." && pwd -P)
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=$(/usr/bin/mktemp -d "/private/tmp/slurm-smd303-${run_stamp}.XXXXXX") || exit 1
active_candidate_pid=

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
}

cleanup()
{
	if [ -n "$active_candidate_pid" ] && \
	    /bin/kill -0 "$active_candidate_pid" >/dev/null 2>&1; then
		/bin/kill -TERM "$active_candidate_pid" >/dev/null 2>&1 || true
		wait "$active_candidate_pid" >/dev/null 2>&1 || true
	fi
}

node_field()
{
	field=$1
	file=$2
	/usr/bin/awk -v key="${field}=" '
	{
		for (i = 1; i <= NF; i++) {
			if (index($i, key) == 1) {
				sub(key, "", $i)
				print $i
				exit
			}
		}
	}' "$file"
}

write_candidate_conf()
{
	case_dir=$1
	candidate_node=$2
	controller_port=$3
	worker_port=$4
	proctrack_type=$5
	task_type=$6
	local_user=$7
	local_host=$8

	/bin/mkdir -m 0755 "$case_dir" "${case_dir}/spool" "${case_dir}/state" ||
		fail "cannot create candidate directories for ${case_dir}"
	{
		/usr/bin/printf '%s\n' \
			'ClusterName=smd303-isolated' \
			"SlurmctldHost=smd303ctl(127.0.0.1)" \
			"SlurmctldPort=${controller_port}" \
			"SlurmdPort=${worker_port}" \
			"SlurmUser=${local_user}" \
			"SlurmdUser=${local_user}" \
			"SlurmctldPidFile=${case_dir}/slurmctld.pid" \
			"SlurmdPidFile=${case_dir}/slurmd.pid" \
			"SlurmdSpoolDir=${case_dir}/spool" \
			"StateSaveLocation=${case_dir}/state" \
			"SlurmdLogFile=${case_dir}/slurmd.log" \
			"PluginDir=${plugin_dir}" \
			'AuthType=auth/none' \
			'CredType=cred/none' \
			"ProctrackType=${proctrack_type}"
		if [ "$task_type" != OMIT ]; then
			/usr/bin/printf 'TaskPlugin=%s\n' "$task_type"
		fi
		/usr/bin/printf '%s\n' \
			'JobAcctGatherType=jobacct_gather/none' \
			'SelectType=select/cons_tres' \
			'SwitchType=switch/none' \
			'MpiDefault=none' \
			'SlurmdDebug=debug2' \
			"NodeName=${candidate_node} NodeHostName=${local_host} NodeAddr=127.0.0.1 CPUs=18 Boards=1 SocketsPerBoard=1 CoresPerSocket=1 ThreadsPerCore=18 RealMemory=1024 State=UNKNOWN" \
			"PartitionName=isolate Nodes=${candidate_node} Default=YES MaxTime=INFINITE State=UP"
	} >"${case_dir}/slurm.conf" || fail "cannot write ${case_dir}/slurm.conf"
}

run_negative_case()
{
	case_name=$1
	case_dir=$2
	candidate_node=$3
	expected_primary=$4
	expected_secondary=$5
	worker_port=$6

	SLURM_CONF="${case_dir}/slurm.conf" \
		"$slurmd" -D -vvvv -f "${case_dir}/slurm.conf" -N "$candidate_node" \
		>"${case_dir}/stdout.txt" 2>"${case_dir}/stderr.txt" &
	active_candidate_pid=$!

	i=0
	while /bin/kill -0 "$active_candidate_pid" >/dev/null 2>&1; do
		if [ "$i" -ge 100 ]; then
			/bin/kill -TERM "$active_candidate_pid" >/dev/null 2>&1 || true
			wait "$active_candidate_pid" >/dev/null 2>&1 || true
			active_candidate_pid=
			fail "${case_name} did not fail within 10 seconds; possible no-op startup"
		fi
		/bin/sleep 0.1
		i=$((i + 1))
	done

	wait "$active_candidate_pid"
	rc=$?
	active_candidate_pid=
	[ "$rc" -ne 0 ] || fail "${case_name} returned success"
	/usr/bin/grep -Fq "$expected_primary" "${case_dir}/stderr.txt" ||
		fail "${case_name} did not report ${expected_primary}"
	/usr/bin/grep -Fq "$expected_secondary" "${case_dir}/stderr.txt" ||
		fail "${case_name} did not end with ${expected_secondary}"
	[ ! -e "${case_dir}/slurmd.pid" ] ||
		fail "${case_name} left a candidate pid file"
	if /usr/sbin/lsof -nP -iTCP:"${worker_port}" -sTCP:LISTEN \
		>"${case_dir}/listener-after.txt" 2>&1; then
		fail "${case_name} left TCP ${worker_port} listening"
	fi

	/usr/bin/printf 'case=%s rc=%s result=EXPECTED_REJECTION\n' "$case_name" "$rc"
	/usr/bin/grep -E \
		'Reading cgroup.conf|Trying to load plugin .*(cgroup_v2|proctrack_cgroup|task_cgroup)\.so|cannot find (cgroup|proctrack|task) plugin|cannot create (cgroup|proctrack|task) context|Unable to initialize cgroup plugin|slurmd initialization failed' \
		"${case_dir}/stderr.txt" || true
}

trap cleanup EXIT HUP INT TERM

[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'
[ "$(/usr/bin/id -u)" -ne 0 ] || fail 'run without sudo; candidates must not have root authority'

for required in "$production_conf" "$slurmd" "$scontrol" "$squeue" "$pid_file" \
	"$plist" "${plugin_dir}/auth_none.so" "${plugin_dir}/cred_none.so" \
	"${plugin_dir}/proctrack_pgid.so" "${plugin_dir}/task_affinity.so" \
	"${repo_root}/config.h" "${repo_root}/config.status"; do
	[ -e "$required" ] || fail "missing required file: ${required}"
done
for command in /usr/bin/awk /usr/bin/grep /usr/bin/id /usr/bin/mktemp \
	/usr/bin/shasum /usr/bin/uname /usr/sbin/lsof /bin/cat /bin/date /bin/kill \
	/bin/launchctl /bin/mkdir /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: ${command}"
done

/usr/bin/grep -Fq '/* #undef WITH_CGROUP */' "${repo_root}/config.h" ||
	fail 'current build does not show WITH_CGROUP disabled'
"${repo_root}/config.status" --config >"${run_dir}/configure.txt" ||
	fail 'cannot read configure arguments'
/usr/bin/grep -Fq -- '--disable-cgroupv2' "${run_dir}/configure.txt" ||
	fail 'current configure arguments do not contain --disable-cgroupv2'

for unavailable in cgroup_v1.so cgroup_v2.so proctrack_cgroup.so task_cgroup.so; do
	[ ! -e "${plugin_dir}/${unavailable}" ] ||
		fail "unexpected cgroup plugin is installed: ${plugin_dir}/${unavailable}"
done

export SLURM_CONF="$production_conf"
"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 ||
	fail 'production controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" ||
	fail 'production controller is not UP'
"$scontrol" show node "$node_name" -o >"${run_dir}/node-before.txt" ||
	fail 'cannot read production node before test'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] ||
	fail 'production node is not IDLE before test'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] ||
	fail 'production CPUAlloc is not zero before test'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] ||
	fail 'production AllocMem is not zero before test'
[ -z "$("$squeue" -h -w "$node_name")" ] ||
	fail 'production node has queued or running jobs before test'

production_pid=$(/bin/cat "$pid_file")
case "$production_pid" in
''|*[!0-9]*) fail "invalid production slurmd pid: ${production_pid}" ;;
esac
/bin/ps -p "$production_pid" -o pid= >"${run_dir}/production-pid-before.txt" ||
	fail "production slurmd pid ${production_pid} is not running"
/usr/bin/grep -Eq "^[[:space:]]*${production_pid}[[:space:]]*$" \
	"${run_dir}/production-pid-before.txt" ||
	fail "production slurmd pid ${production_pid} was not returned by ps"
/bin/launchctl print "$service_target" >"${run_dir}/launchd-before.txt" 2>&1 ||
	fail "production launchd service is not loaded: ${service_target}"
launchd_pid=$(/usr/bin/awk '/pid =/ { print $3; exit }' "${run_dir}/launchd-before.txt")
[ "$launchd_pid" = "$production_pid" ] ||
	fail "launchd pid ${launchd_pid} differs from pidfile ${production_pid}"
/bin/ps -p "$production_pid" -o pid=,ppid=,user=,lstart=,command= \
	>"${run_dir}/production-process-before.txt" ||
	fail 'cannot inspect production slurmd process'

/usr/bin/shasum -a 256 "$production_conf" "$slurmd" \
	"${plugin_dir}/proctrack_pgid.so" "${plugin_dir}/task_affinity.so" "$plist" \
	>"${run_dir}/production-before.sha256" || fail 'cannot hash production files'

local_user=$(/usr/bin/id -un)
local_host=$(/bin/hostname -s)
process_dir=${run_dir}/process
task_dir=${run_dir}/task
device_dir=${run_dir}/device

write_candidate_conf "$process_dir" SMD303PROC 26817 26818 \
	proctrack/cgroup OMIT "$local_user" "$local_host"
write_candidate_conf "$task_dir" SMD303TASK 26827 26828 \
	proctrack/pgid task/cgroup "$local_user" "$local_host"
write_candidate_conf "$device_dir" SMD303DEV 26837 26838 \
	proctrack/pgid task/affinity "$local_user" "$local_host"
{
	/usr/bin/printf '%s\n' \
		'CgroupPlugin=cgroup/v2' \
		'ConstrainDevices=yes'
} >"${device_dir}/cgroup.conf" || fail 'cannot write device cgroup.conf'

/usr/bin/printf '%s\n' \
	"SMD-303 cgroup negative runtime" \
	"run_dir=${run_dir}" \
	"execution_uid=$(/usr/bin/id -u) execution_user=${local_user}" \
	"production_pid=${production_pid} production_node=${node_name} production_state=IDLE queue=EMPTY" \
	"build_WITH_CGROUP=UNDEFINED configure_cgroupv2=DISABLED" \
	"installed_cgroup_plugins=ABSENT"

run_negative_case process "$process_dir" SMD303PROC \
	'cannot create proctrack context for proctrack/cgroup' \
	'slurmd initialization failed' 26818
run_negative_case task "$task_dir" SMD303TASK \
	'cannot create task context for task/cgroup' \
	'slurmd initialization failed' 26828
run_negative_case device "$device_dir" SMD303DEV \
	'cannot create cgroup context for cgroup/v2' \
	'slurmd initialization failed' 26838

/usr/bin/shasum -a 256 "$production_conf" "$slurmd" \
	"${plugin_dir}/proctrack_pgid.so" "${plugin_dir}/task_affinity.so" "$plist" \
	>"${run_dir}/production-after.sha256" || fail 'cannot rehash production files'
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production file hash changed'
[ "$(/bin/cat "$pid_file")" = "$production_pid" ] ||
	fail 'production slurmd pid changed'
/bin/ps -p "$production_pid" -o pid= >"${run_dir}/production-pid-after.txt" ||
	fail 'production slurmd stopped'
/usr/bin/grep -Eq "^[[:space:]]*${production_pid}[[:space:]]*$" \
	"${run_dir}/production-pid-after.txt" || fail 'production slurmd pid was not returned by ps'
"$scontrol" show node "$node_name" -o >"${run_dir}/node-after.txt" ||
	fail 'cannot read production node after test'
[ "$(node_field State "${run_dir}/node-after.txt")" = IDLE ] ||
	fail 'production node is not IDLE after test'
[ "$(node_field CPUAlloc "${run_dir}/node-after.txt")" = 0 ] ||
	fail 'production CPUAlloc is not zero after test'
[ "$(node_field AllocMem "${run_dir}/node-after.txt")" = 0 ] ||
	fail 'production AllocMem is not zero after test'
[ -z "$("$squeue" -h -w "$node_name")" ] ||
	fail 'production node has queued or running jobs after test'

/usr/bin/printf '%s\n' \
	"production_unchanged=PASS pid=${production_pid} node=IDLE allocation=ZERO queue=EMPTY hashes=IDENTICAL" \
	"SMD303_PASS_EXPECTED_UNSUPPORTED process=EXPLICIT_REJECTION task=EXPLICIT_REJECTION device=EXPLICIT_REJECTION no_op_success=ABSENT candidate_listeners=ABSENT production=UNCHANGED run_dir=${run_dir}"
