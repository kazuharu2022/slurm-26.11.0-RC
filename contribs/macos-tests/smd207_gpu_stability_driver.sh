#!/bin/sh

set -u

if [ "${SMD207_GPU_STABILITY_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD207_GPU_STABILITY_CONFIRMED=YES after accepting 30 sequential GPU jobs' >&2
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
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
repeat_count=${SMD207_REPEAT_COUNT:-30}
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd207-${run_stamp}
output_dir=${run_dir}/output
active_job=
powermetrics_pid=
slurmd_pid=
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

cancel_active_job()
{
	[ -n "$active_job" ] || return 0
	state=$(queue_state "$active_job")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$active_job" "$state" >&2
		"$scancel" "$active_job" >/dev/null 2>&1 || true
	fi
}

stop_powermetrics()
{
	[ -n "$powermetrics_pid" ] || return 0
	if /bin/kill -0 "$powermetrics_pid" >/dev/null 2>&1; then
		/bin/kill -INFO "$powermetrics_pid" >/dev/null 2>&1 || true
		/bin/sleep 1
		/bin/kill -TERM "$powermetrics_pid" >/dev/null 2>&1 || true
		wait "$powermetrics_pid" 2>/dev/null || true
	fi
	powermetrics_pid=
}

make_output_readable()
{
	[ -d "$output_dir" ] || return 0
	/bin/chmod 0755 "$output_dir" || return 1
	find "$output_dir" -type f -exec /bin/chmod 0644 {} \; || return 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_active_job
	stop_powermetrics
	make_output_readable || rc=1
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: no production configuration was changed; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

wait_job_gone()
{
	job=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ -z "$(queue_state "$job")" ]; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

accounting_complete_with_gpu()
{
	job=$1
	file=$2
	"$sacct" -j "$job" -n -P \
		--format=JobIDRaw,User,State,ExitCode,ElapsedRaw,NodeList,ReqTRES%200,AllocTRES%200 \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job" -v user="$test_user" '
	function has(value, expected, count, fields, i) {
		count = split(value, fields, ",")
		for (i = 1; i <= count; i++)
			if (fields[i] == expected) return 1
		return 0
	}
	$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" &&
	 has($7, "gres/gpu=1") && has($7, "gres/gpu:apple=1") &&
	 has($8, "gres/gpu=1") && has($8, "gres/gpu:apple=1") { root_ok = 1 }
	$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" { batch_ok = 1 }
	END { exit !(root_ok && batch_ok) }
	' "$file"
}

wait_accounting()
{
	job=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if accounting_complete_with_gpu "$job" "$file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

analyse_metrics()
{
	/usr/bin/awk -F '\t' '
	NR == 1 { next }
	{
		n++
		v = $3 + 0
		sum += v
		sumsq += v * v
		if (n == 1 || v < min) min = v
		if (n == 1 || v > max) max = v
	}
	END {
		if (!n) exit 1
		mean = sum / n
		variance = (sumsq / n) - (mean * mean)
		if (variance < 0 && variance > -0.000000000001) variance = 0
		stddev = sqrt(variance)
		printf "samples=%d\n", n
		printf "elapsed_mean_seconds=%.6f\n", mean
		printf "elapsed_min_seconds=%.6f\n", min
		printf "elapsed_max_seconds=%.6f\n", max
		printf "elapsed_stddev_seconds=%.6f\n", stddev
		printf "elapsed_cv_percent=%.3f\n", (mean ? stddev / mean * 100 : 0)
	}' "${run_dir}/metrics.tsv" >"${run_dir}/statistics.env" || return 1

	/usr/bin/awk -F '\t' 'NR > 1 { print $3 }' "${run_dir}/metrics.tsv" |
		/usr/bin/sort -n >"${run_dir}/elapsed.sorted"
	/usr/bin/awk '
	{ value[NR] = $1 }
	END {
		if (!NR) exit 1
		if (NR % 2) median = value[(NR + 1) / 2]
		else median = (value[NR / 2] + value[NR / 2 + 1]) / 2
		printf "elapsed_median_seconds=%.6f\n", median
	}' "${run_dir}/elapsed.sorted" >>"${run_dir}/statistics.env" || return 1
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'
case "$repeat_count" in
''|*[!0-9]*) fail "invalid repeat count=$repeat_count" ;;
esac
[ "$repeat_count" -ge 30 ] || fail 'official SMD-207 requires at least 30 repetitions'
[ "$repeat_count" -le 100 ] || fail 'repeat count must not exceed 100'

for path in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" "$scancel" \
	"$sacct" "$mlx_job" "$pid_file" /usr/bin/powermetrics; do
	[ -e "$path" ] || fail "missing $path"
done
for command in /usr/bin/awk /usr/bin/diff /usr/bin/find /usr/bin/grep /usr/bin/id \
	/usr/bin/pgrep /usr/bin/pmset /usr/bin/shasum /usr/bin/sort /usr/bin/stat \
	/usr/bin/sudo /usr/bin/sw_vers /usr/bin/uname /usr/sbin/chown \
	/usr/sbin/system_profiler /bin/cat /bin/chmod /bin/date /bin/kill \
	/bin/mkdir /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
/usr/bin/printf 'run_dir=%s repeat_count=%s mlx_job=%s\n' "$run_dir" "$repeat_count" "$mlx_job"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
/usr/bin/grep -Fq 'Gres=gpu:apple:1' "${run_dir}/node-before.txt" || fail 'GPU GRES is missing'
/usr/bin/grep -Fq 'gres/gpu=1,gres/gpu:apple=1' "${run_dir}/node-before.txt" || fail 'GPU CfgTRES is missing'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail 'slurmd is not running'
/usr/bin/shasum -a 256 "$slurm_conf" "$mlx_job" >"${run_dir}/inputs-before.sha256"
/usr/bin/sw_vers >"${run_dir}/sw-vers.txt"
/usr/bin/uname -a >"${run_dir}/uname.txt"
/usr/sbin/system_profiler SPHardwareDataType >"${run_dir}/hardware.txt"
/usr/bin/pmset -g therm >"${run_dir}/pmset-therm-before.txt" 2>&1 || true

if /usr/bin/powermetrics --samplers smc --sample-count 1 --sample-rate 100 \
	>"${run_dir}/smc-probe.out" 2>"${run_dir}/smc-probe.err"; then
	/usr/bin/printf 'absolute_temperature_source=powermetrics_smc\n' \
		>"${run_dir}/temperature-capability.env"
else
	/usr/bin/grep -Fq 'unrecognized sampler: smc' "${run_dir}/smc-probe.err" || \
		fail 'smc temperature capability probe failed unexpectedly'
	/usr/bin/printf '%s\n' \
		'absolute_temperature_celsius=NOT_AVAILABLE_FROM_SUPPORTED_POWERMETRICS_SAMPLERS' \
		'thermal_substitute=powermetrics_thermal_pressure_and_gpu_power' \
		>"${run_dir}/temperature-capability.env"
fi

/usr/bin/powermetrics --samplers thermal,gpu_power --sample-rate 1000 \
	--sample-count 900 --buffer-size 1 --output-file "${run_dir}/powermetrics.txt" \
	>"${run_dir}/powermetrics.stdout" 2>"${run_dir}/powermetrics.stderr" &
powermetrics_pid=$!
/bin/sleep 2
/bin/kill -0 "$powermetrics_pid" >/dev/null 2>&1 || fail 'powermetrics sampler exited early'

/usr/bin/printf 'sequence\tjob_id\telapsed_seconds\tmean_value\tjob_elapsed_raw\n' \
	>"${run_dir}/metrics.tsv"
sequence=1
while [ "$sequence" -le "$repeat_count" ]; do
	job_out=${output_dir}/gpu-${sequence}-%j.out
	job_err=${output_dir}/gpu-${sequence}-%j.err
	active_job=$(
		/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
			"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
			--cpus-per-task=2 --mem=4G --gres=gpu:apple:1 --time=00:02:00 \
			--chdir=/tmp --job-name=smd207-gpu-stability \
			--output="$job_out" --error="$job_err" "$mlx_job"
	) || fail "submission failed sequence=$sequence"
	active_job=${active_job%%;*}
	case "$active_job" in
	''|*[!0-9]*) fail "invalid job id sequence=$sequence job=$active_job" ;;
	esac
	/usr/bin/printf 'submitted sequence=%s job_id=%s\n' "$sequence" "$active_job"
	wait_job_gone "$active_job" || fail "job remained in queue sequence=$sequence job=$active_job"
	sacct_file=${run_dir}/sacct-${sequence}-${active_job}.txt
	wait_accounting "$active_job" "$sacct_file" || \
		fail "accounting mismatch sequence=$sequence job=$active_job"
	actual_out=${output_dir}/gpu-${sequence}-${active_job}.out
	actual_err=${output_dir}/gpu-${sequence}-${active_job}.err
	/usr/bin/grep -Fq "job_id=${active_job}" "$actual_out" || fail "job ID output mismatch sequence=$sequence"
	/usr/bin/grep -Fq 'slurm_job_gpus=0' "$actual_out" || fail "GPU env mismatch sequence=$sequence"
	/usr/bin/grep -Fq 'machine=arm64' "$actual_out" || fail "architecture mismatch sequence=$sequence"
	/usr/bin/grep -Fq 'default_device=Device(gpu, 0)' "$actual_out" || fail "device mismatch sequence=$sequence"
	/usr/bin/grep -Fq "'device_name': 'Apple M5 Max'" "$actual_out" || fail "GPU name mismatch sequence=$sequence"
	/usr/bin/grep -Fq 'gpu_smoke_test=PASS' "$actual_out" || fail "GPU smoke failed sequence=$sequence"
	[ ! -s "$actual_err" ] || fail "job stderr is not empty sequence=$sequence"
	elapsed=$(/usr/bin/awk -F '=' '$1 == "elapsed_seconds" { print $2; exit }' "$actual_out")
	mean_value=$(/usr/bin/awk -F '=' '$1 == "mean_value" { print $2; exit }' "$actual_out")
	job_elapsed_raw=$(/usr/bin/awk -F '|' -v job="$active_job" '$1 == job { print $5; exit }' "$sacct_file")
	/usr/bin/awk -v v="$elapsed" 'BEGIN { exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v > 0) }' || \
		fail "invalid elapsed value sequence=$sequence value=$elapsed"
	/usr/bin/awk -v v="$mean_value" 'BEGIN { exit !(v ~ /^[+-]?[0-9]+([.][0-9]+)?[eE][+-]?[0-9]+$/) }' || \
		fail "invalid mean value sequence=$sequence value=$mean_value"
	/usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
		"$sequence" "$active_job" "$elapsed" "$mean_value" "$job_elapsed_raw" \
		>>"${run_dir}/metrics.tsv"
	active_job=
	sequence=$((sequence + 1))
done

stop_powermetrics
/usr/bin/pmset -g therm >"${run_dir}/pmset-therm-after.txt" 2>&1 || true
[ -s "${run_dir}/powermetrics.txt" ] || fail 'powermetrics output is empty'
/usr/bin/grep -Eic 'thermal|pressure' "${run_dir}/powermetrics.txt" \
	>"${run_dir}/thermal-line-count.txt" || true
/usr/bin/grep -Eic 'GPU|gpu' "${run_dir}/powermetrics.txt" \
	>"${run_dir}/gpu-line-count.txt" || true
[ "$(/bin/cat "${run_dir}/thermal-line-count.txt")" -gt 0 ] || fail 'thermal pressure samples are missing'
[ "$(/bin/cat "${run_dir}/gpu-line-count.txt")" -gt 0 ] || fail 'GPU power/frequency samples are missing'

analyse_metrics || fail 'statistics calculation failed'
[ "$(/usr/bin/awk -F '=' '$1 == "samples" { print $2 }' "${run_dir}/statistics.env")" = "$repeat_count" ] || \
	fail 'statistics sample count mismatch'

"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-final.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-final.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-final.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed during SMD-207'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-final.txt" 2>/dev/null; then
	fail 'slurmstepd remains after repetitions'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-final.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-final.txt" >"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'SMD-207 process remains'
/usr/bin/shasum -a 256 "$slurm_conf" "$mlx_job" >"${run_dir}/inputs-after.sha256"
/usr/bin/diff -u "${run_dir}/inputs-before.sha256" "${run_dir}/inputs-after.sha256" \
	>"${run_dir}/inputs.diff" || fail 'input files changed during SMD-207'

make_output_readable || fail 'cannot make output evidence readable'
success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD207_GPU_STABILITY_COMPLETE repetitions=%s successful_jobs=%s failed_jobs=0 slurmd_pid=%s temperature_celsius=NOT_AVAILABLE thermal_pressure=RECORDED gpu_power=RECORDED run_dir=%s\n' \
	"$repeat_count" "$repeat_count" "$slurmd_pid" "$run_dir"
/bin/cat "${run_dir}/statistics.env"
