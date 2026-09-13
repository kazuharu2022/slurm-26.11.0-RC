#!/bin/sh

set -u

slurm_bin=/opt/slurm/26.11.0/bin
slurm_conf=/tmp/slurm-smd001-fixed/slurm.conf
slurm_lib=/tmp/slurm-smd001-fixed
stage_dir=/tmp/slurm-smd001-fixed
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir="/tmp/slurm-smd004-${run_stamp}"
test_jobs=""

export DYLD_LIBRARY_PATH="$slurm_lib"
export SLURM_CONF="$slurm_conf"

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
	workload=$2
	submit_result=$("$slurm_bin/sbatch" \
		--parsable \
		--partition=debug \
		--nodes=1 \
		--ntasks=1 \
		--time=00:02:00 \
		--chdir=/tmp \
		--job-name="smd004-${case_name}" \
		--output="${run_dir}/${case_name}.out" \
		--error="${run_dir}/${case_name}.err" \
		"$workload") || return 1
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
			printf 'error job_id=%s left_queue_before_signal\n' "$job_id" >&2
			return 1
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	printf 'error job_id=%s did_not_reach_running\n' "$job_id" >&2
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

submit_job term "${stage_dir}/smd004_term_trap.sh" || exit 1
term_job=$SUBMITTED_JOB_ID
wait_running "$term_job" || exit 1
/bin/sleep 1
printf 'signal case=term job_id=%s signal=TERM scope=full\n' "$term_job"
"$slurm_bin/scancel" --signal=TERM --full "$term_job" || exit 1
wait_finished "$term_job" || exit 1

submit_job normal_cancel "${stage_dir}/smd004_normal_cancel.sh" || exit 1
cancel_job=$SUBMITTED_JOB_ID
wait_running "$cancel_job" || exit 1
/bin/sleep 1
printf 'signal case=normal_cancel job_id=%s action=scancel\n' "$cancel_job"
"$slurm_bin/scancel" "$cancel_job" || exit 1
wait_finished "$cancel_job" || exit 1

submit_job force_kill "${stage_dir}/smd004_force_kill.sh" || exit 1
kill_job=$SUBMITTED_JOB_ID
wait_running "$kill_job" || exit 1
/bin/sleep 1
kill_start=$(/bin/date '+%s')
printf 'signal case=force_kill job_id=%s action=scancel term_ignored=true\n' "$kill_job"
"$slurm_bin/scancel" "$kill_job" || exit 1
wait_finished "$kill_job" || exit 1
kill_end=$(/bin/date '+%s')
printf 'force_kill_elapsed_seconds=%s\n' "$((kill_end - kill_start))"

for output_file in "$run_dir"/*.out "$run_dir"/*.err; do
	printf '[file=%s]\n' "$output_file"
	/bin/cat "$output_file"
done

trap - EXIT HUP INT TERM
printf 'SMD004_CLIENT_RUN_COMPLETE run_dir=%s\n' "$run_dir"
