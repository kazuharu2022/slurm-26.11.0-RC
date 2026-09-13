#!/bin/sh

set -u

if [ "${SMD106_MULTI_TASK_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD106_MULTI_TASK_CONFIRMED=YES after confirming PC-210 is idle' >&2
	exit 64
fi

source_root=/Users/REDACTED_USER/dev/slurm.26-05
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
task_count=4
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd106-${run_stamp}
record_dir=${run_dir}/records
client_conf=${run_dir}/slurm-client.conf
payload=${run_dir}/multi-task-payload.sh
job_name=smd106-${run_stamp}
test_job=
client_pid=
slurmd_pid=
slurmd_start=
success=0

export SLURM_CONF="$slurm_conf"

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
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

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }'
}

cancel_if_active()
{
	job_id=$1
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state" >&2
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
}

discover_test_job()
{
	if [ -n "$test_job" ]; then
		return 0
	fi
	candidate=$("$squeue" -h -n "$job_name" -u "$test_user" -o '%A' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }')
	case "$candidate" in
	''|*[!0-9]*) return 0 ;;
	esac
	test_job=$candidate
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ -z "$(queue_state "$job_id")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' \
				"$job_id" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

accounting_complete()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { job_ok = 1 }
		$1 == job ".0" && $3 == "COMPLETED" && $4 == "0:0" { step_ok = 1 }
		END { exit !(job_ok && step_ok) }
	' "$file"
}

wait_accounting()
{
	job_id=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		accounting_complete "$job_id" "$file" && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	discover_test_job
	cancel_if_active "$test_job"
	if [ -n "$client_pid" ]; then
		/bin/kill "$client_pid" >/dev/null 2>&1 || true
	fi
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf '%s\n' \
			"recovery: no production configuration was changed; inspect run_dir=$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$scontrol" "$squeue" "$srun" \
	"$scancel" "$sacct" "$pid_file" \
	"${source_root}/contribs/macos-tests/smd106_multi_task_payload.sh"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for command in /usr/bin/awk /usr/bin/dscacheutil /usr/bin/find \
	/usr/bin/grep /usr/bin/id /usr/bin/pgrep /usr/bin/sed /usr/bin/shasum \
	/usr/bin/sort /usr/bin/sudo /usr/bin/tr /usr/bin/uniq /usr/bin/wc \
	/usr/sbin/chown /usr/sbin/ipconfig /bin/cat /bin/chmod /bin/cp \
	/bin/date /bin/hostname /bin/kill /bin/mkdir /bin/mv /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0700 "$record_dir" || fail 'cannot create record directory'
/usr/sbin/chown "$test_uid:$test_gid" "$record_dir" || fail 'cannot chown record directory'
/bin/cp "${source_root}/contribs/macos-tests/smd106_multi_task_payload.sh" \
	"$payload" || fail 'cannot stage payload'
/bin/chmod 0555 "$payload" || fail 'cannot set payload mode'
/usr/sbin/chown 0:0 "$payload" || fail 'cannot set payload owner'
/usr/bin/printf 'run_dir=%s task_count=%s\n' "$run_dir" "$task_count"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || \
	fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || \
	fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || \
	fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail "slurmd pid=$slurmd_pid is not running"
slurmd_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")

node_ipv4=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || true)
case "$node_ipv4" in
''|*[!0-9.]*) fail "invalid en0 IPv4 address=$node_ipv4" ;;
esac
/usr/bin/dscacheutil -q host -a name "${node_name}.local" \
	>"${run_dir}/node-address-readback.txt" 2>"${run_dir}/node-address-readback.err" || \
	fail "cannot resolve ${node_name}.local"
/usr/bin/grep -Fqx "ip_address: ${node_ipv4}" "${run_dir}/node-address-readback.txt" || \
	fail "${node_name}.local does not resolve to en0 address $node_ipv4"

/usr/bin/awk -v node="$node_name" -v addr="$node_ipv4" '
	$1 == "NodeName=" node {
		found_addr = 0
		for (i = 1; i <= NF; i++) if ($i ~ /^NodeAddr=/) found_addr = 1
		if (!found_addr) $0 = $0 " NodeAddr=" addr
		found_node = 1
	}
	{ print }
	END { if (!found_node) exit 1 }
' "$slurm_conf" >"$client_conf" || fail 'cannot create numeric NodeAddr client config'
/bin/chmod 0644 "$client_conf" || fail 'cannot set client config mode'
/usr/bin/shasum -a 256 "$slurm_conf" "$payload" >"${run_dir}/inputs-before.sha256"

set +e
/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
	SLURM_CONF="$client_conf" \
	"$srun" --partition="$partition" --nodes=1 --ntasks="$task_count" \
	--cpus-per-task=1 --mem=256M --time=00:01:00 --chdir=/tmp \
	--mpi=none --kill-on-bad-exit=1 --job-name="$job_name" \
	"$payload" "$record_dir" >"${run_dir}/srun.out" 2>"${run_dir}/srun.err" &
client_pid=$!
set -e

attempt=0
while [ "$attempt" -lt 300 ]; do
	ready_count=$(/usr/bin/find "$record_dir" -type f -name 'ready.*' |
		/usr/bin/wc -l | /usr/bin/tr -d ' ')
	[ "$ready_count" = "$task_count" ] && break
	/bin/kill -0 "$client_pid" >/dev/null 2>&1 || \
		fail "srun exited before barrier ready_count=$ready_count"
	/bin/sleep 0.1
	attempt=$((attempt + 1))
done
[ "$ready_count" = "$task_count" ] || fail "barrier ready timeout count=$ready_count"

test_job=$(/usr/bin/awk -F '=' '$1 == "job_id" { print $2 }' \
	"${record_dir}"/ready.* | /usr/bin/sort -u)
case "$test_job" in
''|*[!0-9]*) fail "invalid or non-unique test job id=$test_job" ;;
esac
[ "$(queue_state "$test_job")" = RUNNING ] || fail 'test job is not RUNNING at barrier'

expected_host=$(/bin/hostname)
for proc_id in 0 1 2 3; do
	record=${record_dir}/ready.${proc_id}
	[ -f "$record" ] || fail "missing task record procid=$proc_id"
	/usr/bin/grep -Fqx "step_id=0" "$record" || fail "step ID mismatch procid=$proc_id"
	/usr/bin/grep -Fqx "proc_id=$proc_id" "$record" || fail "proc ID mismatch=$proc_id"
	/usr/bin/grep -Fqx "local_id=$proc_id" "$record" || fail "local ID mismatch=$proc_id"
	/usr/bin/grep -Fqx 'node_id=0' "$record" || fail "node ID mismatch procid=$proc_id"
	/usr/bin/grep -Fqx "task_count=$task_count" "$record" || \
		fail "SLURM_NTASKS mismatch procid=$proc_id"
	/usr/bin/grep -Fqx "step_task_count=$task_count" "$record" || \
		fail "SLURM_STEP_NUM_TASKS mismatch procid=$proc_id"
	/usr/bin/grep -Fqx 'node_count=1' "$record" || fail "node count mismatch procid=$proc_id"
	/usr/bin/grep -Fqx "uid=$test_uid" "$record" || fail "UID mismatch procid=$proc_id"
	/usr/bin/grep -Fqx "gid=$test_gid" "$record" || fail "GID mismatch procid=$proc_id"
	/usr/bin/grep -Fqx "node=$expected_host" "$record" || \
		fail "hostname mismatch procid=$proc_id"
	task_pid=$(/usr/bin/awk -F '=' '$1 == "pid" { print $2 }' "$record")
	case "$task_pid" in
	''|*[!0-9]*) fail "invalid PID procid=$proc_id pid=$task_pid" ;;
	esac
	/bin/kill -0 "$task_pid" >/dev/null 2>&1 || fail "task is not alive procid=$proc_id"
	/usr/bin/printf '%s %s\n' "$proc_id" "$task_pid" >>"${run_dir}/task-pids.txt"
done

unique_pids=$(/usr/bin/awk '{ print $2 }' "${run_dir}/task-pids.txt" |
	/usr/bin/sort -n | /usr/bin/uniq | /usr/bin/wc -l | /usr/bin/tr -d ' ')
[ "$unique_pids" = "$task_count" ] || fail "task PID count mismatch=$unique_pids"
/bin/ps -p "$(/usr/bin/awk '{ printf "%s%s", sep, $2; sep="," }' \
	"${run_dir}/task-pids.txt")" -o pid=,ppid=,pgid=,state=,command= \
	>"${run_dir}/tasks-at-barrier.txt" || fail 'cannot capture barrier process state'
[ "$(/usr/bin/wc -l <"${run_dir}/tasks-at-barrier.txt" | /usr/bin/tr -d ' ')" = \
	"$task_count" ] || fail 'not all task processes were present at barrier'

release_epoch=$(/bin/date '+%s')
/usr/bin/printf 'release_epoch=%s\n' "$release_epoch" >"${record_dir}/release"
/usr/bin/printf 'barrier=PASS job_id=%s tasks=%s live_pids=%s release_epoch=%s\n' \
	"$test_job" "$task_count" "$unique_pids" "$release_epoch"

set +e
wait "$client_pid"
srun_rc=$?
set -e
client_pid=
/usr/bin/printf 'srun_rc=%s\n' "$srun_rc"
[ "$srun_rc" -eq 0 ] || fail "multi-task srun failed rc=$srun_rc"
[ ! -s "${run_dir}/srun.err" ] || fail 'srun stderr is not empty'
[ "$(/usr/bin/grep -c '^record=task ' "${run_dir}/srun.out")" = "$task_count" ] || \
	fail 'srun stdout task record count mismatch'

for proc_id in 0 1 2 3; do
	record_pattern="^record=task job_id=${test_job} step_id=0"\
" procid=${proc_id} localid=${proc_id} nodeid=0"\
" ntasks=${task_count} step_ntasks=${task_count} nnodes=1"\
" pid=[0-9]+ uid=${test_uid} gid=${test_gid}"\
" node=${expected_host} start=[0-9]+ release=[0-9]+$"
	/usr/bin/grep -Eq "$record_pattern" \
		"${run_dir}/srun.out" || fail "stdout record mismatch procid=$proc_id"
	done_file=${record_dir}/done.${proc_id}
	[ -f "$done_file" ] || fail "missing completion record procid=$proc_id"
	end_epoch=$(/usr/bin/awk -F '=' '$1 == "end_epoch" { print $2 }' "$done_file")
	case "$end_epoch" in
	''|*[!0-9]*) fail "invalid end epoch procid=$proc_id" ;;
	esac
	[ "$end_epoch" -ge "$release_epoch" ] || fail "task ended before release procid=$proc_id"
done

wait_job_gone "$test_job" || fail 'multi-task job remained in queue'
wait_accounting "$test_job" "${run_dir}/sacct.txt" || \
	fail 'job/step accounting did not reach COMPLETED 0:0'

"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || \
	fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-final.txt")" = IDLE ] || fail 'final node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-final.txt")" = 0 ] || \
	fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-final.txt")" = 0 ] || \
	fail 'final AllocMem is not zero'
[ -z "$(node_field AllocTRES "${run_dir}/node-final.txt")" ] || \
	fail 'final AllocTRES is not empty'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed during test'
[ "$(node_field SlurmdStartTime "${run_dir}/node-final.txt")" = "$slurmd_start" ] || \
	fail 'SlurmdStartTime changed during test'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-final.txt" 2>/dev/null; then
	fail 'slurmstepd remains after test'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-final.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-final.txt" \
	>"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'test payload process remains'
/usr/bin/shasum -a 256 "$slurm_conf" "$payload" >"${run_dir}/inputs-after.sha256"
/usr/bin/cmp -s "${run_dir}/inputs-before.sha256" "${run_dir}/inputs-after.sha256" || \
	fail 'production config or staged payload changed during test'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s%s\n' \
	"SMD106_MULTI_TASK_COMPLETE job_id=$test_job tasks=$task_count" \
	' concurrent=PASS task_ids=0,1,2,3 accounting=COMPLETED' \
	" slurmd_pid=$slurmd_pid production_unchanged=PASS" \
	" run_dir=$run_dir"
