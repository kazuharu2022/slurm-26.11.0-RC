#!/bin/sh

set -u

if [ "${SMD201_GPU_EXCLUSIVITY_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD201_GPU_EXCLUSIVITY_CONFIRMED=YES after confirming PC-210 is idle' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
mlx_job=${prefix}/share/macos-gpu-job/mlx_gpu_smoke.sbatch
pid_file=/var/run/slurmd.pid
slurmd_log=/var/log/slurm/slurmd.log
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd201-${run_stamp}
output_dir=${run_dir}/output
payload=${run_dir}/gpu-exclusivity-payload.sh
first_job=
second_job=
first_payload_pid=
first_hold_pid=
second_payload_pid=
second_hold_pid=
slurmd_pid=
log_size_before=0
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

job_field()
{
	job_id=$1
	field=$2
	"$scontrol" -o show job "$job_id" 2>/dev/null |
		/usr/bin/awk -v key="${field}=" '
		{
			for (i = 1; i <= NF; i++) {
				if (index($i, key) == 1) {
					sub(key, "", $i)
					print $i
					exit
				}
			}
		}'
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

wait_marker()
{
	job_id=$1
	file=$2
	marker=$3
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		if [ -f "$file" ] && /usr/bin/grep -Fq "$marker" "$file"; then
			return 0
		fi
		state=$(queue_state "$job_id")
		case "$state" in
		RUNNING|COMPLETING|PENDING) ;;
		'') return 1 ;;
		*) return 1 ;;
		esac
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_exclusive_pending()
{
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		first_state=$(queue_state "$first_job")
		second_state=$(queue_state "$second_job")
		second_reason=$(job_field "$second_job" Reason)
		if [ "$first_state" = RUNNING ] && [ "$second_state" = PENDING ] && \
			[ "$second_reason" = Resources ]; then
			/usr/bin/printf 'exclusive_pending first_job=%s state=%s second_job=%s state=%s reason=%s wait_seconds=%s\n' \
				"$first_job" "$first_state" "$second_job" "$second_state" \
				"$second_reason" "$attempt"
			return 0
		fi
		if [ "$second_state" = RUNNING ] || [ -z "$first_state" ] || \
			[ -z "$second_state" ]; then
			return 1
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

accounting_cancelled_batch()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 ~ /^CANCELLED/ { job_ok = 1 }
		$1 == job ".batch" && $3 ~ /^CANCELLED/ { batch_ok = 1 }
		END { exit !(job_ok && batch_ok) }
	' "$file"
}

accounting_completed_batch()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { job_ok = 1 }
		$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" { batch_ok = 1 }
		END { exit !(job_ok && batch_ok) }
	' "$file"
}

wait_accounting()
{
	kind=$1
	job_id=$2
	file=$3
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if [ "$kind" = cancelled ]; then
			accounting_cancelled_batch "$job_id" "$file" && return 0
		else
			accounting_completed_batch "$job_id" "$file" && return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

pid_absent()
{
	pid=$1
	case "$pid" in
	''|*[!0-9]*) return 1 ;;
	esac
	! /bin/kill -0 "$pid" >/dev/null 2>&1
}

wait_pid_absent()
{
	pid=$1
	attempt=0
	while [ "$attempt" -lt 30 ]; do
		if pid_absent "$pid"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

output_field()
{
	file=$1
	key=$2
	/usr/bin/awk -F '=' -v key="$key" '$1 == key { print $2; exit }' "$file"
}

make_output_readable()
{
	[ -d "$output_dir" ] || return 0
	/bin/chmod 0755 "$output_dir" || return 1
	if [ -n "$first_job" ]; then
		for file in "${output_dir}/first-${first_job}.out" \
			"${output_dir}/first-${first_job}.err"; do
			[ ! -f "$file" ] || /bin/chmod 0644 "$file" || return 1
		done
	fi
	if [ -n "$second_job" ]; then
		for file in "${output_dir}/second-${second_job}.out" \
			"${output_dir}/second-${second_job}.err"; do
			[ ! -f "$file" ] || /bin/chmod 0644 "$file" || return 1
		done
	fi
	return 0
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$first_job"
	cancel_if_active "$second_job"
	if ! make_output_readable; then
		/usr/bin/printf 'warning: could not make output evidence readable\n' >&2
		rc=1
	fi
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: no production configuration was changed; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" \
	"$scancel" "$sacct" "$mlx_job" "$pid_file" "$slurmd_log"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for command in /usr/bin/awk /usr/bin/grep /usr/bin/id /usr/bin/pgrep \
	/usr/bin/shasum /usr/bin/sort /usr/bin/sudo /usr/bin/tail /usr/bin/tr \
	/usr/bin/wc /usr/sbin/chown /bin/bash /bin/cat /bin/chmod /bin/date \
	/bin/hostname /bin/kill /bin/mkdir /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'

/bin/cat >"$payload" <<'EOF'
#!/bin/bash
set -euo pipefail

case_name=${1:?missing case name}
hold_seconds=${2:?missing hold seconds}
mlx_job=${3:?missing MLX job path}

echo "case=${case_name}"
echo "payload_pid=$$"
echo "actual_uid=$(/usr/bin/id -u)"
echo "actual_gid=$(/usr/bin/id -g)"
echo "job_gpus=${SLURM_JOB_GPUS:-unset}"
/bin/bash "$mlx_job"
echo "scheduler_ready case=${case_name} job_id=${SLURM_JOB_ID:-unset}"
/bin/sleep "$hold_seconds" &
hold_pid=$!
echo "hold_pid=${hold_pid}"
wait "$hold_pid"
echo "scheduler_complete case=${case_name} job_id=${SLURM_JOB_ID:-unset}"
EOF
/bin/chmod 0555 "$payload" || fail 'cannot set payload mode'
/usr/sbin/chown 0:0 "$payload" || fail 'cannot set payload owner'
/usr/bin/printf 'run_dir=%s mlx_job=%s\n' "$run_dir" "$mlx_job"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
/usr/bin/grep -Fq 'Gres=gpu:apple:1' "${run_dir}/node-before.txt" || fail 'gpu:apple:1 is not registered'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail "slurmd pid=$slurmd_pid is not running"
/usr/bin/shasum -a 256 "$mlx_job" >"${run_dir}/mlx-job.sha256"
log_size_before=$(/usr/bin/wc -c <"$slurmd_log" | /usr/bin/tr -d ' ')
case "$log_size_before" in
''|*[!0-9]*) fail "invalid initial log size=$log_size_before" ;;
esac

first_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=256M --gres=gpu:apple:1 --time=00:03:00 \
		--chdir=/tmp --job-name=smd201-first \
		--output="${output_dir}/first-%j.out" --error="${output_dir}/first-%j.err" \
		"$payload" first 120 "$mlx_job"
) || fail 'first GPU job submission failed'
first_job=${first_job%%;*}
case "$first_job" in
''|*[!0-9]*) fail "invalid first job id=$first_job" ;;
esac
/usr/bin/printf 'submitted first_job=%s\n' "$first_job"
wait_marker "$first_job" "${output_dir}/first-${first_job}.out" \
	"scheduler_ready case=first job_id=${first_job}" || fail 'first GPU job did not become ready'
/usr/bin/printf 'first_ready job_id=%s\n' "$first_job"

first_payload_pid=$(output_field "${output_dir}/first-${first_job}.out" payload_pid)
first_hold_pid=$(output_field "${output_dir}/first-${first_job}.out" hold_pid)
case "$first_payload_pid" in
''|*[!0-9]*) fail "invalid first payload pid=$first_payload_pid" ;;
esac
case "$first_hold_pid" in
''|*[!0-9]*) fail "invalid first hold pid=$first_hold_pid" ;;
esac

second_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=256M --gres=gpu:apple:1 --time=00:02:00 \
		--chdir=/tmp --job-name=smd201-second \
		--output="${output_dir}/second-%j.out" --error="${output_dir}/second-%j.err" \
		"$payload" second 0 "$mlx_job"
) || fail 'second GPU job submission failed'
second_job=${second_job%%;*}
case "$second_job" in
''|*[!0-9]*) fail "invalid second job id=$second_job" ;;
esac
/usr/bin/printf 'submitted second_job=%s\n' "$second_job"

wait_exclusive_pending || fail 'second GPU job was not held pending for Resources'
"$squeue" -h -j "${first_job},${second_job}" -o '%i|%T|%R|%N' \
	>"${run_dir}/queue-exclusive.txt" || fail 'cannot capture exclusive queue state'
"$scontrol" -o show job "$first_job" >"${run_dir}/first-job-exclusive.txt" || \
	fail 'cannot capture first job state'
"$scontrol" -o show job "$second_job" >"${run_dir}/second-job-exclusive.txt" || \
	fail 'cannot capture second job state'
"$scontrol" show node "$node_name" >"${run_dir}/node-exclusive.txt" || \
	fail 'cannot capture node allocation state'
[ ! -f "${output_dir}/second-${second_job}.out" ] || \
	! /usr/bin/grep -Fq 'scheduler_ready case=second' \
		"${output_dir}/second-${second_job}.out" || \
	fail 'second GPU payload executed before first released the GRES'

"$scancel" "$first_job" || fail 'cannot cancel first GPU job'
/usr/bin/printf 'cancel first_job=%s\n' "$first_job"
wait_job_gone "$first_job" || fail 'first GPU job remained in queue'
wait_accounting cancelled "$first_job" "${run_dir}/first-sacct.txt" || \
	fail 'first GPU job accounting did not reach CANCELLED'
wait_pid_absent "$first_payload_pid" || fail "first payload remains pid=$first_payload_pid"
wait_pid_absent "$first_hold_pid" || fail "first hold process remains pid=$first_hold_pid"

wait_marker "$second_job" "${output_dir}/second-${second_job}.out" \
	"scheduler_complete case=second job_id=${second_job}" || \
	fail 'second GPU job did not run after first released the GRES'
wait_job_gone "$second_job" || fail 'second GPU job remained in queue'
wait_accounting completed "$second_job" "${run_dir}/second-sacct.txt" || \
	fail 'second GPU job accounting did not reach COMPLETED 0:0'

for file in "${output_dir}/first-${first_job}.out" \
	"${output_dir}/second-${second_job}.out"; do
	/usr/bin/grep -Fq 'job_gpus=0' "$file" || fail "missing wrapper GRES environment in $file"
	/usr/bin/grep -Fq 'slurm_job_gpus=0' "$file" || fail "missing MLX GRES environment in $file"
	/usr/bin/grep -Fq 'default_device=Device(gpu, 0)' "$file" || fail "MLX default device is not GPU in $file"
	/usr/bin/grep -Fq 'gpu_smoke_test=PASS' "$file" || fail "MLX smoke test failed in $file"
	/usr/bin/grep -Fq "actual_uid=${test_uid}" "$file" || fail "UID mismatch in $file"
	/usr/bin/grep -Fq "actual_gid=${test_gid}" "$file" || fail "GID mismatch in $file"
done

second_payload_pid=$(output_field "${output_dir}/second-${second_job}.out" payload_pid)
second_hold_pid=$(output_field "${output_dir}/second-${second_job}.out" hold_pid)
case "$second_payload_pid" in
''|*[!0-9]*) fail "invalid second payload pid=$second_payload_pid" ;;
esac
case "$second_hold_pid" in
''|*[!0-9]*) fail "invalid second hold pid=$second_hold_pid" ;;
esac
wait_pid_absent "$second_payload_pid" || fail "second payload remains pid=$second_payload_pid"
wait_pid_absent "$second_hold_pid" || fail "second hold process remains pid=$second_hold_pid"
[ ! -s "${output_dir}/second-${second_job}.err" ] || fail 'second GPU job stderr is not empty'

log_size_after=$(/usr/bin/wc -c <"$slurmd_log" | /usr/bin/tr -d ' ')
case "$log_size_after" in
''|*[!0-9]*) fail "invalid final log size=$log_size_after" ;;
esac
[ "$log_size_after" -ge "$log_size_before" ] || fail 'slurmd log rotated during SMD-201'
/usr/bin/tail -c "+$((log_size_before + 1))" "$slurmd_log" \
	>"${run_dir}/slurmd-log-delta.txt"
for job_id in "$first_job" "$second_job"; do
	/usr/bin/grep -Fq "Launching batch JobId=${job_id}" \
		"${run_dir}/slurmd-log-delta.txt" || fail "slurmd log lacks launch job=$job_id"
done
/usr/bin/grep -Fq "[${first_job}.batch] error: *** JOB ${first_job} ON ${node_name} CANCELLED" \
	"${run_dir}/slurmd-log-delta.txt" || fail 'slurmd log lacks first job cancellation'
/usr/bin/grep -Fq "[${first_job}.batch] stepd_cleanup: done with step" \
	"${run_dir}/slurmd-log-delta.txt" || fail 'slurmd log lacks first job cancelled cleanup'
/usr/bin/grep -Fq "[${second_job}.batch] done with step" \
	"${run_dir}/slurmd-log-delta.txt" || fail 'slurmd log lacks second job completion'

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final node queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed during SMD-201'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-after.txt" 2>/dev/null; then
	fail 'slurmstepd remains after GPU jobs completed'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-after.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-after.txt" \
	>"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'SMD-201 payload process remains'

make_output_readable || fail 'cannot make output evidence readable'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD201_GPU_EXCLUSIVITY_COMPLETE first_job=%s first_state=CANCELLED second_job=%s second_state=COMPLETED pending_reason=Resources slurmd_pid=%s run_dir=%s\n' \
	"$first_job" "$second_job" "$slurmd_pid" "$run_dir"
