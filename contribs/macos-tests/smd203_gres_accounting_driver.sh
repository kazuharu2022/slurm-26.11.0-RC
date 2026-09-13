#!/bin/sh

set -u

if [ "${SMD203_GRES_ACCOUNTING_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD203_GRES_ACCOUNTING_CONFIRMED=YES after confirming PC-210 is idle' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
sacctmgr=${prefix}/bin/sacctmgr
mlx_job=${prefix}/share/macos-gpu-job/mlx_gpu_smoke.sbatch
pid_file=/var/run/slurmd.pid
slurmd_log=/var/log/slurm/slurmd.log
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd203-${run_stamp}
output_dir=${run_dir}/output
job_id=
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
		for (i = 1; i <= count; i++) {
			if (fields[i] == expected)
				return 1
		}
		return 0
	}
	$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" {
		job_state_ok = 1
		if (has_tres($6, "gres/gpu=1"))
			req_generic_ok = 1
		if (has_tres($6, "gres/gpu:apple=1"))
			req_typed_ok = 1
		if (has_tres($7, "gres/gpu=1"))
			alloc_generic_ok = 1
		if (has_tres($7, "gres/gpu:apple=1"))
			alloc_typed_ok = 1
	}
	$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" {
		batch_state_ok = 1
	}
	END {
		exit !(job_state_ok && batch_state_ok &&
		       req_generic_ok && req_typed_ok &&
		       alloc_generic_ok && alloc_typed_ok)
	}
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

make_output_readable()
{
	[ -d "$output_dir" ] || return 0
	/bin/chmod 0755 "$output_dir" || return 1
	if [ -n "$job_id" ]; then
		for file in "${output_dir}/gpu-${job_id}.out" \
			"${output_dir}/gpu-${job_id}.err"; do
			[ ! -f "$file" ] || /bin/chmod 0644 "$file" || return 1
		done
	fi
	return 0
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$job_id"
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
	"$scancel" "$sacct" "$sacctmgr" "$mlx_job" "$pid_file" "$slurmd_log"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for command in /usr/bin/awk /usr/bin/grep /usr/bin/id /usr/bin/pgrep \
	/usr/bin/shasum /usr/bin/sudo /usr/bin/tail /usr/bin/tr /usr/bin/wc \
	/usr/sbin/chown /bin/cat /bin/chmod /bin/date /bin/kill /bin/mkdir \
	/bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'
/usr/bin/grep -Eq \
	'^[[:space:]]*AccountingStorageTRES=([^#]*,)?gres/gpu,gres/gpu:apple([,[:space:]#]|$)' \
	"$slurm_conf" || fail 'local slurm.conf lacks generic and typed GPU accounting TRES'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
/usr/bin/printf 'run_dir=%s mlx_job=%s\n' "$run_dir" "$mlx_job"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show config >"${run_dir}/controller-config.txt" || fail 'controller config readback failed'
/usr/bin/grep -Fq 'gres/gpu' "${run_dir}/controller-config.txt" || \
	fail 'effective config lacks gres/gpu accounting'
/usr/bin/grep -Fq 'gres/gpu:apple' "${run_dir}/controller-config.txt" || \
	fail 'effective config lacks gres/gpu:apple accounting'
"$sacctmgr" -nP show tres format=Type,Name,ID \
	>"${run_dir}/registered-tres.txt" 2>"${run_dir}/registered-tres.err" || \
	fail 'cannot read registered TRES'
/usr/bin/grep -Eq '^gres\|gpu\|[0-9]+$' "${run_dir}/registered-tres.txt" || \
	fail 'database lacks gres/gpu TRES'
/usr/bin/grep -Eq '^gres\|gpu:apple\|[0-9]+$' "${run_dir}/registered-tres.txt" || \
	fail 'database lacks gres/gpu:apple TRES'

"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
/usr/bin/grep -Fq 'Gres=gpu:apple:1' "${run_dir}/node-before.txt" || \
	fail 'gpu:apple:1 is not registered'
/usr/bin/grep -Fq 'gres/gpu=1,gres/gpu:apple=1' "${run_dir}/node-before.txt" || \
	fail 'node CfgTRES lacks generic or typed GPU'
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

job_id=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=2 --mem=4G --gres=gpu:apple:1 --time=00:02:00 \
		--chdir=/tmp --job-name=smd203-accounting \
		--output="${output_dir}/gpu-%j.out" --error="${output_dir}/gpu-%j.err" \
		"$mlx_job"
) || fail 'GPU accounting job submission failed'
job_id=${job_id%%;*}
case "$job_id" in
''|*[!0-9]*) fail "invalid GPU job id=$job_id" ;;
esac
/usr/bin/printf 'submitted gpu_job=%s\n' "$job_id"

wait_job_gone "$job_id" || fail 'GPU accounting job remained in queue'
wait_accounting "$job_id" "${run_dir}/sacct.txt" || \
	fail 'accounting lacks COMPLETED state or generic/typed GPU TRES'

job_out=${output_dir}/gpu-${job_id}.out
job_err=${output_dir}/gpu-${job_id}.err
/usr/bin/grep -Fq "job_id=${job_id}" "$job_out" || fail 'MLX output job ID mismatch'
/usr/bin/grep -Fq 'slurm_job_gpus=0' "$job_out" || fail 'SLURM_JOB_GPUS is not 0'
/usr/bin/grep -Fq 'machine=arm64' "$job_out" || fail 'MLX job did not report arm64'
/usr/bin/grep -Fq 'default_device=Device(gpu, 0)' "$job_out" || fail 'MLX default device is not GPU'
/usr/bin/grep -Fq "'device_name': 'Apple M5 Max'" "$job_out" || fail 'MLX did not report Apple M5 Max'
/usr/bin/grep -Fq 'gpu_smoke_test=PASS' "$job_out" || fail 'MLX GPU smoke test failed'
[ ! -s "$job_err" ] || fail 'GPU accounting job stderr is not empty'

log_size_after=$(/usr/bin/wc -c <"$slurmd_log" | /usr/bin/tr -d ' ')
case "$log_size_after" in
''|*[!0-9]*) fail "invalid final log size=$log_size_after" ;;
esac
[ "$log_size_after" -ge "$log_size_before" ] || fail 'slurmd log rotated during SMD-203'
/usr/bin/tail -c "+$((log_size_before + 1))" "$slurmd_log" \
	>"${run_dir}/slurmd-log-delta.txt"
/usr/bin/grep -Fq "Launching batch JobId=${job_id}" \
	"${run_dir}/slurmd-log-delta.txt" || fail 'slurmd log lacks job launch'
/usr/bin/grep -Fq "[${job_id}.batch] done with step" \
	"${run_dir}/slurmd-log-delta.txt" || fail 'slurmd log lacks successful step completion'

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final node queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed during SMD-203'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-after.txt" 2>/dev/null; then
	fail 'slurmstepd remains after GPU job completed'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-after.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-after.txt" \
	>"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'SMD-203 process remains'

make_output_readable || fail 'cannot make output evidence readable'
/usr/bin/printf '%s\n' '[accounting]'
/bin/cat "${run_dir}/sacct.txt"

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD203_GRES_ACCOUNTING_COMPLETE job_id=%s state=COMPLETED req_generic=1 req_typed=1 alloc_generic=1 alloc_typed=1 slurmd_pid=%s run_dir=%s\n' \
	"$job_id" "$slurmd_pid" "$run_dir"
