#!/bin/sh

set -u

if [ "${SMD204_GPU_COMPETITION_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD204_GPU_COMPETITION_CONFIRMED=YES after confirming PC-210 is idle' >&2
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
repeat_count=3
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd204-${run_stamp}
output_dir=${run_dir}/output
payload=${run_dir}/mlx-wrapper.sh
release_file=${run_dir}/release
baseline_job=
gres_job=
unmanaged_job=
baseline_pid=
gres_pid=
unmanaged_pid=
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
	active_job=$1
	[ -n "$active_job" ] || return 0
	state=$(queue_state "$active_job")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$active_job" "$state" >&2
		"$scancel" "$active_job" >/dev/null 2>&1 || true
	fi
}

wait_job_gone()
{
	active_job=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ -z "$(queue_state "$active_job")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' \
				"$active_job" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_marker()
{
	active_job=$1
	file=$2
	marker=$3
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		if [ -f "$file" ] && /usr/bin/grep -Fq "$marker" "$file"; then
			return 0
		fi
		state=$(queue_state "$active_job")
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

accounting_matches()
{
	active_job=$1
	expect_gpu=$2
	file=$3
	"$sacct" -j "$active_job" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES%200,AllocTRES%200 \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$active_job" -v user="$test_user" \
		-v expect_gpu="$expect_gpu" '
	function has_tres(value, expected, count, fields, i) {
		count = split(value, fields, ",")
		for (i = 1; i <= count; i++) {
			if (fields[i] == expected)
				return 1
		}
		return 0
	}
	$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" {
		state_ok = 1
		req_generic = has_tres($6, "gres/gpu=1")
		req_typed = has_tres($6, "gres/gpu:apple=1")
		alloc_generic = has_tres($7, "gres/gpu=1")
		alloc_typed = has_tres($7, "gres/gpu:apple=1")
		if (expect_gpu == "yes" && req_generic && req_typed &&
		    alloc_generic && alloc_typed)
			tres_ok = 1
		if (expect_gpu == "no" && !req_generic && !req_typed &&
		    !alloc_generic && !alloc_typed)
			tres_ok = 1
	}
	$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" {
		batch_ok = 1
	}
	END { exit !(state_ok && batch_ok && tres_ok) }
	' "$file"
}

wait_accounting()
{
	active_job=$1
	expect_gpu=$2
	file=$3
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if accounting_matches "$active_job" "$expect_gpu" "$file"; then
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

wait_pid_absent()
{
	pid=$1
	attempt=0
	case "$pid" in
	''|*[!0-9]*) return 1 ;;
	esac
	while [ "$attempt" -lt 30 ]; do
		if ! /bin/kill -0 "$pid" >/dev/null 2>&1; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

validate_mlx_output()
{
	file=$1
	active_job=$2
	case_name=$3
	expected_gpu_env=$4
	/usr/bin/grep -Fq "case=${case_name}" "$file" || return 1
	/usr/bin/grep -Fq "actual_uid=${test_uid}" "$file" || return 1
	/usr/bin/grep -Fq "actual_gid=${test_gid}" "$file" || return 1
	[ "$(/usr/bin/grep -c "^job_id=${active_job}$" "$file")" = "$repeat_count" ] || return 1
	[ "$(/usr/bin/grep -c "^slurm_job_gpus=${expected_gpu_env}$" "$file")" = "$repeat_count" ] || return 1
	[ "$(/usr/bin/grep -c '^machine=arm64$' "$file")" = "$repeat_count" ] || return 1
	[ "$(/usr/bin/grep -c '^default_device=Device(gpu, 0)$' "$file")" = "$repeat_count" ] || return 1
	[ "$(/usr/bin/grep -c "'device_name': 'Apple M5 Max'" "$file")" = "$repeat_count" ] || return 1
	[ "$(/usr/bin/grep -c '^gpu_smoke_test=PASS$' "$file")" = "$repeat_count" ] || return 1
	/usr/bin/grep -Fq "scheduler_complete case=${case_name} job_id=${active_job}" "$file"
}

mean_elapsed()
{
	/usr/bin/awk -F '=' '
	$1 == "elapsed_seconds" { sum += $2; count++ }
	END {
		if (!count) exit 1
		printf "%.6f", sum / count
	}' "$1"
}

make_output_readable()
{
	[ -d "$output_dir" ] || return 0
	/bin/chmod 0755 "$output_dir" || return 1
	for active_job in "$baseline_job" "$gres_job" "$unmanaged_job"; do
		[ -n "$active_job" ] || continue
		for file in "${output_dir}/job-${active_job}.out" \
			"${output_dir}/job-${active_job}.err"; do
			[ ! -f "$file" ] || /bin/chmod 0644 "$file" || return 1
		done
	done
	return 0
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$baseline_job"
	cancel_if_active "$gres_job"
	cancel_if_active "$unmanaged_job"
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
	/usr/bin/shasum /usr/bin/sudo /usr/bin/tail /usr/bin/touch /usr/bin/tr \
	/usr/bin/wc /usr/sbin/chown /bin/bash /bin/cat /bin/chmod /bin/date \
	/bin/kill /bin/mkdir /bin/ps /bin/sleep; do
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
repeat_count=${2:?missing repeat count}
release_file=${3:?missing release file}
mlx_job=${4:?missing MLX job}

echo "case=${case_name}"
echo "payload_pid=$$"
echo "actual_uid=$(/usr/bin/id -u)"
echo "actual_gid=$(/usr/bin/id -g)"
echo "wrapper_job_gpus=${SLURM_JOB_GPUS:-not-configured}"
echo "scheduler_ready case=${case_name} job_id=${SLURM_JOB_ID:-unset} epoch=$(/bin/date +%s)"

if [[ "${release_file}" != none ]]; then
	for ((attempt = 0; attempt < 120; attempt++)); do
		[[ ! -e "${release_file}" ]] || break
		/bin/sleep 1
	done
	[[ -e "${release_file}" ]] || {
		echo "barrier_timeout case=${case_name}" >&2
		exit 70
	}
fi

echo "compute_begin case=${case_name} epoch=$(/bin/date +%s)"
for ((iteration = 1; iteration <= repeat_count; iteration++)); do
	echo "wrapper_iteration=${iteration}"
	/bin/bash "${mlx_job}"
done
echo "compute_end case=${case_name} epoch=$(/bin/date +%s)"
echo "scheduler_complete case=${case_name} job_id=${SLURM_JOB_ID:-unset}"
EOF
/bin/chmod 0555 "$payload" || fail 'cannot set payload mode'
/usr/sbin/chown 0:0 "$payload" || fail 'cannot set payload owner'
/usr/bin/printf 'run_dir=%s mlx_job=%s repeat_count=%s\n' \
	"$run_dir" "$mlx_job" "$repeat_count"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
/usr/bin/grep -Fq 'Gres=gpu:apple:1' "${run_dir}/node-before.txt" || \
	fail 'gpu:apple:1 is not registered'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail "slurmd pid=$slurmd_pid is not running"
/usr/bin/shasum -a 256 "$slurm_conf" >"${run_dir}/local-config.sha256"
/usr/bin/shasum -a 256 "$mlx_job" >"${run_dir}/mlx-job.sha256"
log_size_before=$(/usr/bin/wc -c <"$slurmd_log" | /usr/bin/tr -d ' ')
case "$log_size_before" in
''|*[!0-9]*) fail "invalid initial log size=$log_size_before" ;;
esac

baseline_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=2 --mem=4G --time=00:02:00 --chdir=/tmp \
		--job-name=smd204-baseline --output="${output_dir}/job-%j.out" \
		--error="${output_dir}/job-%j.err" \
		"$payload" baseline "$repeat_count" none "$mlx_job"
) || fail 'baseline job submission failed'
baseline_job=${baseline_job%%;*}
case "$baseline_job" in
''|*[!0-9]*) fail "invalid baseline job id=$baseline_job" ;;
esac
/usr/bin/printf 'submitted baseline_job=%s gres_requested=NO\n' "$baseline_job"
wait_job_gone "$baseline_job" || fail 'baseline job remained in queue'
wait_accounting "$baseline_job" no "${run_dir}/baseline-sacct.txt" || \
	fail 'baseline accounting mismatch'
baseline_out=${output_dir}/job-${baseline_job}.out
baseline_err=${output_dir}/job-${baseline_job}.err
validate_mlx_output "$baseline_out" "$baseline_job" baseline not-configured || \
	fail 'baseline MLX output mismatch'
[ ! -s "$baseline_err" ] || fail 'baseline stderr is not empty'
baseline_pid=$(output_field "$baseline_out" payload_pid)
wait_pid_absent "$baseline_pid" || fail "baseline payload remains pid=$baseline_pid"
baseline_mean=$(mean_elapsed "$baseline_out") || fail 'cannot compute baseline mean'
/usr/bin/printf 'baseline_complete job_id=%s mean_elapsed_seconds=%s\n' \
	"$baseline_job" "$baseline_mean"

gres_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=2 --mem=4G --gres=gpu:apple:1 --time=00:03:00 \
		--chdir=/tmp --job-name=smd204-gres \
		--output="${output_dir}/job-%j.out" --error="${output_dir}/job-%j.err" \
		"$payload" gres "$repeat_count" "$release_file" "$mlx_job"
) || fail 'GRES job submission failed'
gres_job=${gres_job%%;*}
case "$gres_job" in
''|*[!0-9]*) fail "invalid GRES job id=$gres_job" ;;
esac
/usr/bin/printf 'submitted gres_job=%s gres_requested=YES\n' "$gres_job"

unmanaged_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=2 --mem=4G --time=00:03:00 --chdir=/tmp \
		--job-name=smd204-unmanaged \
		--output="${output_dir}/job-%j.out" --error="${output_dir}/job-%j.err" \
		"$payload" unmanaged "$repeat_count" "$release_file" "$mlx_job"
) || fail 'unmanaged GPU job submission failed'
unmanaged_job=${unmanaged_job%%;*}
case "$unmanaged_job" in
''|*[!0-9]*) fail "invalid unmanaged job id=$unmanaged_job" ;;
esac
/usr/bin/printf 'submitted unmanaged_job=%s gres_requested=NO\n' "$unmanaged_job"

gres_out=${output_dir}/job-${gres_job}.out
gres_err=${output_dir}/job-${gres_job}.err
unmanaged_out=${output_dir}/job-${unmanaged_job}.out
unmanaged_err=${output_dir}/job-${unmanaged_job}.err
wait_marker "$gres_job" "$gres_out" "scheduler_ready case=gres job_id=${gres_job}" || \
	fail 'GRES job did not reach barrier'
wait_marker "$unmanaged_job" "$unmanaged_out" \
	"scheduler_ready case=unmanaged job_id=${unmanaged_job}" || \
	fail 'unmanaged job did not reach barrier'
[ "$(queue_state "$gres_job")" = RUNNING ] || fail 'GRES job is not RUNNING at barrier'
[ "$(queue_state "$unmanaged_job")" = RUNNING ] || fail 'unmanaged job is not RUNNING at barrier'
"$squeue" -h -j "${gres_job},${unmanaged_job}" -o '%i|%T|%R|%N' \
	>"${run_dir}/queue-at-barrier.txt" || fail 'cannot capture barrier queue'
"$scontrol" show node "$node_name" >"${run_dir}/node-at-barrier.txt" || \
	fail 'cannot capture node at barrier'
"$scontrol" -o show job "$gres_job" >"${run_dir}/gres-job-at-barrier.txt" || \
	fail 'cannot capture GRES job at barrier'
"$scontrol" -o show job "$unmanaged_job" >"${run_dir}/unmanaged-job-at-barrier.txt" || \
	fail 'cannot capture unmanaged job at barrier'
/usr/bin/printf 'barrier_ready gres_job=%s unmanaged_job=%s both_state=RUNNING\n' \
	"$gres_job" "$unmanaged_job"

/usr/bin/touch "$release_file" || fail 'cannot release compute barrier'
/usr/bin/printf 'barrier_released epoch=%s\n' "$(/bin/date +%s)"
wait_job_gone "$gres_job" || fail 'GRES job remained in queue'
wait_job_gone "$unmanaged_job" || fail 'unmanaged job remained in queue'
wait_accounting "$gres_job" yes "${run_dir}/gres-sacct.txt" || \
	fail 'GRES job accounting mismatch'
wait_accounting "$unmanaged_job" no "${run_dir}/unmanaged-sacct.txt" || \
	fail 'unmanaged job unexpectedly acquired GPU TRES or did not complete'

validate_mlx_output "$gres_out" "$gres_job" gres 0 || fail 'GRES MLX output mismatch'
validate_mlx_output "$unmanaged_out" "$unmanaged_job" unmanaged not-configured || \
	fail 'unmanaged MLX output mismatch'
[ ! -s "$gres_err" ] || fail 'GRES job stderr is not empty'
[ ! -s "$unmanaged_err" ] || fail 'unmanaged job stderr is not empty'
gres_pid=$(output_field "$gres_out" payload_pid)
unmanaged_pid=$(output_field "$unmanaged_out" payload_pid)
wait_pid_absent "$gres_pid" || fail "GRES payload remains pid=$gres_pid"
wait_pid_absent "$unmanaged_pid" || fail "unmanaged payload remains pid=$unmanaged_pid"

gres_mean=$(mean_elapsed "$gres_out") || fail 'cannot compute GRES concurrent mean'
unmanaged_mean=$(mean_elapsed "$unmanaged_out") || fail 'cannot compute unmanaged concurrent mean'
unmanaged_ratio=$(/usr/bin/awk -v baseline="$baseline_mean" -v concurrent="$unmanaged_mean" '
BEGIN {
	if (baseline <= 0) exit 1
	printf "%.3f", concurrent / baseline
}') || fail 'cannot compute unmanaged/baseline ratio'
/usr/bin/printf 'performance baseline_mean_seconds=%s gres_concurrent_mean_seconds=%s unmanaged_concurrent_mean_seconds=%s unmanaged_to_baseline_ratio=%s samples_each=%s\n' \
	"$baseline_mean" "$gres_mean" "$unmanaged_mean" "$unmanaged_ratio" "$repeat_count"

log_size_after=$(/usr/bin/wc -c <"$slurmd_log" | /usr/bin/tr -d ' ')
case "$log_size_after" in
''|*[!0-9]*) fail "invalid final log size=$log_size_after" ;;
esac
[ "$log_size_after" -ge "$log_size_before" ] || fail 'slurmd log rotated during SMD-204'
/usr/bin/tail -c "+$((log_size_before + 1))" "$slurmd_log" \
	>"${run_dir}/slurmd-log-delta.txt"
for active_job in "$baseline_job" "$gres_job" "$unmanaged_job"; do
	/usr/bin/grep -Fq "Launching batch JobId=${active_job}" \
		"${run_dir}/slurmd-log-delta.txt" || fail "slurmd log lacks launch job=$active_job"
	/usr/bin/grep -Fq "[${active_job}.batch] done with step" \
		"${run_dir}/slurmd-log-delta.txt" || fail "slurmd log lacks completion job=$active_job"
done

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final node queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed during SMD-204'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-after.txt" 2>/dev/null; then
	fail 'slurmstepd remains after SMD-204 jobs completed'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-after.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-after.txt" \
	>"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'SMD-204 process remains'

make_output_readable || fail 'cannot make output evidence readable'
/usr/bin/printf '%s\n' '[baseline-accounting]'
/bin/cat "${run_dir}/baseline-sacct.txt"
/usr/bin/printf '%s\n' '[gres-accounting]'
/bin/cat "${run_dir}/gres-sacct.txt"
/usr/bin/printf '%s\n' '[unmanaged-accounting]'
/bin/cat "${run_dir}/unmanaged-sacct.txt"

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD204_GPU_COMPETITION_COMPLETE baseline_job=%s gres_job=%s unmanaged_job=%s classification=UNMANAGED_GPU_ACCESS_CONFIRMED slurmd_pid=%s run_dir=%s\n' \
	"$baseline_job" "$gres_job" "$unmanaged_job" "$slurmd_pid" "$run_dir"

