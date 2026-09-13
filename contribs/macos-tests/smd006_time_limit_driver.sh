#!/bin/sh

set -u

slurm_bin=/opt/slurm/26.11.0/bin
slurm_conf=/tmp/slurm-smd001-fixed/slurm.conf
slurm_lib=/tmp/slurm-smd001-fixed
stage_dir=/tmp/slurm-smd001-fixed
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir="/tmp/slurm-smd006-${run_stamp}"
job_id=""

export DYLD_LIBRARY_PATH="$slurm_lib"
export SLURM_CONF="$slurm_conf"

/bin/mkdir -m 0755 "$run_dir" || exit 1
printf 'run_dir=%s\n' "$run_dir"

cleanup_job()
{
	if [ -n "$job_id" ]; then
		state=$("$slurm_bin/squeue" -h -j "$job_id" -o '%T')
		if [ -n "$state" ]; then
			printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state"
			"$slurm_bin/scancel" "$job_id"
		fi
	fi
}

trap cleanup_job EXIT HUP INT TERM

submit_result=$("$slurm_bin/sbatch" \
	--parsable \
	--partition=debug \
	--nodes=1 \
	--ntasks=1 \
	--cpus-per-task=1 \
	--mem=1G \
	--time=00:01:00 \
	--chdir=/tmp \
	--job-name=smd006-time-limit \
	--output="${run_dir}/time-limit.out" \
	--error="${run_dir}/time-limit.err" \
	"${stage_dir}/smd006_time_limit_workload.sh" "$run_dir") || exit 1
job_id=${submit_result%%;*}
printf 'submitted job_id=%s time_limit=00:01:00 workload_seconds=180\n' "$job_id"
printf '%s\n' "$job_id" >"${run_dir}/job-id.txt"

attempt=0
while [ "$attempt" -lt 30 ]; do
	state=$("$slurm_bin/squeue" -h -j "$job_id" -o '%T')
	if [ "$state" = RUNNING ]; then
		printf 'running job_id=%s\n' "$job_id"
		break
	fi
	if [ -z "$state" ]; then
		printf 'error job left queue before running\n' >&2
		exit 1
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if [ "$state" != RUNNING ]; then
	printf 'error job did not reach running state=%s\n' "$state" >&2
	exit 1
fi

attempt=0
while [ ! -s "${run_dir}/workload.ready" ] && [ "$attempt" -lt 100 ]; do
	/bin/sleep 0.1
	attempt=$((attempt + 1))
done
if [ ! -s "${run_dir}/workload.ready" ]; then
	printf 'error workload did not become ready\n' >&2
	exit 1
fi

printf '[processes_before_timeout]\n'
while read role pid; do
	printf 'role=%s expected_pid=%s ' "$role" "$pid"
	if /bin/ps -p "$pid" -o pid=,ppid=,pgid=,state=,command=; then
		:
	else
		printf 'MISSING_BEFORE_TIMEOUT\n'
		exit 1
	fi
done <"${run_dir}/pids.tsv"

wait_start=$(/bin/date '+%s')
attempt=0
while [ "$attempt" -lt 150 ]; do
	state=$("$slurm_bin/squeue" -h -j "$job_id" -o '%T')
	if [ -z "$state" ]; then
		break
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
wait_end=$(/bin/date '+%s')
if [ -n "$state" ]; then
	printf 'error job remained in queue state=%s\n' "$state" >&2
	exit 1
fi
printf 'finished job_id=%s wait_seconds=%s wall_seconds=%s\n' \
	"$job_id" "$attempt" "$((wait_end - wait_start))"

residual=0
printf '[processes_after_timeout]\n'
while read role pid; do
	if /bin/ps -p "$pid" -o pid=,ppid=,pgid=,state=,command=; then
		printf 'role=%s pid=%s residual=YES\n' "$role" "$pid"
		residual=1
	else
		printf 'role=%s pid=%s residual=NO\n' "$role" "$pid"
	fi
done <"${run_dir}/pids.tsv"

for output_file in "${run_dir}/time-limit.out" "${run_dir}/time-limit.err"; do
	printf '[file=%s]\n' "$output_file"
	/bin/cat "$output_file"
done

if [ "$residual" -ne 0 ]; then
	printf 'SMD006_FAIL residual_process_detected run_dir=%s\n' "$run_dir" >&2
	exit 1
fi

trap - EXIT HUP INT TERM
printf 'SMD006_CLIENT_RUN_COMPLETE job_id=%s run_dir=%s\n' "$job_id" "$run_dir"
