#!/bin/sh

set -u

if [ "${SMD108_CPU_OVERCOMMIT_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD108_CPU_OVERCOMMIT_CONFIRMED=YES after confirming PC-210 is idle' >&2
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
below_count=4
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd108-${run_stamp}
client_conf=${run_dir}/slurm-client.conf
payload=${run_dir}/cpu-task-payload.sh
source_payload=${source_root}/contribs/macos-tests/smd108_cpu_task_payload.sh
source_driver=${source_root}/contribs/macos-tests/smd108_cpu_overcommit_driver.sh
active_jobs=
client_pid=
slurmd_pid=
slurmd_start=
cpu_total=
equal_count=
over_count=
below_job=
equal_job=
over_job=
case_job_id=
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

accounting_success()
{
	job_id=$1
	expected_cpu=$2
	file=$3
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" \
		-v expected="$expected_cpu" '
	function cpu_is(tres, expected, fields, i) {
		n = split(tres, fields, ",")
		for (i = 1; i <= n; i++) if (fields[i] == "cpu=" expected) return 1
		return 0
	}
	$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" &&
		cpu_is($6, expected) { job_ok = 1 }
	$1 == job ".0" && $3 == "COMPLETED" && $4 == "0:0" &&
		cpu_is($6, expected) { step_ok = 1 }
	END { exit !(job_ok && step_ok) }
	' "$file"
}

wait_success_accounting()
{
	job_id=$1
	expected_cpu=$2
	file=$3
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		accounting_success "$job_id" "$expected_cpu" "$file" && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

pending_cancel_accounting()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
	$1 == job && $2 == user && $3 ~ /^CANCELLED/ { job_ok = 1 }
	$1 == job ".0" { step_seen = 1 }
	END { exit !(job_ok && !step_seen) }
	' "$file"
}

wait_pending_cancel_accounting()
{
	job_id=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		pending_cancel_accounting "$job_id" "$file" && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	for job_id in $active_jobs; do
		cancel_if_active "$job_id"
	done
	if [ -n "$client_pid" ]; then
		/bin/kill "$client_pid" >/dev/null 2>&1 || true
	fi
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf '%s\n' \
			"recovery: no production configuration was changed; inspect run_dir=$run_dir" >&2
	fi
	exit "$rc"
}

run_capacity_case()
{
	case_label=$1
	task_count=$2
	record_dir=${run_dir}/${case_label}-records
	out_file=${run_dir}/${case_label}.out
	err_file=${run_dir}/${case_label}.err
	accounting_file=${run_dir}/${case_label}-sacct.txt
	job_name=smd108-${case_label}-${run_stamp}

	/bin/mkdir -m 0700 "$record_dir" || fail "cannot create $case_label record directory"
	/usr/sbin/chown "$test_uid:$test_gid" "$record_dir" || \
		fail "cannot chown $case_label record directory"

	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
		SLURM_CONF="$client_conf" \
		"$srun" --partition="$partition" --nodes=1 --ntasks="$task_count" \
		--cpus-per-task=1 --mem=256M --time=00:01:00 --chdir=/tmp \
		--mpi=none --kill-on-bad-exit=1 --job-name="$job_name" \
		"$payload" "$case_label" "$record_dir" >"$out_file" 2>"$err_file" &
	client_pid=$!

	attempt=0
	ready_count=0
	while [ "$attempt" -lt 300 ]; do
		ready_count=$(/usr/bin/find "$record_dir" -type f -name 'ready.*' |
			/usr/bin/wc -l | /usr/bin/tr -d ' ')
		[ "$ready_count" = "$task_count" ] && break
		/bin/kill -0 "$client_pid" >/dev/null 2>&1 || \
			fail "$case_label srun exited before barrier ready_count=$ready_count"
		/bin/sleep 0.1
		attempt=$((attempt + 1))
	done
	[ "$ready_count" = "$task_count" ] || \
		fail "$case_label barrier timeout count=$ready_count expected=$task_count"

	job_id=$(/usr/bin/awk -F '=' '$1 == "job_id" { print $2 }' \
		"${record_dir}"/ready.* | /usr/bin/sort -u)
	case "$job_id" in
	''|*[!0-9]*) fail "$case_label invalid or non-unique job id=$job_id" ;;
	esac
	active_jobs="$active_jobs $job_id"
	[ "$(queue_state "$job_id")" = RUNNING ] || \
		fail "$case_label job is not RUNNING at barrier"

	/usr/bin/awk -v count="$task_count" 'BEGIN {
		for (i = 0; i < count; i++) print i
	}' >"${run_dir}/${case_label}-expected-ranks.txt"
	for record in "${record_dir}"/ready.*; do
		/usr/bin/awk -F '=' '$1 == "proc_id" { print $2 }' "$record" \
			>>"${run_dir}/${case_label}-actual-ranks.txt"
		/usr/bin/grep -Fqx "case=$case_label" "$record" || \
			fail "$case_label label mismatch in $record"
		/usr/bin/grep -Fqx "task_count=$task_count" "$record" || \
			fail "$case_label task count mismatch in $record"
		/usr/bin/grep -Fqx "step_task_count=$task_count" "$record" || \
			fail "$case_label step task count mismatch in $record"
		/usr/bin/grep -Fqx "uid=$test_uid" "$record" || \
			fail "$case_label UID mismatch in $record"
		/usr/bin/grep -Fqx "gid=$test_gid" "$record" || \
			fail "$case_label GID mismatch in $record"
		task_pid=$(/usr/bin/awk -F '=' '$1 == "pid" { print $2 }' "$record")
		case "$task_pid" in
		''|*[!0-9]*) fail "$case_label invalid task PID=$task_pid" ;;
		esac
		/bin/kill -0 "$task_pid" >/dev/null 2>&1 || \
			fail "$case_label task is not alive pid=$task_pid"
		/usr/bin/printf '%s\n' "$task_pid" >>"${run_dir}/${case_label}-task-pids.txt"
	done
	/usr/bin/sort -n "${run_dir}/${case_label}-actual-ranks.txt" \
		-o "${run_dir}/${case_label}-actual-ranks.txt"
	/usr/bin/cmp -s "${run_dir}/${case_label}-expected-ranks.txt" \
		"${run_dir}/${case_label}-actual-ranks.txt" || \
		fail "$case_label task rank set mismatch"
	unique_pids=$(/usr/bin/sort -n "${run_dir}/${case_label}-task-pids.txt" |
		/usr/bin/uniq | /usr/bin/wc -l | /usr/bin/tr -d ' ')
	[ "$unique_pids" = "$task_count" ] || fail "$case_label task PID count mismatch"

	/usr/bin/printf 'release=YES\n' >"${record_dir}/release"
	/usr/bin/printf 'capacity_case=%s job_id=%s tasks=%s live_pids=%s\n' \
		"$case_label" "$job_id" "$task_count" "$unique_pids"
	wait "$client_pid"
	srun_rc=$?
	client_pid=
	[ "$srun_rc" -eq 0 ] || fail "$case_label srun failed rc=$srun_rc"
	[ ! -s "$err_file" ] || fail "$case_label stderr is not empty"
	[ "$(/usr/bin/grep -c '^record=cpu-task ' "$out_file")" = "$task_count" ] || \
		fail "$case_label stdout task count mismatch"
	wait_job_gone "$job_id" || fail "$case_label job remained in queue"
	wait_success_accounting "$job_id" "$task_count" "$accounting_file" || \
		fail "$case_label accounting mismatch expected_cpu=$task_count"
	case_job_id=$job_id
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$scontrol" "$squeue" "$srun" \
	"$scancel" "$sacct" "$pid_file" "$source_payload" "$source_driver"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for command in /usr/bin/awk /usr/bin/cmp /usr/bin/dscacheutil /usr/bin/find \
	/usr/bin/grep /usr/bin/id /usr/bin/pgrep /usr/bin/shasum /usr/bin/sort \
	/usr/bin/sudo /usr/bin/tr /usr/bin/uniq /usr/bin/wc /usr/sbin/chown \
	/usr/sbin/ipconfig /bin/cat /bin/chmod /bin/cp /bin/date /bin/hostname \
	/bin/kill /bin/mkdir /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/cp "$source_payload" "$payload" || fail 'cannot stage payload'
/bin/chmod 0555 "$payload" || fail 'cannot set payload mode'
/usr/sbin/chown 0:0 "$payload" || fail 'cannot set payload owner'
/usr/bin/printf 'run_dir=%s\n' "$run_dir"

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

cpu_total=$(node_field CPUTot "${run_dir}/node-before.txt")
case "$cpu_total" in
''|*[!0-9]*) fail "invalid CPUTot=$cpu_total" ;;
esac
[ "$cpu_total" -ge "$below_count" ] || fail "CPUTot=$cpu_total is below test minimum"
equal_count=$cpu_total
over_count=$((cpu_total + 1))
"$scontrol" show partition "$partition" >"${run_dir}/partition-before.txt" || \
	fail 'partition readback failed'
/usr/bin/printf 'cpu_total=%s below=%s equal=%s over=%s\n' \
	"$cpu_total" "$below_count" "$equal_count" "$over_count"

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
/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" "$source_driver" \
	>"${run_dir}/inputs-before.sha256"

run_capacity_case below "$below_count"
below_job=$case_job_id
case "$below_job" in
''|*[!0-9]*) fail "invalid below-capacity job id=$below_job" ;;
esac

run_capacity_case equal "$equal_count"
equal_job=$case_job_id
case "$equal_job" in
''|*[!0-9]*) fail "invalid equal-capacity job id=$equal_job" ;;
esac

over_record_dir=${run_dir}/over-records
over_out=${run_dir}/over.out
over_err=${run_dir}/over.err
over_name=smd108-over-${run_stamp}
/bin/mkdir -m 0700 "$over_record_dir" || fail 'cannot create over record directory'
/usr/sbin/chown "$test_uid:$test_gid" "$over_record_dir" || \
	fail 'cannot chown over record directory'
/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
	SLURM_CONF="$client_conf" \
	"$srun" --partition="$partition" --nodes=1 --ntasks="$over_count" \
	--cpus-per-task=1 --mem=256M --time=00:01:00 --chdir=/tmp \
	--mpi=none --kill-on-bad-exit=1 --job-name="$over_name" \
	"$payload" over "$over_record_dir" >"$over_out" 2>"$over_err" &
client_pid=$!

attempt=0
while [ "$attempt" -lt 30 ]; do
	over_job=$("$squeue" -h -n "$over_name" -u "$test_user" -o '%A' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }')
	case "$over_job" in
	''|*[!0-9]*) ;;
	*) break ;;
	esac
	/bin/kill -0 "$client_pid" >/dev/null 2>&1 || \
		fail 'over-capacity srun exited before queue observation'
	/bin/sleep 1
	attempt=$((attempt + 1))
done
case "$over_job" in
''|*[!0-9]*) fail "cannot discover over-capacity job id=$over_job" ;;
esac
active_jobs="$active_jobs $over_job"

observation=0
while [ "$observation" -lt 5 ]; do
	"$squeue" -h -j "$over_job" -o '%T|%R' >"${run_dir}/over-pending-${observation}.txt"
	over_state=$(/usr/bin/awk -F '|' 'NR == 1 { print $1 }' \
		"${run_dir}/over-pending-${observation}.txt")
	[ "$over_state" = PENDING ] || \
		fail "over-capacity job state=$over_state expected=PENDING"
	[ -z "$(/usr/bin/find "$over_record_dir" -type f -print -quit)" ] || \
		fail 'over-capacity payload executed unexpectedly'
	/bin/kill -0 "$client_pid" >/dev/null 2>&1 || \
		fail 'over-capacity srun client exited during pending observation'
	/bin/sleep 1
	observation=$((observation + 1))
done
over_reason=$(/usr/bin/awk -F '|' 'NR == 1 { print $2 }' \
	"${run_dir}/over-pending-4.txt")
[ -n "$over_reason" ] || fail 'over-capacity pending reason is empty'
/usr/bin/printf '%s%s%s\n' \
	"over_capacity=BLOCKED job_id=$over_job requested_cpu=$over_count" \
	" state=PENDING reason=$over_reason observed_seconds=5" \
	' payload_executed=NO'
"$scancel" "$over_job" || fail 'cannot cancel over-capacity pending job'
wait "$client_pid"
over_client_rc=$?
client_pid=
/usr/bin/printf 'over_cancel_client_rc=%s\n' "$over_client_rc"
wait_job_gone "$over_job" || fail 'over-capacity job remained in queue'
[ -z "$(/usr/bin/find "$over_record_dir" -type f -print -quit)" ] || \
	fail 'over-capacity payload record appeared after cancel'
/usr/bin/grep -q '^record=cpu-task ' "$over_out" && \
	fail 'over-capacity stdout contains payload record'
wait_pending_cancel_accounting "$over_job" "${run_dir}/over-sacct.txt" || \
	fail 'over-capacity pending cancel accounting mismatch'

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
/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" "$source_driver" \
	>"${run_dir}/inputs-after.sha256"
/usr/bin/cmp -s "${run_dir}/inputs-before.sha256" "${run_dir}/inputs-after.sha256" || \
	fail 'production config or test source changed during test'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s%s%s\n' \
	"SMD108_CPU_OVERCOMMIT_COMPLETE below_job=$below_job below_cpu=$below_count" \
	" equal_job=$equal_job equal_cpu=$equal_count" \
	" over_job=$over_job over_cpu=$over_count over_state=CANCELLED_NOT_EXECUTED" \
	" slurmd_pid=$slurmd_pid production_unchanged=PASS" \
	" run_dir=$run_dir"
