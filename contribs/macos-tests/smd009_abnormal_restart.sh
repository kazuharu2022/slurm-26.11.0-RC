#!/bin/sh

set -u

source_dir=/Users/REDACTED_USER/dev/slurm.26-05/contribs/macos-tests
slurm_prefix=/opt/slurm/26.11.0
slurm_conf=${slurm_prefix}/etc/slurm.conf
slurmd=${slurm_prefix}/sbin/slurmd
squeue=${slurm_prefix}/bin/squeue
scontrol=${slurm_prefix}/bin/scontrol
sbatch=${slurm_prefix}/bin/sbatch
scancel=${slurm_prefix}/bin/scancel
sacct=${slurm_prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
node_name=PC-210
test_user=testuser
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir="/tmp/slurm-smd009-${run_stamp}"
job_dir="${run_dir}/job"
smoke_dir="${run_dir}/smoke"
old_pid=
new_pid=
target_job=
smoke_job=
batch_pid=
child_pid=
old_start_time=
new_start_time=
old_stopped=0
success=0

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

start_slurmd()
{
	output_file=$1
	/usr/bin/nohup "$slurmd" -Dvvv -f "$slurm_conf" \
		>"$output_file" 2>&1 </dev/null &
	new_pid=$!
	printf 'start_candidate_pid=%s\n' "$new_pid"
}

cancel_if_active()
{
	job_id=$1
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id" 2>/dev/null)
	if [ -n "$state" ]; then
		printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state"
		"$scancel" "$job_id" || true
	fi
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM

	cancel_if_active "$target_job"
	cancel_if_active "$smoke_job"

	if [ "$success" -ne 1 ] && [ "$old_stopped" -eq 1 ]; then
		current_pid=
		if [ -f "$pid_file" ]; then
			current_pid=$(/bin/cat "$pid_file" 2>/dev/null)
		fi
		if is_running "$new_pid"; then
			printf 'recovery: new slurmd candidate remains alive pid=%s; no duplicate start\n' \
				"$new_pid" >&2
		elif is_running "$current_pid"; then
			printf 'recovery: current slurmd remains alive pid=%s; no duplicate start\n' \
				"$current_pid" >&2
		else
			printf 'recovery: slurmd absent; restarting original command\n' >&2
			start_slurmd "${run_dir}/slurmd-recovery.log"
			/bin/sleep 3
			if is_running "$new_pid"; then
				printf 'recovery: slurmd restarted pid=%s\n' "$new_pid" >&2
			else
				printf 'recovery: slurmd restart failed; inspect %s\n' \
					"${run_dir}/slurmd-recovery.log" >&2
			fi
		fi
	fi

	exit "$rc"
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		if ! state=$(queue_state "$job_id"); then
			printf 'error: failed to query job=%s\n' "$job_id" >&2
			return 1
		fi
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

trap cleanup EXIT HUP INT TERM

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	printf 'error: run as root with sudo\n' >&2
	exit 77
fi

for required_file in "$slurm_conf" "$slurmd" "$squeue" "$scontrol" \
	"$sbatch" "$scancel" "$sacct" "${source_dir}/smd009_survivor_job.sh"; do
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
	"${source_dir}/smd009_survivor_job.sh" "${job_dir}/survivor-job.sh" || exit 1
printf 'run_dir=%s\n' "$run_dir"

if ! active_jobs=$("$squeue" -h -w "$node_name" -o '%i %T'); then
	printf 'error: failed to query active jobs\n' >&2
	exit 1
fi
if [ -n "$active_jobs" ]; then
	printf 'error: node has active jobs; abnormal restart not attempted\n%s\n' \
		"$active_jobs" >&2
	exit 75
fi

if [ ! -f "$pid_file" ]; then
	printf 'error: missing pid file %s\n' "$pid_file" >&2
	exit 69
fi
old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*)
	printf 'error: invalid slurmd pid=%s\n' "$old_pid" >&2
	exit 69
	;;
esac
old_command=$(/bin/ps -p "$old_pid" -o command=)
case "$old_command" in
"$slurmd"*) ;;
*)
	printf 'error: pid %s is not expected slurmd: %s\n' \
		"$old_pid" "$old_command" >&2
	exit 69
	;;
esac

"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-before.txt"; then
	printf 'error: node is not IDLE before test\n' >&2
	exit 75
fi
old_start_time=$(/usr/bin/sed -n \
	's/.*SlurmdStartTime=\([^ ]*\).*/\1/p' "${run_dir}/node-before.txt")
[ -n "$old_start_time" ] || exit 1

submit_result=$(
	cd /tmp || exit 1
	/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
		SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
		--exclusive --mem=1G --gres=gpu:apple:1 --time=00:03:00 \
		--chdir=/tmp --job-name=smd009-survivor \
		--output="${job_dir}/survivor.out" \
		--error="${job_dir}/survivor.err" \
		"${job_dir}/survivor-job.sh" "$job_dir"
) || exit 1
target_job=${submit_result%%;*}
printf 'submitted target_job=%s\n' "$target_job"

attempt=0
while [ "$attempt" -lt 90 ]; do
	state=$(queue_state "$target_job") || exit 1
	if [ "$state" = RUNNING ] && [ -s "${job_dir}/ready.txt" ]; then
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
printf 'target_ready job_id=%s batch_pid=%s child_pid=%s\n' \
	"$target_job" "$batch_pid" "$child_pid"
{
	/bin/ps -p "$old_pid" -o user=,pid=,ppid=,pgid=,state=,command=
	/bin/ps -p "$batch_pid" -o user=,pid=,ppid=,pgid=,state=,command=
	/bin/ps -p "$child_pid" -o user=,pid=,ppid=,pgid=,state=,command=
} >"${run_dir}/process-before-kill.txt"

printf 'kill slurmd_pid=%s signal=KILL target_job=%s\n' "$old_pid" "$target_job"
/bin/kill -KILL "$old_pid" || exit 1
old_stopped=1
attempt=0
while is_running "$old_pid" && [ "$attempt" -lt 30 ]; do
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if is_running "$old_pid"; then
	printf 'error: killed slurmd remained after %s seconds\n' "$attempt" >&2
	exit 1
fi
printf 'old_slurmd_gone wait_seconds=%s\n' "$attempt"

start_slurmd "${run_dir}/slurmd-foreground.log"
attempt=0
while [ "$attempt" -lt 30 ]; do
	if is_running "$new_pid" && [ -f "$pid_file" ] && \
		[ "$(/bin/cat "$pid_file" 2>/dev/null)" = "$new_pid" ]; then
		break
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if ! is_running "$new_pid"; then
	printf 'error: new slurmd exited\n' >&2
	exit 1
fi
if [ ! -f "$pid_file" ] || \
	[ "$(/bin/cat "$pid_file" 2>/dev/null)" != "$new_pid" ]; then
	printf 'error: pid file did not converge to new pid=%s\n' "$new_pid" >&2
	exit 1
fi

attempt=0
while [ "$attempt" -lt 60 ]; do
	if "$scontrol" show node "$node_name" >"${run_dir}/node-after-start.txt" \
		2>"${run_dir}/node-after-start.err"; then
		new_start_time=$(/usr/bin/sed -n \
			's/.*SlurmdStartTime=\([^ ]*\).*/\1/p' \
			"${run_dir}/node-after-start.txt")
		if [ -n "$new_start_time" ] && \
			[ "$new_start_time" != "$old_start_time" ]; then
			break
		fi
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if [ "$attempt" -ge 60 ]; then
	printf 'error: controller did not observe restarted slurmd\n' >&2
	exit 1
fi
printf 'slurmd_restarted old_pid=%s new_pid=%s old_start=%s new_start=%s\n' \
	"$old_pid" "$new_pid" "$old_start_time" "$new_start_time"

state_after_restart=$(queue_state "$target_job") || exit 1
printf 'target_state_after_restart=%s\n' "${state_after_restart:-not-in-queue}"
{
	/bin/ps -p "$batch_pid" -o user=,pid=,ppid=,pgid=,state=,command=
	/bin/ps -p "$child_pid" -o user=,pid=,ppid=,pgid=,state=,command=
} >"${run_dir}/process-after-restart.txt" 2>&1 || true

/bin/sleep 5
state_after_observation=$(queue_state "$target_job") || exit 1
printf 'target_state_after_5s=%s\n' "${state_after_observation:-not-in-queue}"
if [ -n "$state_after_observation" ]; then
	"$scancel" "$target_job" || exit 1
	printf 'cancel target_job=%s\n' "$target_job"
fi
wait_job_gone "$target_job" || exit 1

attempt=0
while { is_running "$batch_pid" || is_running "$child_pid"; } && \
	[ "$attempt" -lt 30 ]; do
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if is_running "$batch_pid" || is_running "$child_pid"; then
	printf 'error: job processes remain batch=%s child=%s\n' \
		"$batch_pid" "$child_pid" >&2
	{
		/bin/ps -p "$batch_pid" -o user=,pid=,ppid=,pgid=,state=,command=
		/bin/ps -p "$child_pid" -o user=,pid=,ppid=,pgid=,state=,command=
	} >"${run_dir}/residual-processes.txt" 2>&1 || true
	for residual_pid in "$batch_pid" "$child_pid"; do
		if is_running "$residual_pid"; then
			/bin/kill -TERM "$residual_pid" >/dev/null 2>&1 || true
		fi
	done
	/bin/sleep 2
	for residual_pid in "$batch_pid" "$child_pid"; do
		if is_running "$residual_pid"; then
			/bin/kill -KILL "$residual_pid" >/dev/null 2>&1 || true
		fi
	done
	exit 1
fi
printf 'target_process_cleanup=PASS wait_seconds=%s\n' "$attempt"

attempt=0
while [ "$attempt" -lt 15 ]; do
"$sacct" -j "$target_job" \
	--format=JobID,JobName,User,State,ReqTRES,AllocTRES,Submit,Start,End,Elapsed,ExitCode,NodeList \
	-P >"${run_dir}/target-sacct.txt" || exit 1
target_accounting=$("$sacct" -n -X -j "$target_job" \
	--format=State,ExitCode -P | /usr/bin/sed -n '1p')
case "$target_accounting" in
''|PENDING*|RUNNING*|COMPLETING*)
	printf 'error: target accounting is not terminal: %s\n' \
		"${target_accounting:-empty}" >&2
	exit 1
	;;
esac
printf 'target_accounting=%s\n' "$target_accounting"
	if /usr/bin/grep -q "^${target_job}|" "${run_dir}/target-sacct.txt"; then
		break
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if [ "$attempt" -ge 15 ]; then
	printf 'error: target accounting record did not appear\n' >&2
	exit 1
fi

submit_result=$(
	cd /tmp || exit 1
	/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
		SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=1G --gres=gpu:apple:1 --time=00:01:00 \
		--chdir=/tmp --job-name=smd009-post-smoke \
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
if ! /usr/bin/grep -Eq '^PC-210(\.local)?$' "${smoke_dir}/hostname.out"; then
	printf 'error: post-restart smoke hostname mismatch\n' >&2
	exit 1
fi
"$sacct" -j "$smoke_job" \
	--format=JobID,JobName,User,State,ReqTRES,AllocTRES,Submit,Start,End,Elapsed,ExitCode,NodeList \
	-P >"${run_dir}/smoke-sacct.txt" || exit 1
if ! "$sacct" -n -X -j "$smoke_job" --format=State,ExitCode -P | \
	/usr/bin/grep -Eq '^[[:space:]]*COMPLETED[[:space:]]*\|0:0'; then
	printf 'error: post-restart smoke job is not COMPLETED 0:0\n' >&2
	exit 1
fi

"$squeue" -j "$target_job,$smoke_job" >"${run_dir}/queue-after.txt" || exit 1
"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-after.txt" || \
	! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-after.txt" || \
	! /usr/bin/grep -q 'AllocTRES=$' "${run_dir}/node-after.txt"; then
	printf 'error: node resources were not fully released\n' >&2
	exit 1
fi
if ! is_running "$new_pid" || [ ! -f "$pid_file" ] || \
	[ "$(/bin/cat "$pid_file" 2>/dev/null)" != "$new_pid" ]; then
	printf 'error: final slurmd process or pid file mismatch\n' >&2
	exit 1
fi

/usr/bin/tail -n 250 /var/log/slurm/slurmd.log >"${run_dir}/slurmd-log-tail.txt"
/bin/ps -p "$new_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/slurmd-process-after.txt"

success=1
trap - EXIT HUP INT TERM
printf 'SMD009_ROOT_RUN_COMPLETE new_pid=%s target_job=%s smoke_job=%s run_dir=%s\n' \
	"$new_pid" "$target_job" "$smoke_job" "$run_dir"
