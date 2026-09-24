#!/bin/sh

set -u

slurm_bin=${SMD_SLURM_BIN:-/opt/slurm/26.11.0/bin}
slurm_conf=${SMD_SLURM_CONF:-/tmp/slurm-smd001-fixed/slurm.conf}
slurm_lib=${SMD_SLURM_LIB:-/tmp/slurm-smd001-fixed}
stage_dir=${SMD_STAGE_DIR:-/tmp/slurm-smd001-fixed}
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir="/tmp/slurm-smd005-${run_stamp}"
test_jobs=""

export SLURM_CONF="$slurm_conf"
if [ -n "$slurm_lib" ]; then
	export DYLD_LIBRARY_PATH="$slurm_lib"
else
	unset DYLD_LIBRARY_PATH
fi

/bin/mkdir -m 0755 "$run_dir" || exit 1
printf 'run_dir=%s\n' "$run_dir"

cleanup_jobs()
{
	for job_id in $test_jobs; do
		state=$("$slurm_bin/squeue" -h -j "$job_id" -o '%T')
		if [ -n "$state" ]; then
			printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state"
			"$slurm_bin/scancel" "$job_id"
		fi
	done
}

trap cleanup_jobs EXIT HUP INT TERM

submit_job()
{
	case_name=$1
	shift
	submit_result=$("$slurm_bin/sbatch" \
		--parsable \
		--partition=debug \
		--nodes=1 \
		--ntasks=1 \
		--cpus-per-task=1 \
		--mem=1G \
		--time=00:03:00 \
		--chdir=/tmp \
		--job-name="smd005-${case_name}" \
		--output="${run_dir}/${case_name}.out" \
		--error="${run_dir}/${case_name}.err" \
		"$@") || return 1
	job_id=${submit_result%%;*}
	test_jobs="$test_jobs $job_id"
	printf '%s\t%s\n' "$case_name" "$job_id" >>"${run_dir}/jobs.tsv"
	printf 'submitted case=%s job_id=%s\n' "$case_name" "$job_id"
	SUBMITTED_JOB_ID=$job_id
}

wait_running()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 30 ]; do
		state=$("$slurm_bin/squeue" -h -j "$job_id" -o '%T')
		if [ "$state" = RUNNING ]; then
			printf 'running job_id=%s\n' "$job_id"
			return 0
		fi
		if [ -z "$state" ]; then
			printf 'error job_id=%s left_queue_before_running\n' "$job_id" >&2
			return 1
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	printf 'error job_id=%s did_not_reach_running state=%s\n' "$job_id" "$state" >&2
	return 1
}

wait_finished()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		state=$("$slurm_bin/squeue" -h -j "$job_id" -o '%T')
		if [ -z "$state" ]; then
			printf 'finished job_id=%s wait_seconds=%s\n' "$job_id" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	printf 'error job_id=%s remained_in_queue state=%s\n' "$job_id" "$state" >&2
	return 1
}

submit_job control "${stage_dir}/smd005_control.sh" || exit 1
control_job=$SUBMITTED_JOB_ID
wait_running "$control_job" || exit 1

submit_job target "${stage_dir}/smd005_process_tree.sh" "$run_dir" "$stage_dir" || exit 1
target_job=$SUBMITTED_JOB_ID
wait_running "$target_job" || exit 1

attempt=0
while [ ! -s "${run_dir}/target.ready" ] && [ "$attempt" -lt 100 ]; do
	/bin/sleep 0.1
	attempt=$((attempt + 1))
done
if [ ! -s "${run_dir}/target.ready" ]; then
	printf 'error target tree did not become ready\n' >&2
	exit 1
fi

printf '[target_processes_before_cancel]\n'
while read role pid; do
	printf 'role=%s expected_pid=%s ' "$role" "$pid"
	if /bin/ps -p "$pid" -o pid=,ppid=,pgid=,state=,command=; then
		:
	else
		printf 'MISSING_BEFORE_CANCEL\n'
		exit 1
	fi
done <"${run_dir}/target-pids.tsv"

printf 'cancel target_job=%s\n' "$target_job"
"$slurm_bin/scancel" "$target_job" || exit 1
wait_finished "$target_job" || exit 1

residual=0
printf '[target_processes_after_cancel]\n'
while read role pid; do
	if /bin/ps -p "$pid" -o pid=,ppid=,pgid=,state=,command=; then
		printf 'role=%s pid=%s residual=YES\n' "$role" "$pid"
		residual=1
	else
		printf 'role=%s pid=%s residual=NO\n' "$role" "$pid"
	fi
done <"${run_dir}/target-pids.tsv"

control_state=$("$slurm_bin/squeue" -h -j "$control_job" -o '%T')
printf 'control_after_target_cancel job_id=%s state=%s\n' "$control_job" "$control_state"
if [ "$control_state" != RUNNING ]; then
	printf 'error control job was not preserved\n' >&2
	exit 1
fi

printf 'cancel control_job=%s\n' "$control_job"
"$slurm_bin/scancel" "$control_job" || exit 1
wait_finished "$control_job" || exit 1

for output_file in "$run_dir"/*.out "$run_dir"/*.err; do
	printf '[file=%s]\n' "$output_file"
	/bin/cat "$output_file"
done

if [ "$residual" -ne 0 ]; then
	printf 'SMD005_FAIL residual_process_detected run_dir=%s\n' "$run_dir" >&2
	exit 1
fi

trap - EXIT HUP INT TERM
printf 'SMD005_CLIENT_RUN_COMPLETE run_dir=%s\n' "$run_dir"
