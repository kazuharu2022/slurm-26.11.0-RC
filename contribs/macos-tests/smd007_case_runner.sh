#!/bin/sh

set -u

case_name=$1
run_dir=$2
srun_bin=/tmp/slurm-smd001-fixed/srun

export DYLD_LIBRARY_PATH=/tmp/slurm-smd001-fixed
export SLURM_CONF=/tmp/slurm-smd001-fixed/slurm.conf

printf 'case_begin=%s job_id=%s job_gpus=%s\n' \
	"$case_name" "${SLURM_JOB_ID:-unknown}" "${SLURM_JOB_GPUS:-not-set}"

case "$case_name" in
nonexistent_command)
	"$srun_bin" --nodes=1 --ntasks=1 \
		"${run_dir}/command-that-does-not-exist"
	;;
not_executable)
	"$srun_bin" --nodes=1 --ntasks=1 \
		"${run_dir}/not-executable.sh"
	;;
missing_chdir)
	"$srun_bin" --nodes=1 --ntasks=1 \
		--chdir="${run_dir}/directory-that-does-not-exist" \
		/bin/pwd
	;;
*)
	printf 'unknown case=%s\n' "$case_name" >&2
	exit 2
	;;
esac

rc=$?
printf '%s\n' "$rc" >"${run_dir}/${case_name}.rc"
printf 'case_end=%s srun_rc=%s\n' "$case_name" "$rc"
exit "$rc"
