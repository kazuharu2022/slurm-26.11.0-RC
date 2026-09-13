#!/bin/sh

set -u

source_root=/Users/REDACTED_USER/dev/slurm.26-05
candidate_slurmd_src=${source_root}/src/slurmd/slurmd/.libs/slurmd
candidate_lib_src=${source_root}/src/api/.libs/libslurmfull.dylib
slurm_prefix=/opt/slurm/26.11.0
slurm_conf=${slurm_prefix}/etc/slurm.conf
scontrol=${slurm_prefix}/bin/scontrol
squeue=${slurm_prefix}/bin/squeue
sbatch=${slurm_prefix}/bin/sbatch
sacct=${slurm_prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
sack_socket=/var/run/slurm/sack.socket
node_name=PC-210
test_user=testuser
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir="/tmp/slurm-smd012-sack-${run_stamp}"
candidate_dir=${run_dir}/candidate
smoke_dir=${run_dir}/smoke
old_pid=
first_pid=
second_pid=
smoke_job=
smoke_start_epoch=0
clean_stop_done=0
success=0

export SLURM_CONF="$slurm_conf"

is_running()
{
	check_pid=$1
	[ -n "$check_pid" ] && /bin/kill -0 "$check_pid" >/dev/null 2>&1
}

start_candidate()
{
	output_file=$1
	/usr/bin/nohup /usr/bin/env \
		DYLD_LIBRARY_PATH="$candidate_dir" \
		"${candidate_dir}/slurmd" -Dvvv -f "$slurm_conf" \
		>"$output_file" 2>&1 </dev/null &
	started_pid=$!
	printf '%s\n' "$started_pid"
}

wait_for_current_pid()
{
	expected_pid=$1
	attempt=0
	while [ "$attempt" -lt 30 ]; do
		if is_running "$expected_pid" && [ -f "$pid_file" ] && \
			[ "$(/bin/cat "$pid_file" 2>/dev/null)" = "$expected_pid" ]; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_for_stop()
{
	stopping_pid=$1
	attempt=0
	while is_running "$stopping_pid" && [ "$attempt" -lt 30 ]; do
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	! is_running "$stopping_pid"
}

start_original_recovery()
{
	recovery_log=$1
	/usr/bin/nohup "${slurm_prefix}/sbin/slurmd" -Dvvv -f "$slurm_conf" \
		>"$recovery_log" 2>&1 </dev/null &
	recovery_pid=$!
	if wait_for_current_pid "$recovery_pid"; then
		printf 'recovery: original slurmd started cleanly pid=%s\n' \
			"$recovery_pid" >&2
	else
		printf 'recovery: original slurmd failed; inspect %s\n' \
			"$recovery_log" >&2
	fi
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM

	if [ -n "$smoke_job" ]; then
		state=$("$squeue" -h -j "$smoke_job" -o '%T' 2>/dev/null)
		if [ -n "$state" ]; then
			printf 'cleanup smoke_job=%s state=%s\n' "$smoke_job" "$state" >&2
			"${slurm_prefix}/bin/scancel" "$smoke_job" || true
		fi
	fi

	if [ "$success" -ne 1 ] && [ "$clean_stop_done" -eq 1 ]; then
		current_pid=
		if [ -f "$pid_file" ]; then
			current_pid=$(/bin/cat "$pid_file" 2>/dev/null)
		fi
		if is_running "$current_pid"; then
			printf 'recovery: current slurmd remains alive pid=%s; no duplicate start\n' \
				"$current_pid" >&2
		else
			start_original_recovery "${run_dir}/slurmd-recovery.log"
		fi
	fi

	exit "$rc"
}

trap cleanup EXIT HUP INT TERM

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	printf 'error: run as root with sudo\n' >&2
	exit 77
fi

if ! ulimit -n unlimited; then
	printf 'error: unable to set RLIMIT_NOFILE soft limit to unlimited\n' >&2
	exit 1
fi
printf 'nofile_soft_limit=%s\n' "$(ulimit -n)"

if [ "${SMD012_CONTROLLER_IDLE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: first confirm on ubuntu2504 that squeue is empty and PC-210 is IDLE,' \
		'then rerun with SMD012_CONTROLLER_IDLE_CONFIRMED=YES' >&2
	exit 75
fi

for required_file in "$candidate_slurmd_src" "$candidate_lib_src" \
	"$slurm_conf" "$scontrol" "$squeue" "$sbatch" "$sacct"; do
	if [ ! -e "$required_file" ]; then
		printf 'error: missing %s\n' "$required_file" >&2
		exit 66
	fi
done

if ! /usr/bin/id "$test_user" >/dev/null 2>&1; then
	printf 'error: test user %s does not exist\n' "$test_user" >&2
	exit 67
fi

/bin/mkdir -m 0755 "$run_dir" "$candidate_dir" "$smoke_dir" || exit 1
/usr/sbin/chown "$test_user" "$smoke_dir" || exit 1
/usr/bin/install -m 0755 "$candidate_slurmd_src" "${candidate_dir}/slurmd" || exit 1
/usr/bin/install -m 0755 "$candidate_lib_src" \
	"${candidate_dir}/libslurmfull.dylib" || exit 1
printf 'run_dir=%s\n' "$run_dir"

/usr/bin/shasum -a 256 "${candidate_dir}/slurmd" \
	"${candidate_dir}/libslurmfull.dylib" >"${run_dir}/candidate-sha256.txt" || exit 1
version=$(
	/usr/bin/env DYLD_LIBRARY_PATH="$candidate_dir" \
		"${candidate_dir}/slurmd" -V
) || exit 1
printf 'candidate_version=%s\n' "$version"
if [ "$version" != 'slurm 26.11.0-0rc1' ]; then
	printf 'error: unexpected candidate version=%s\n' "$version" >&2
	exit 1
fi

if [ ! -f "$pid_file" ]; then
	printf 'error: missing pid file %s\n' "$pid_file" >&2
	exit 69
fi
old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*)
	printf 'error: invalid current pid=%s\n' "$old_pid" >&2
	exit 69
	;;
esac
old_command=$(/bin/ps -p "$old_pid" -o command=)
case "$old_command" in
*slurmd*) ;;
*)
	printf 'error: pid %s is not slurmd: %s\n' "$old_pid" "$old_command" >&2
	exit 69
	;;
esac
printf 'clean_stop old_pid=%s old_command=%s\n' "$old_pid" "$old_command"
/bin/kill -TERM "$old_pid" || exit 1
if ! wait_for_stop "$old_pid"; then
	printf 'error: old slurmd did not stop\n' >&2
	exit 1
fi
clean_stop_done=1

first_pid=$(start_candidate "${run_dir}/candidate-first.log")
printf 'start first_candidate_pid=%s\n' "$first_pid"
if ! wait_for_current_pid "$first_pid"; then
	printf 'error: first candidate did not become current\n' >&2
	exit 1
fi
attempt=0
while [ ! -S "$sack_socket" ] && [ "$attempt" -lt 30 ]; do
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if [ ! -S "$sack_socket" ]; then
	printf 'error: first candidate did not create %s\n' "$sack_socket" >&2
	exit 1
fi
first_identity=$(/usr/bin/stat -f '%d:%i' "$sack_socket") || exit 1
printf 'first_sack_identity=%s\n' "$first_identity"

"$scontrol" ping >"${run_dir}/controller-after-first.txt" 2>&1 || exit 1
"$scontrol" show node "$node_name" >"${run_dir}/node-after-first.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-after-first.txt"; then
	printf 'error: node is not IDLE after clean candidate start\n' >&2
	exit 75
fi
active_jobs=$("$squeue" -h -w "$node_name" -o '%i %T') || exit 1
if [ -n "$active_jobs" ]; then
	printf 'error: active jobs appeared; replacement not attempted\n%s\n' \
		"$active_jobs" >&2
	exit 75
fi

second_pid=$(start_candidate "${run_dir}/candidate-second.log")
printf 'start replacement_candidate_pid=%s old_candidate_pid=%s\n' \
	"$second_pid" "$first_pid"
if ! wait_for_current_pid "$second_pid"; then
	printf 'error: replacement candidate did not become current\n' >&2
	exit 1
fi
if ! wait_for_stop "$first_pid"; then
	printf 'error: first candidate did not stop after replacement\n' >&2
	exit 1
fi
if [ ! -S "$sack_socket" ]; then
	printf 'error: replacement removed the new SACK socket\n' >&2
	exit 1
fi
second_identity=$(/usr/bin/stat -f '%d:%i' "$sack_socket") || exit 1
printf 'second_sack_identity=%s\n' "$second_identity"
if [ "$first_identity" = "$second_identity" ]; then
	printf 'error: replacement did not create a distinguishable socket entry\n' >&2
	exit 1
fi

"$scontrol" ping >"${run_dir}/controller-after-replacement.txt" 2>&1 || exit 1
"$scontrol" show node "$node_name" >"${run_dir}/node-after-replacement.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-after-replacement.txt"; then
	printf 'error: node is not IDLE after replacement\n' >&2
	exit 1
fi

smoke_start_epoch=$(/bin/date '+%s')
submit_result=$(
	cd /tmp || exit 1
	/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
		SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=1G --gres=gpu:apple:1 --time=00:01:00 \
		--chdir=/tmp --job-name=smd012-sack-smoke \
		--output="${smoke_dir}/hostname.out" \
		--error="${smoke_dir}/hostname.err" --wrap=/bin/hostname
) || exit 1
smoke_job=${submit_result%%;*}
printf 'submitted smoke_job=%s\n' "$smoke_job"

attempt=0
while [ "$attempt" -lt 90 ]; do
	state=$("$squeue" -h -j "$smoke_job" -o '%T') || exit 1
	[ -z "$state" ] && break
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if [ "$attempt" -ge 90 ]; then
	printf 'error: smoke job remained state=%s\n' "$state" >&2
	exit 1
fi
smoke_elapsed=$(( $(/bin/date '+%s') - smoke_start_epoch ))
printf 'smoke_elapsed_seconds=%s\n' "$smoke_elapsed"
if [ "$smoke_elapsed" -gt 30 ]; then
	printf 'error: smoke job exceeded 30-second closeall regression limit\n' >&2
	exit 1
fi
"$sacct" -j "$smoke_job" \
	--format=JobID,JobName,User,State,ReqTRES,AllocTRES,ExitCode,NodeList -P \
	>"${run_dir}/sacct.txt" || exit 1
if ! "$sacct" -n -X -j "$smoke_job" --format=State,ExitCode -P | \
	/usr/bin/grep -Eq '^[[:space:]]*COMPLETED[[:space:]]*\|0:0'; then
	printf 'error: smoke accounting is not COMPLETED 0:0\n' >&2
	exit 1
fi
if ! /usr/bin/grep -Eq '^PC-210(\.local)?$' "${smoke_dir}/hostname.out"; then
	printf 'error: unexpected smoke hostname output\n' >&2
	exit 1
fi

"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || exit 1
"$squeue" -w "$node_name" >"${run_dir}/queue-final.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-final.txt" || \
	! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-final.txt" || \
	! /usr/bin/grep -q 'AllocTRES=$' "${run_dir}/node-final.txt"; then
	printf 'error: final node resources were not released\n' >&2
	exit 1
fi

/usr/bin/tail -n 300 /var/log/slurm/slurmd.log \
	>"${run_dir}/slurmd-log-tail.txt"
success=1
trap - EXIT HUP INT TERM
printf '%s\n' \
	"SMD012_SACK_GUARD_COMPLETE current_pid=${second_pid} smoke_job=${smoke_job} run_dir=${run_dir}" \
	"NOTICE current slurmd is the validated /tmp candidate; install it before reboot or cleanup."
