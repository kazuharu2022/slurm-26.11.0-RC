#!/bin/sh

set -u

if [ "${SMD208_NUMERICAL_CORRECTNESS_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD208_NUMERICAL_CORRECTNESS_CONFIRMED=YES after accepting one GPU correctness job with predeclared tolerances' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
mlx_python=${prefix}/share/macos-gpu-job/.venv/bin/python
pid_file=/var/run/slurmd.pid
source_dir=/Users/REDACTED_USER/dev/slurm.26-05/contribs/macos-tests
source_payload=${source_dir}/smd208_mlx_correctness.py
source_batch=${source_dir}/smd208_mlx_correctness.sbatch
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd208-${run_stamp}
input_dir=${run_dir}/input
output_dir=${run_dir}/output
job_id=
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

cancel_if_active()
{
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state" >&2
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
}

make_evidence_readable()
{
	[ -d "$run_dir" ] || return 0
	/bin/chmod 0755 "$run_dir" "$input_dir" "$output_dir" 2>/dev/null || true
	/usr/bin/find "$run_dir" -type f -exec /bin/chmod 0644 {} \; || return 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active
	make_evidence_readable || rc=1
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: no production configuration was changed; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
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

accounting_complete_with_gpu()
{
	active_job=$1
	file=$2
	"$sacct" -j "$active_job" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES%200,AllocTRES%200 \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$active_job" -v user="$test_user" '
	function has_tres(value, expected, count, fields, i) {
		count = split(value, fields, ",")
		for (i = 1; i <= count; i++)
			if (fields[i] == expected) return 1
		return 0
	}
	$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" &&
	 has_tres($6, "gres/gpu=1") && has_tres($6, "gres/gpu:apple=1") &&
	 has_tres($7, "gres/gpu=1") && has_tres($7, "gres/gpu:apple=1") { root_ok = 1 }
	$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" { batch_ok = 1 }
	END { exit !(root_ok && batch_ok) }
	' "$file"
}

wait_accounting()
{
	active_job=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if accounting_complete_with_gpu "$active_job" "$file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

capture_accounting()
{
	active_job=$1
	file=$2
	"$sacct" -j "$active_job" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES%200,AllocTRES%200 \
		>"$file" 2>"${file%.txt}.err" || true
}

validate_numeric_output()
{
	file=$1
	/usr/bin/awk '
	function numeric(number) {
		return number ~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/
	}
	function value(key,   i, pair) {
		for (i = 1; i <= NF; i++) {
			split($i, pair, "=")
			if (pair[1] == key) return pair[2]
		}
		return ""
	}
	/^case=/ {
		name = value("case")
		shape = value("shape")
		max_abs = value("max_abs_error")
		mean_abs = value("mean_abs_error")
		max_scaled = value("max_scaled_error")
		cases++
		seen[name]++
		if ((name == "rect_k31" && shape != "7x31x11") ||
		    (name == "rect_k64" && shape != "13x64x9") ||
		    (name == "rect_k127" && shape != "5x127x7") ||
		    (name != "rect_k31" && name != "rect_k64" && name != "rect_k127")) bad = 1
		if (value("status") != "PASS" || value("non_finite") != 0 ||
		    !numeric(max_abs) || !numeric(mean_abs) || !numeric(max_scaled) ||
		    max_abs + 0 > 0.001 || mean_abs + 0 > 0.00002 ||
		    max_scaled + 0 > 1.0) bad = 1
	}
	/^overall_elements=/ {
		max_abs = value("overall_max_abs_error")
		mean_abs = value("overall_mean_abs_error")
		max_scaled = value("overall_max_scaled_error")
		overall++
		if (value("overall_elements") != 229 || value("status") != "PASS" ||
		    !numeric(max_abs) || !numeric(mean_abs) || !numeric(max_scaled) ||
		    max_abs + 0 > 0.001 || mean_abs + 0 > 0.00002 ||
		    max_scaled + 0 > 1.0) bad = 1
	}
	END {
		exit !(cases == 3 && overall == 1 &&
		       seen["rect_k31"] == 1 && seen["rect_k64"] == 1 &&
		       seen["rect_k127"] == 1 && !bad)
	}
	' "$file"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for path in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" "$scancel" \
	"$sacct" "$mlx_python" "$pid_file" "$source_payload" "$source_batch"; do
	[ -e "$path" ] || fail "missing $path"
done
for command in /usr/bin/awk /usr/bin/diff /usr/bin/find /usr/bin/grep \
	/usr/bin/id /usr/bin/pgrep /usr/bin/shasum /usr/bin/sudo /usr/sbin/chown \
	/bin/cat /bin/chmod /bin/cp /bin/date /bin/kill /bin/mkdir /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0755 "$input_dir" || fail 'cannot create input directory'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/bin/cp "$source_payload" "${input_dir}/smd208_mlx_correctness.py" || fail 'cannot stage payload'
/bin/cp "$source_batch" "${input_dir}/smd208_mlx_correctness.sbatch" || fail 'cannot stage batch script'
/bin/chmod 0644 "${input_dir}/smd208_mlx_correctness.py" || fail 'cannot set payload mode'
/bin/chmod 0755 "${input_dir}/smd208_mlx_correctness.sbatch" || fail 'cannot set batch mode'
/usr/sbin/chown -R "$test_uid:$test_gid" "$input_dir" "$output_dir" || fail 'cannot chown staged inputs'
/usr/bin/printf 'run_dir=%s payload=%s\n' "$run_dir" "$source_payload"

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
/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" "$source_batch" \
	>"${run_dir}/inputs-before.sha256"
/usr/bin/shasum -a 256 "${input_dir}/smd208_mlx_correctness.py" \
	"${input_dir}/smd208_mlx_correctness.sbatch" >"${run_dir}/staged-inputs.sha256"

job_id=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=2 --mem=1G --gres=gpu:apple:1 --time=00:02:00 \
		--chdir=/tmp --job-name=smd208-correctness \
		--output="${output_dir}/correctness-%j.out" \
		--error="${output_dir}/correctness-%j.err" \
		"${input_dir}/smd208_mlx_correctness.sbatch" \
		"${input_dir}/smd208_mlx_correctness.py"
) || fail 'GPU correctness job submission failed'
job_id=${job_id%%;*}
case "$job_id" in
''|*[!0-9]*) fail "invalid job id=$job_id" ;;
esac
/usr/bin/printf 'submitted correctness_job=%s\n' "$job_id"

wait_job_gone "$job_id" || fail 'GPU correctness job remained in queue'

job_out=${output_dir}/correctness-${job_id}.out
job_err=${output_dir}/correctness-${job_id}.err
[ -f "$job_out" ] || fail 'job stdout is missing'
[ -f "$job_err" ] || fail 'job stderr is missing'
if ! /usr/bin/grep -Fxq 'SMD208_NUMERICAL_CORRECTNESS_PASS' "$job_out"; then
	capture_accounting "$job_id" "${run_dir}/sacct.txt"
	/usr/bin/printf '%s\n' '[numerical-result]' >&2
	/bin/cat "$job_out" >&2
	/usr/bin/printf '%s\n' '[job-stderr]' >&2
	/bin/cat "$job_err" >&2
	/usr/bin/printf '%s\n' '[accounting]' >&2
	/bin/cat "${run_dir}/sacct.txt" >&2
	fail 'numerical correctness criteria failed'
fi
[ ! -s "$job_err" ] || fail 'job stderr is not empty'
wait_accounting "$job_id" "${run_dir}/sacct.txt" || fail 'successful payload accounting mismatch'
/usr/bin/grep -Fxq "job_id=${job_id}" "$job_out" || fail 'job ID output mismatch'
/usr/bin/grep -Fxq 'job_user=testuser' "$job_out" || fail 'job user output mismatch'
/usr/bin/grep -Fxq 'slurm_job_gpus=0' "$job_out" || fail 'GPU environment output mismatch'
/usr/bin/grep -Fxq 'machine=arm64' "$job_out" || fail 'architecture output mismatch'
/usr/bin/grep -Fxq 'mlx_version=0.32.2' "$job_out" || fail 'MLX version output mismatch'
/usr/bin/grep -Fxq 'default_device=Device(gpu, 0)' "$job_out" || fail 'MLX default device is not GPU'
/usr/bin/grep -Fxq 'metal_device_name=Apple M5 Max' "$job_out" || fail 'Metal device mismatch'
/usr/bin/grep -Fxq 'mlx_enable_tf32=0' "$job_out" || fail 'full float32 mode is not enabled'
/usr/bin/grep -Fxq 'reference=python_math_fsum_float64' "$job_out" || fail 'CPU reference marker missing'
/usr/bin/grep -Fxq 'element_atol=0.00005000' "$job_out" || fail 'ATOL changed'
/usr/bin/grep -Fxq 'element_rtol=0.00005000' "$job_out" || fail 'RTOL changed'
/usr/bin/grep -Fxq 'max_abs_error_limit=0.00100000' "$job_out" || fail 'max error limit changed'
/usr/bin/grep -Fxq 'mean_abs_error_limit=0.00002000' "$job_out" || fail 'mean error limit changed'
validate_numeric_output "$job_out" || fail 'independent numerical threshold check failed'

"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-final.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-final.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-final.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed during SMD-208'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-final.txt" 2>/dev/null; then
	fail 'slurmstepd remains after correctness job'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-final.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-final.txt" >"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'SMD-208 process remains'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" "$source_batch" \
	>"${run_dir}/inputs-after.sha256"
/usr/bin/diff -u "${run_dir}/inputs-before.sha256" "${run_dir}/inputs-after.sha256" \
	>"${run_dir}/inputs.diff" || fail 'input files changed during SMD-208'

make_evidence_readable || fail 'cannot make evidence readable'
/usr/bin/printf '%s\n' '[numerical-result]'
/bin/cat "$job_out"
/usr/bin/printf '%s\n' '[accounting]'
/bin/cat "${run_dir}/sacct.txt"

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD208_NUMERICAL_CORRECTNESS_COMPLETE job_id=%s cases=3 elements=229 slurmd_pid=%s production_unchanged=PASS run_dir=%s\n' \
	"$job_id" "$slurmd_pid" "$run_dir"
