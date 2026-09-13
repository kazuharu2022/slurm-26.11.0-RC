#!/bin/sh

set -u

srun_bin=/tmp/slurm-smd001-fixed/srun
slurm_conf=/tmp/slurm-smd001-fixed/slurm.conf
slurm_lib=/tmp/slurm-smd001-fixed
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir="/tmp/slurm-smd003-${run_stamp}"

/bin/mkdir -m 0755 "$run_dir" || exit 1

printf 'run_dir=%s\n' "$run_dir"

for expected_rc in 0 1 255; do
	stdout_file="${run_dir}/exit-${expected_rc}.out"
	stderr_file="${run_dir}/exit-${expected_rc}.err"
	rc_file="${run_dir}/exit-${expected_rc}.client-rc"

	DYLD_LIBRARY_PATH="$slurm_lib" \
	SLURM_CONF="$slurm_conf" \
		"$srun_bin" \
		--partition=debug \
		--nodes=1 \
		--ntasks=1 \
		--time=00:01:00 \
		--chdir=/tmp \
		--job-name="smd003-exit-${expected_rc}" \
		/bin/sh -c \
		'code=$1; printf "stdout_marker=exit_%s\n" "$code"; printf "stderr_marker=exit_%s\n" "$code" >&2; exit "$code"' \
		sh "$expected_rc" >"$stdout_file" 2>"$stderr_file"
	client_rc=$?

	printf '%s\n' "$client_rc" >"$rc_file"
	printf '\ncase=%s client_rc=%s\n' "$expected_rc" "$client_rc"
	printf '[case=%s stream=stdout]\n' "$expected_rc"
	/bin/cat "$stdout_file"
	printf '[case=%s stream=stderr]\n' "$expected_rc"
	/bin/cat "$stderr_file"
done

printf '\nSMD003_CLIENT_RUN_COMPLETE run_dir=%s\n' "$run_dir"
