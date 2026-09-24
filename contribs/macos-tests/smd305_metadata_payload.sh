#!/bin/sh

set -eu

case_name=$1
marker=$2
hold_seconds=${3:-12}

/usr/bin/printf '%s\n' \
	"SMD305_PAYLOAD case=${case_name} pid=$$ ppid=${PPID:-UNSET} uid=$(/usr/bin/id -u) gid=$(/usr/bin/id -g) job=${SLURM_JOB_ID:-UNSET} step=${SLURM_STEP_ID:-UNSET} core_spec_env=${SLURM_CORE_SPEC:-UNSET} cpu_freq_req=${SLURM_CPU_FREQ_REQ:-UNSET}"
/usr/bin/printf '%s\n' \
	"case=${case_name} pid=$$ job=${SLURM_JOB_ID:-UNSET} step=${SLURM_STEP_ID:-UNSET} cpu_freq_req=${SLURM_CPU_FREQ_REQ:-UNSET}" \
	>"$marker"
/bin/sleep "$hold_seconds"
/usr/bin/printf 'SMD305_DONE case=%s pid=%s\n' "$case_name" "$$"
