#!/bin/sh

set -eu

case_name=$1
mode=$2
probe=$3
submit_limits=$4
sbatch=$5
slurm_conf=$6
partition=$7
stdout_pattern=$8
stderr_pattern=$9
job_script=${10}

case "$mode" in
default)
	;;
explicit)
	# Change soft limits only. The probe records the exact kernel values after
	# these shell-unit conversions, before sbatch captures them.
	ulimit -S -t 60
	ulimit -S -c 0
	ulimit -S -s 4096
	ulimit -S -n 256
	;;
*)
	/usr/bin/printf 'error: invalid mode=%s\n' "$mode" >&2
	exit 90
	;;
esac

"$probe" submit >"$submit_limits"

if [ "$mode" = explicit ]; then
	exec "$sbatch" --parsable \
		--propagate=CORE,CPU,NOFILE,STACK \
		--export=NONE --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=128M --time=00:01:00 --chdir=/tmp \
		--job-name="smd110-${case_name}" --output="$stdout_pattern" \
		--error="$stderr_pattern" "$job_script" "$case_name" "$probe"
fi

exec "$sbatch" --parsable \
	--export=NONE --partition="$partition" --nodes=1 --ntasks=1 \
	--cpus-per-task=1 --mem=128M --time=00:01:00 --chdir=/tmp \
	--job-name="smd110-${case_name}" --output="$stdout_pattern" \
	--error="$stderr_pattern" "$job_script" "$case_name" "$probe"
