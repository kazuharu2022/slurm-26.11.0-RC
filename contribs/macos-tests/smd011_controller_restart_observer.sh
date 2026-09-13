#!/bin/sh

set -u

source_dir=/Users/REDACTED_USER/dev/slurm.26-05/contribs/macos-tests
slurm_prefix=/opt/slurm/26.11.0
slurm_conf=${slurm_prefix}/etc/slurm.conf
squeue=${slurm_prefix}/bin/squeue
scontrol=${slurm_prefix}/bin/scontrol
sbatch=${slurm_prefix}/bin/sbatch
scancel=${slurm_prefix}/bin/scancel
sacct=${slurm_prefix}/bin/sacct
sdiag=${slurm_prefix}/bin/sdiag
pid_file=/var/run/slurmd.pid
slurmd_log=/var/log/slurm/slurmd.log
node_name=PC-210
test_user=testuser
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir="/tmp/slurm-smd011-${run_stamp}"
job_dir="${run_dir}/job"
smoke_dir="${run_dir}/smoke"
target_job=
smoke_job=
batch_pid=
child_pid=
slurmd_pid=
old_data_since=
new_data_since=
slurmd_log_start=0
finish_requested=0
success=0
controller_restart_wait_attempts=300

export SLURM_CONF="$slurm_conf"

is_running()
{
	check_pid=$1
	[ -n "$check_pid" ] && /bin/kill -0 "$check_pid" >/dev/null 2>&1
}

queue_state()
{
	"$squeue" -h -j "$1" -o '%T'
}

extract_data_since()
{
	/usr/bin/awk '/^Data since/ { value=$NF; gsub(/[()]/, "", value); print value; exit }' "$1"
}

cancel_if_active()
{
	job_id=$1
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id" 2>/dev/null || true)
	if [ -n "$state" ]; then
		printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state" >&2
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ -n "$target_job" ] && [ "$finish_requested" -eq 0 ] && \
		[ -d "$job_dir" ]; then
		printf 'cleanup\n' >"${job_dir}/finish-requested.txt" 2>/dev/null || true
		/usr/sbin/chown "$test_user" "${job_dir}/finish-requested.txt" \
			>/dev/null 2>&1 || true
	fi
	cancel_if_active "$target_job"
	cancel_if_active "$smoke_job"
	if [ "$success" -ne 1 ]; then
		printf 'recovery: inspect controller and worker state; evidence=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		state=$(queue_state "$job_id") || return 1
		if [ -z "$state" ]; then
			printf 'job_gone job_id=%s wait_seconds=%s\n' "$job_id" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	printf 'error: job=%s remained state=%s\n' "$job_id" "$state" >&2
	return 1
}

wait_accounting_complete()
{
	job_id=$1
	output_file=$2
	attempt=0
	while [ "$attempt" -lt 20 ]; do
		"$sacct" -j "$job_id" \
			--format=JobID,JobName,User,State,ReqTRES,AllocTRES,Submit,Start,End,Elapsed,ExitCode,NodeList \
			-P >"$output_file" || return 1
		if "$sacct" -n -X -j "$job_id" --format=State,ExitCode -P |
			/usr/bin/grep -Eq '^[[:space:]]*COMPLETED[[:space:]]*\|0:0'; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	printf 'error: run as root with sudo\n' >&2
	exit 77
fi

for required_file in "$slurm_conf" "$squeue" "$scontrol" "$sbatch" \
	"$scancel" "$sacct" "$sdiag" "$pid_file" "$slurmd_log" \
	"${source_dir}/smd011_survivor_job.sh"; do
	if [ ! -e "$required_file" ]; then
		printf 'error: missing %s\n' "$required_file" >&2
		exit 66
	fi
done

if ! /usr/bin/id "$test_user" >/dev/null 2>&1; then
	printf 'error: test user %s does not exist\n' "$test_user" >&2
	exit 67
fi

/bin/mkdir -m 0755 "$run_dir" "$job_dir" "$smoke_dir" || exit 1
/usr/sbin/chown "$test_user" "$job_dir" "$smoke_dir" || exit 1
/usr/bin/install -o "$test_user" -m 0755 \
	"${source_dir}/smd011_survivor_job.sh" \
	"${job_dir}/survivor-job.sh" || exit 1
printf 'run_dir=%s\n' "$run_dir"
trap cleanup EXIT HUP INT TERM

active_jobs=$("$squeue" -h -w "$node_name" -o '%i %T %u %j') || exit 1
if [ -n "$active_jobs" ]; then
	printf 'error: node has active jobs; controller restart test not started\n%s\n' \
		"$active_jobs" >&2
	exit 75
fi
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-before.txt"; then
	printf 'error: node is not IDLE before test\n' >&2
	exit 75
fi

slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*)
	printf 'error: invalid slurmd pid=%s\n' "$slurmd_pid" >&2
	exit 69
	;;
esac
if ! is_running "$slurmd_pid"; then
	printf 'error: slurmd pid=%s is not running\n' "$slurmd_pid" >&2
	exit 69
fi
/bin/ps -p "$slurmd_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/slurmd-before.txt" || exit 1
slurmd_log_start=$(/usr/bin/wc -l <"$slurmd_log" | /usr/bin/tr -d ' ')

"$sdiag" >"${run_dir}/sdiag-before.txt" || exit 1
old_data_since=$(extract_data_since "${run_dir}/sdiag-before.txt")
case "$old_data_since" in
''|*[!0-9]*)
	printf 'error: unable to parse controller Data since\n' >&2
	exit 1
	;;
esac
printf 'controller_data_since_before=%s\n' "$old_data_since"

submit_result=$(
	cd /tmp || exit 1
	/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
		SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
		--exclusive --mem=1G --time=00:15:00 --chdir=/tmp \
		--job-name=smd011-survivor \
		--output="${job_dir}/survivor.out" \
		--error="${job_dir}/survivor.err" \
		"${job_dir}/survivor-job.sh" "$job_dir"
) || exit 1
target_job=${submit_result%%;*}
printf 'submitted target_job=%s\n' "$target_job"

attempt=0
while [ "$attempt" -lt 90 ]; do
	state=$(queue_state "$target_job") || exit 1
	if [ "$state" = RUNNING ] && [ -s "${job_dir}/ready.txt" ] && \
		[ -s "${job_dir}/heartbeat.txt" ]; then
		break
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if [ "$attempt" -ge 90 ]; then
	printf 'error: target job did not become ready state=%s\n' "$state" >&2
	exit 1
fi
batch_pid=$(/usr/bin/sed -n 's/^batch_pid=//p' "${job_dir}/ready.txt")
child_pid=$(/usr/bin/sed -n 's/^child_pid=//p' "${job_dir}/ready.txt")
case "$batch_pid:$child_pid" in
*[!0-9:]*|:|*:)
	printf 'error: invalid recorded process IDs batch=%s child=%s\n' \
		"$batch_pid" "$child_pid" >&2
	exit 1
	;;
esac
heartbeat_before=$(/usr/bin/sed -n 's/^count=\([0-9][0-9]*\).*/\1/p' \
	"${job_dir}/heartbeat.txt")
printf 'target_ready job_id=%s batch_pid=%s child_pid=%s heartbeat=%s\n' \
	"$target_job" "$batch_pid" "$child_pid" "$heartbeat_before"
printf 'SMD011_WAITING_FOR_CONTROLLER_RESTART job_id=%s old_data_since=%s\n' \
	"$target_job" "$old_data_since"
printf 'On ubuntu2504 root shell, now run: systemctl restart slurmctld\n'
printf 'controller_restart_observation_attempts=%s (approximately five minutes)\n' \
	"$controller_restart_wait_attempts"

: >"${run_dir}/sdiag-poll.log"
attempt=0
while [ "$attempt" -lt "$controller_restart_wait_attempts" ]; do
	if "$sdiag" >"${run_dir}/sdiag-current.txt" 2>>"${run_dir}/sdiag-poll.log"; then
		candidate=$(extract_data_since "${run_dir}/sdiag-current.txt")
		printf 'attempt=%s data_since=%s\n' "$attempt" "${candidate:-unparsed}" \
			>>"${run_dir}/sdiag-poll.log"
		if [ -n "$candidate" ] && [ "$candidate" != 0 ] && \
			[ "$candidate" != "$old_data_since" ]; then
			new_data_since=$candidate
			/bin/cp "${run_dir}/sdiag-current.txt" "${run_dir}/sdiag-after.txt"
			break
		fi
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if [ -z "$new_data_since" ]; then
	printf 'error: controller restart not detected within %s attempts\n' \
		"$controller_restart_wait_attempts" >&2
	exit 75
fi
printf 'controller_restart_detected old_data_since=%s new_data_since=%s attempts=%s\n' \
	"$old_data_since" "$new_data_since" "$attempt"

attempt=0
while [ "$attempt" -lt 60 ]; do
	state=$(queue_state "$target_job") || exit 1
	if [ "$state" = RUNNING ]; then
		break
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if [ "$state" != RUNNING ]; then
	printf 'error: target job state after restart=%s\n' "$state" >&2
	exit 1
fi
/bin/sleep 3
heartbeat_after=$(/usr/bin/sed -n 's/^count=\([0-9][0-9]*\).*/\1/p' \
	"${job_dir}/heartbeat.txt")
case "$heartbeat_after" in
''|*[!0-9]*)
	printf 'error: heartbeat after restart is invalid\n' >&2
	exit 1
	;;
esac
if [ "$heartbeat_after" -le "$heartbeat_before" ]; then
	printf 'error: job heartbeat did not advance across controller restart\n' >&2
	exit 1
fi
if ! is_running "$batch_pid" || ! is_running "$child_pid"; then
	printf 'error: job process did not survive controller restart\n' >&2
	exit 1
fi
if ! is_running "$slurmd_pid" || [ "$(/bin/cat "$pid_file")" != "$slurmd_pid" ]; then
	printf 'error: slurmd changed or stopped across controller restart\n' >&2
	exit 1
fi
printf 'survivor_after_restart state=%s heartbeat_before=%s heartbeat_after=%s\n' \
	"$state" "$heartbeat_before" "$heartbeat_after"

printf 'finish\n' >"${job_dir}/finish-requested.txt" || exit 1
/usr/sbin/chown "$test_user" "${job_dir}/finish-requested.txt" || exit 1
finish_requested=1
wait_job_gone "$target_job" || exit 1
if ! wait_accounting_complete "$target_job" "${run_dir}/target-sacct.txt"; then
	printf 'error: survivor job did not converge to COMPLETED 0:0\n' >&2
	exit 1
fi
if is_running "$batch_pid" || is_running "$child_pid"; then
	printf 'error: survivor job process remained after completion\n' >&2
	exit 1
fi

submit_result=$(
	cd /tmp || exit 1
	/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
		SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=1G --gres=gpu:apple:1 --time=00:01:00 \
		--chdir=/tmp --job-name=smd011-post-smoke \
		--output="${smoke_dir}/hostname.out" \
		--error="${smoke_dir}/hostname.err" --wrap=/bin/hostname
) || exit 1
smoke_job=${submit_result%%;*}
printf 'submitted smoke_job=%s\n' "$smoke_job"
wait_job_gone "$smoke_job" || exit 1
attempt=0
while [ ! -s "${smoke_dir}/hostname.out" ] && [ "$attempt" -lt 5 ]; do
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if ! wait_accounting_complete "$smoke_job" "${run_dir}/smoke-sacct.txt"; then
	printf 'error: post-restart smoke job is not COMPLETED 0:0\n' >&2
	exit 1
fi
if ! /usr/bin/grep -Eq '^PC-210(\.local)?$' "${smoke_dir}/hostname.out"; then
	printf 'error: post-restart hostname output mismatch\n' >&2
	exit 1
fi

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || exit 1
"$squeue" -j "$target_job,$smoke_job" >"${run_dir}/queue-after.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-after.txt" || \
	! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-after.txt" || \
	! /usr/bin/grep -q 'AllocTRES=$' "${run_dir}/node-after.txt"; then
	printf 'error: node resources were not fully released\n' >&2
	exit 1
fi

log_first=$((slurmd_log_start + 1))
/usr/bin/sed -n "${log_first},\$p" "$slurmd_log" \
	>"${run_dir}/slurmd-during-test.log"
/bin/ps -p "$slurmd_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/slurmd-after.txt" || exit 1

success=1
trap - EXIT HUP INT TERM
printf 'SMD011_ROOT_RUN_COMPLETE slurmd_pid=%s target_job=%s smoke_job=%s run_dir=%s\n' \
	"$slurmd_pid" "$target_job" "$smoke_job" "$run_dir"
