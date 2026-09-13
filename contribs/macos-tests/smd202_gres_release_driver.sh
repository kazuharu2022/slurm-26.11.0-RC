#!/bin/sh

set -u

if [ "${SMD202_GRES_RELEASE_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD202_GRES_RELEASE_CONFIRMED=YES after confirming PC-210 is idle' >&2
	exit 64
fi

mode=${1:-}
case "$mode" in
normal|cancel|timeout|signal|crash) ;;
'')
	/usr/bin/printf '%s\n' 'error: mode is required: normal|cancel|timeout|signal|crash' >&2
	exit 64
	;;
*)
	/usr/bin/printf 'error: unsupported mode=%s\n' "$mode" >&2
	exit 64
	;;
esac

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
run_dir=/tmp/slurm-smd202-${mode}-${run_stamp}
output_dir=${run_dir}/output
payload=${run_dir}/gres-release-payload.sh
target_job=
probe_job=
target_payload_pid=
target_child_pid=
probe_payload_pid=
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

capture_accounting()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
}

accounting_matches()
{
	kind=$1
	job_id=$2
	file=$3
	capture_accounting "$job_id" "$file"
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" -v kind="$kind" '
		$1 == job && $2 == user {
			if (kind == "normal" || kind == "probe")
				job_ok = ($3 == "COMPLETED" && $4 == "0:0")
			else if (kind == "cancel")
				job_ok = ($3 ~ /^CANCELLED/)
			else if (kind == "timeout")
				job_ok = ($3 == "TIMEOUT")
			else if (kind == "signal")
				job_ok = ($3 == "FAILED" && $4 != "0:0")
			else if (kind == "crash")
				job_ok = ($3 == "FAILED" && $4 ~ /^[0-9]+:11$/)
		}
		$1 == job ".batch" {
			if (kind == "normal" || kind == "probe")
				batch_ok = ($3 == "COMPLETED" && $4 == "0:0")
			else if (kind == "cancel")
				batch_ok = ($3 ~ /^CANCELLED/)
			else if (kind == "timeout")
				batch_ok = (($3 == "FAILED" || $3 ~ /^CANCELLED/) && $4 != "0:0")
			else if (kind == "signal")
				batch_ok = ($3 == "FAILED" && $4 != "0:0")
			else if (kind == "crash")
				batch_ok = (($3 == "FAILED" || $3 ~ /^CANCELLED/) &&
					$4 ~ /^[0-9]+:11$/)
		}
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
		accounting_matches "$kind" "$job_id" "$file" && return 0
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

wait_pid_absent()
{
	pid=$1
	case "$pid" in
	''|*[!0-9]*) return 1 ;;
	esac
	attempt=0
	while [ "$attempt" -lt 30 ]; do
		if ! /bin/kill -0 "$pid" >/dev/null 2>&1; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

verify_mlx_output()
{
	file=$1
	/usr/bin/grep -Fq 'job_gpus=0' "$file" || return 1
	/usr/bin/grep -Fq 'slurm_job_gpus=0' "$file" || return 1
	/usr/bin/grep -Fq 'machine=arm64' "$file" || return 1
	/usr/bin/grep -Fq 'mlx_version=0.32.2' "$file" || return 1
	/usr/bin/grep -Fq 'default_device=Device(gpu, 0)' "$file" || return 1
	/usr/bin/grep -Fq "'device_name': 'Apple M5 Max'" "$file" || return 1
	/usr/bin/grep -Fq 'gpu_smoke_test=PASS' "$file" || return 1
	/usr/bin/grep -Fq "actual_uid=${test_uid}" "$file" || return 1
	/usr/bin/grep -Fq "actual_gid=${test_gid}" "$file" || return 1
	return 0
}

make_output_readable()
{
	[ -d "$output_dir" ] || return 0
	/bin/chmod 0755 "$output_dir" || return 1
	if [ -n "$target_job" ]; then
		for file in "${output_dir}/target-${target_job}.out" \
			"${output_dir}/target-${target_job}.err"; do
			[ ! -f "$file" ] || /bin/chmod 0644 "$file" || return 1
		done
	fi
	if [ -n "$probe_job" ]; then
		for file in "${output_dir}/probe-${probe_job}.out" \
			"${output_dir}/probe-${probe_job}.err"; do
			[ ! -f "$file" ] || /bin/chmod 0644 "$file" || return 1
		done
	fi
	return 0
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$target_job"
	cancel_if_active "$probe_job"
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
	/usr/bin/shasum /usr/bin/sudo /usr/bin/tail /usr/bin/tr /usr/bin/wc \
	/usr/sbin/chown /bin/bash /bin/cat /bin/chmod /bin/date /bin/kill \
	/bin/mkdir /bin/ps /bin/sleep; do
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

mode=${1:?missing mode}
mlx_job=${2:?missing MLX job path}

echo "mode=${mode}"
echo "payload_pid=$$"
echo "actual_uid=$(/usr/bin/id -u)"
echo "actual_gid=$(/usr/bin/id -g)"
echo "job_gpus=${SLURM_JOB_GPUS:-unset}"
/bin/bash "$mlx_job"
echo "case_ready mode=${mode} job_id=${SLURM_JOB_ID:-unset}"

case "$mode" in
normal|probe)
	echo "case_complete mode=${mode} job_id=${SLURM_JOB_ID:-unset}"
	exit 0
	;;
cancel|timeout)
	/bin/sleep 180 &
	child_pid=$!
	echo "child_pid=${child_pid}"
	wait "$child_pid"
	;;
signal)
	trap 'echo signal_received=USR1; exit 91' USR1
	/bin/sleep 180 &
	child_pid=$!
	echo "child_pid=${child_pid}"
	wait "$child_pid"
	;;
crash)
	echo 'crash_signal=SEGV'
	/bin/kill -SEGV "$$"
	;;
*)
	echo "unexpected_mode=${mode}" >&2
	exit 64
	;;
esac
EOF
/bin/chmod 0555 "$payload" || fail 'cannot set payload mode'
/usr/sbin/chown 0:0 "$payload" || fail 'cannot set payload owner'
/usr/bin/printf 'mode=%s run_dir=%s mlx_job=%s\n' "$mode" "$run_dir" "$mlx_job"

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

case "$mode" in
normal|crash) target_time=00:01:00 ;;
cancel|signal) target_time=00:02:00 ;;
timeout) target_time=00:01:00 ;;
esac

target_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=256M --gres=gpu:apple:1 --time="$target_time" \
		--no-requeue --chdir=/tmp --job-name="smd202-${mode}" \
		--output="${output_dir}/target-%j.out" --error="${output_dir}/target-%j.err" \
		"$payload" "$mode" "$mlx_job"
) || fail 'target GPU job submission failed'
target_job=${target_job%%;*}
case "$target_job" in
''|*[!0-9]*) fail "invalid target job id=$target_job" ;;
esac
/usr/bin/printf 'submitted mode=%s target_job=%s\n' "$mode" "$target_job"

wait_marker "$target_job" "${output_dir}/target-${target_job}.out" \
	"case_ready mode=${mode} job_id=${target_job}" || fail 'target GPU job did not reach ready marker'
/usr/bin/printf 'target_ready mode=%s job_id=%s\n' "$mode" "$target_job"
verify_mlx_output "${output_dir}/target-${target_job}.out" || fail 'target MLX evidence mismatch'
target_payload_pid=$(output_field "${output_dir}/target-${target_job}.out" payload_pid)
case "$target_payload_pid" in
''|*[!0-9]*) fail "invalid target payload pid=$target_payload_pid" ;;
esac

case "$mode" in
normal|crash)
	;;
cancel)
	wait_marker "$target_job" "${output_dir}/target-${target_job}.out" \
		'child_pid=' || fail 'cancel target child PID was not recorded'
	target_child_pid=$(output_field "${output_dir}/target-${target_job}.out" child_pid)
	case "$target_child_pid" in
	''|*[!0-9]*) fail "invalid target child pid=$target_child_pid" ;;
	esac
	"$scancel" "$target_job" || fail 'cannot cancel target GPU job'
	/usr/bin/printf 'terminate mode=cancel job_id=%s action=scancel\n' "$target_job"
	;;
timeout)
	wait_marker "$target_job" "${output_dir}/target-${target_job}.out" \
		'child_pid=' || fail 'timeout target child PID was not recorded'
	target_child_pid=$(output_field "${output_dir}/target-${target_job}.out" child_pid)
	case "$target_child_pid" in
	''|*[!0-9]*) fail "invalid target child pid=$target_child_pid" ;;
	esac
	/usr/bin/printf 'terminate mode=timeout job_id=%s action=time_limit\n' "$target_job"
	;;
signal)
	wait_marker "$target_job" "${output_dir}/target-${target_job}.out" \
		'child_pid=' || fail 'signal target child PID was not recorded'
	target_child_pid=$(output_field "${output_dir}/target-${target_job}.out" child_pid)
	case "$target_child_pid" in
	''|*[!0-9]*) fail "invalid target child pid=$target_child_pid" ;;
	esac
	"$scancel" --signal=USR1 --full "$target_job" || fail 'cannot signal target GPU job'
	/usr/bin/printf 'terminate mode=signal job_id=%s signal=USR1 scope=full\n' "$target_job"
	;;
esac

wait_job_gone "$target_job" || fail 'target GPU job remained in queue'
wait_accounting "$mode" "$target_job" "${run_dir}/target-sacct.txt" || \
	fail "target accounting mismatch mode=$mode"
wait_pid_absent "$target_payload_pid" || fail "target payload remains pid=$target_payload_pid"
if [ -n "$target_child_pid" ]; then
	case "$target_child_pid" in
	*[!0-9]*) fail "invalid target child pid=$target_child_pid" ;;
	esac
	wait_pid_absent "$target_child_pid" || fail "target child remains pid=$target_child_pid"
fi
if [ "$mode" = signal ]; then
	/usr/bin/grep -Fq 'signal_received=USR1' "${output_dir}/target-${target_job}.out" || \
		fail 'USR1 trap evidence missing'
fi
if [ "$mode" = crash ]; then
	/usr/bin/grep -Fq 'crash_signal=SEGV' "${output_dir}/target-${target_job}.out" || \
		fail 'SEGV crash marker missing'
fi

"$scontrol" show node "$node_name" >"${run_dir}/node-after-target.txt" || \
	fail 'node readback after target failed'
[ "$(node_field State "${run_dir}/node-after-target.txt")" = IDLE ] || \
	fail 'node is not IDLE after target'
[ "$(node_field CPUAlloc "${run_dir}/node-after-target.txt")" = 0 ] || \
	fail 'CPUAlloc is not zero after target'
[ "$(node_field AllocMem "${run_dir}/node-after-target.txt")" = 0 ] || \
	fail 'AllocMem is not zero after target'

probe_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=256M --gres=gpu:apple:1 --time=00:01:00 \
		--no-requeue --chdir=/tmp --job-name="smd202-${mode}-probe" \
		--output="${output_dir}/probe-%j.out" --error="${output_dir}/probe-%j.err" \
		"$payload" probe "$mlx_job"
) || fail 'post-release GPU probe submission failed'
probe_job=${probe_job%%;*}
case "$probe_job" in
''|*[!0-9]*) fail "invalid probe job id=$probe_job" ;;
esac
/usr/bin/printf 'submitted mode=%s probe_job=%s\n' "$mode" "$probe_job"
wait_marker "$probe_job" "${output_dir}/probe-${probe_job}.out" \
	"case_complete mode=probe job_id=${probe_job}" || fail 'post-release GPU probe did not complete payload'
wait_job_gone "$probe_job" || fail 'post-release GPU probe remained in queue'
wait_accounting probe "$probe_job" "${run_dir}/probe-sacct.txt" || \
	fail 'post-release GPU probe accounting did not reach COMPLETED 0:0'
verify_mlx_output "${output_dir}/probe-${probe_job}.out" || fail 'probe MLX evidence mismatch'
probe_payload_pid=$(output_field "${output_dir}/probe-${probe_job}.out" payload_pid)
wait_pid_absent "$probe_payload_pid" || fail "probe payload remains pid=$probe_payload_pid"
[ ! -s "${output_dir}/probe-${probe_job}.err" ] || fail 'post-release GPU probe stderr is not empty'

log_size_after=$(/usr/bin/wc -c <"$slurmd_log" | /usr/bin/tr -d ' ')
case "$log_size_after" in
''|*[!0-9]*) fail "invalid final log size=$log_size_after" ;;
esac
[ "$log_size_after" -ge "$log_size_before" ] || fail 'slurmd log rotated during SMD-202'
/usr/bin/tail -c "+$((log_size_before + 1))" "$slurmd_log" \
	>"${run_dir}/slurmd-log-delta.txt"
for job_id in "$target_job" "$probe_job"; do
	/usr/bin/grep -Fq "Launching batch JobId=${job_id}" \
		"${run_dir}/slurmd-log-delta.txt" || fail "slurmd log lacks launch job=$job_id"
done
/usr/bin/grep -Fq "[${probe_job}.batch] done with step" \
	"${run_dir}/slurmd-log-delta.txt" || fail 'slurmd log lacks probe completion'

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final node queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed during SMD-202'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-after.txt" 2>/dev/null; then
	fail 'slurmstepd remains after GRES release test'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-after.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-after.txt" \
	>"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'SMD-202 payload process remains'

make_output_readable || fail 'cannot make output evidence readable'
success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD202_GRES_RELEASE_PHASE_COMPLETE mode=%s target_job=%s probe_job=%s probe_state=COMPLETED slurmd_pid=%s run_dir=%s\n' \
	"$mode" "$target_job" "$probe_job" "$slurmd_pid" "$run_dir"
