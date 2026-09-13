#!/bin/sh

set -u

slurm_bin=/opt/slurm/26.11.0/bin
slurm_conf=/tmp/slurm-smd001-fixed/slurm.conf
slurm_lib=/tmp/slurm-smd001-fixed
stage_dir=/tmp/slurm-smd001-fixed
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir="/tmp/slurm-smd007-${run_stamp}"
test_jobs=""

export DYLD_LIBRARY_PATH="$slurm_lib"
export SLURM_CONF="$slurm_conf"

/bin/mkdir -m 0755 "$run_dir" || exit 1
printf '#!/bin/sh\nprintf "must not execute\\n"\n' >"${run_dir}/not-executable.sh"
/bin/chmod 0644 "${run_dir}/not-executable.sh"
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

for case_name in nonexistent_command not_executable missing_chdir; do
	submit_result=$("$slurm_bin/sbatch" \
		--parsable \
		--partition=debug \
		--nodes=1 \
		--ntasks=1 \
		--cpus-per-task=1 \
		--mem=1G \
		--gres=gpu:apple:1 \
		--time=00:01:00 \
		--chdir=/tmp \
		--job-name="smd007-${case_name}" \
		--output="${run_dir}/${case_name}.out" \
		--error="${run_dir}/${case_name}.err" \
		"${stage_dir}/smd007_case_runner.sh" "$case_name" "$run_dir") || exit 1
	job_id=${submit_result%%;*}
	test_jobs="$test_jobs $job_id"
	printf '%s\t%s\n' "$case_name" "$job_id" >>"${run_dir}/jobs.tsv"
	printf 'submitted case=%s job_id=%s\n' "$case_name" "$job_id"
	wait_finished "$job_id" || exit 1

	if [ ! -s "${run_dir}/${case_name}.rc" ]; then
		printf 'error case=%s did not record srun rc\n' "$case_name" >&2
		exit 1
	fi
	rc=$(/bin/cat "${run_dir}/${case_name}.rc")
	printf 'case=%s srun_rc=%s\n' "$case_name" "$rc"
	if [ "$case_name" = missing_chdir ]; then
		if [ "$rc" -ne 0 ]; then
			printf 'error case=%s expected fallback success\n' "$case_name" >&2
			exit 1
		fi
		fallback_path=$(/usr/bin/sed -n '/^\//p' \
			"${run_dir}/${case_name}.out")
		expected_path=$(cd /tmp && /bin/pwd -P)
		if [ "$fallback_path" != "$expected_path" ]; then
			printf 'error case=%s fallback_path=%s expected=%s\n' \
				"$case_name" "$fallback_path" "$expected_path" >&2
			exit 1
		fi
		if ! /usr/bin/grep -q 'going to /tmp instead' \
			"${run_dir}/${case_name}.err"; then
			printf 'error case=%s did not record chdir fallback\n' "$case_name" >&2
			exit 1
		fi
	elif [ "$rc" -eq 0 ]; then
		printf 'error case=%s unexpectedly succeeded\n' "$case_name" >&2
		exit 1
	fi
done

for output_file in "$run_dir"/*.out "$run_dir"/*.err; do
	printf '[file=%s]\n' "$output_file"
	/bin/cat "$output_file"
done

trap - EXIT HUP INT TERM
printf 'SMD007_CLIENT_RUN_COMPLETE run_dir=%s\n' "$run_dir"
