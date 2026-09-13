#!/bin/sh

set -u

slurm_prefix=/opt/slurm/26.11.0
slurm_conf=${slurm_prefix}/etc/slurm.conf
slurmd=${slurm_prefix}/sbin/slurmd
squeue=${slurm_prefix}/bin/squeue
scontrol=${slurm_prefix}/bin/scontrol
sbatch=${slurm_prefix}/bin/sbatch
sacct=${slurm_prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
node_name=PC-210
test_user=testuser
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir="/tmp/slurm-smd008-${run_stamp}"
smoke_dir="${run_dir}/smoke"
old_pid=
new_pid=
smoke_job=
old_stopped=0
success=0
old_start_time=
new_start_time=

export SLURM_CONF="$slurm_conf"

is_running()
{
	check_pid=$1
	[ -n "$check_pid" ] && /bin/kill -0 "$check_pid" >/dev/null 2>&1
}

start_slurmd()
{
	output_file=$1
	/usr/bin/nohup "$slurmd" -Dvvv -f "$slurm_conf" \
		>"$output_file" 2>&1 </dev/null &
	new_pid=$!
	printf 'start_candidate_pid=%s\n' "$new_pid"
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM

	if [ -n "$smoke_job" ]; then
		state=$("$squeue" -h -j "$smoke_job" -o '%T' 2>/dev/null)
		if [ -n "$state" ]; then
			printf 'cleanup smoke_job=%s state=%s\n' "$smoke_job" "$state"
			"${slurm_prefix}/bin/scancel" "$smoke_job" || true
		fi
	fi

	if [ "$success" -ne 1 ] && [ "$old_stopped" -eq 1 ]; then
		current_pid=
		if [ -f "$pid_file" ]; then
			current_pid=$(/bin/cat "$pid_file" 2>/dev/null)
		fi
		if is_running "$new_pid"; then
			printf 'recovery: new slurmd candidate remains alive pid=%s; no duplicate start\n' \
				"$new_pid" >&2
		elif ! is_running "$current_pid"; then
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

trap cleanup EXIT HUP INT TERM

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	printf 'error: run as root with sudo\n' >&2
	exit 77
fi

for required_file in "$slurm_conf" "$slurmd" "$squeue" "$scontrol" \
	"$sbatch" "$sacct"; do
	if [ ! -e "$required_file" ]; then
		printf 'error: missing %s\n' "$required_file" >&2
		exit 66
	fi
done

if ! /usr/bin/id "$test_user" >/dev/null 2>&1; then
	printf 'error: test user %s does not exist\n' "$test_user" >&2
	exit 67
fi

/bin/mkdir -m 0755 "$run_dir" || exit 1
/bin/mkdir -m 0755 "$smoke_dir" || exit 1
/usr/sbin/chown "$test_user" "$smoke_dir" || exit 1
printf 'run_dir=%s\n' "$run_dir"

if ! active_jobs=$("$squeue" -h -w "$node_name" -o '%i %T'); then
	printf 'error: failed to query active jobs\n' >&2
	exit 1
fi
if [ -n "$active_jobs" ]; then
	printf 'error: node has active jobs; restart not attempted\n%s\n' \
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
	printf 'error: invalid old pid %s\n' "$old_pid" >&2
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
	printf 'error: node is not IDLE before restart\n' >&2
	exit 75
fi
old_start_time=$(/usr/bin/sed -n \
	's/.*SlurmdStartTime=\([^ ]*\).*/\1/p' "${run_dir}/node-before.txt")
if [ -z "$old_start_time" ]; then
	printf 'error: could not read old SlurmdStartTime\n' >&2
	exit 1
fi
printf 'old_pid=%s\nold_command=%s\n' "$old_pid" "$old_command" \
	>"${run_dir}/process-before.txt"
printf 'old_start_time=%s\n' "$old_start_time"

printf 'stop old_pid=%s signal=TERM\n' "$old_pid"
/bin/kill -TERM "$old_pid" || exit 1

attempt=0
while is_running "$old_pid" && [ "$attempt" -lt 30 ]; do
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if is_running "$old_pid"; then
	printf 'error: old slurmd remained after %s seconds\n' "$attempt" >&2
	exit 1
fi
old_stopped=1
printf 'old_stopped wait_seconds=%s\n' "$attempt"

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
	printf 'error: new slurmd exited; inspect %s\n' \
		"${run_dir}/slurmd-foreground.log" >&2
	exit 1
fi
if [ ! -f "$pid_file" ] || \
	[ "$(/bin/cat "$pid_file" 2>/dev/null)" != "$new_pid" ]; then
	printf 'error: pid file did not converge to new pid=%s\n' "$new_pid" >&2
	exit 1
fi
printf 'new_running pid=%s wait_seconds=%s\n' "$new_pid" "$attempt"

attempt=0
while [ "$attempt" -lt 60 ]; do
	if "$scontrol" show node "$node_name" >"${run_dir}/node-after-start.txt" \
		2>"${run_dir}/node-after-start.err" && \
		/usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-after-start.txt"; then
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
	printf 'error: node did not return to IDLE after restart\n' >&2
	exit 1
fi
printf 'node_registered state=IDLE old_start=%s new_start=%s wait_seconds=%s\n' \
	"$old_start_time" "$new_start_time" "$attempt"

submit_result=$(
	cd /tmp || exit 1
	/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
		SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=1G --gres=gpu:apple:1 --time=00:01:00 \
		--chdir=/tmp --job-name=smd008-restart-smoke \
		--output="${smoke_dir}/hostname.out" \
		--error="${smoke_dir}/hostname.err" \
		--wrap=/bin/hostname
) || exit 1
smoke_job=${submit_result%%;*}
printf 'submitted smoke_job=%s\n' "$smoke_job"

attempt=0
while [ "$attempt" -lt 90 ]; do
	if ! state=$("$squeue" -h -j "$smoke_job" -o '%T'); then
		printf 'error: failed to query smoke job=%s\n' "$smoke_job" >&2
		exit 1
	fi
	if [ -z "$state" ]; then
		break
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if [ "$attempt" -ge 90 ]; then
	printf 'error: smoke job remained in queue state=%s\n' "$state" >&2
	exit 1
fi
printf 'smoke_finished job_id=%s wait_seconds=%s\n' "$smoke_job" "$attempt"

attempt=0
while [ ! -s "${smoke_dir}/hostname.out" ] && [ "$attempt" -lt 5 ]; do
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if ! /usr/bin/grep -Eq '^PC-210(\.local)?$' \
	"${smoke_dir}/hostname.out"; then
	printf 'error: unexpected hostname output\n' >&2
	exit 1
fi

"$sacct" -j "$smoke_job" \
	--format=JobID,JobName,User,State,ReqTRES,AllocTRES,Submit,Start,End,Elapsed,ExitCode,NodeList \
	-P >"${run_dir}/sacct.txt" || exit 1
if ! "$sacct" -n -X -j "$smoke_job" --format=State,ExitCode -P | \
	/usr/bin/grep -Eq '^[[:space:]]*COMPLETED[[:space:]]*\|0:0'; then
	printf 'error: smoke job accounting is not COMPLETED 0:0\n' >&2
	exit 1
fi

"$squeue" -j "$smoke_job" >"${run_dir}/queue-after.txt" || exit 1
"$scontrol" show node "$node_name" >"${run_dir}/node-after-job.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-after-job.txt" || \
	! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-after-job.txt" || \
	! /usr/bin/grep -q 'AllocTRES=$' "${run_dir}/node-after-job.txt"; then
	printf 'error: node resources were not fully released\n' >&2
	exit 1
fi

/usr/bin/tail -n 200 /var/log/slurm/slurmd.log \
	>"${run_dir}/slurmd-log-tail.txt"
/bin/ps -p "$new_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/process-after.txt"

success=1
trap - EXIT HUP INT TERM
printf 'SMD008_ROOT_RUN_COMPLETE new_pid=%s smoke_job=%s run_dir=%s\n' \
	"$new_pid" "$smoke_job" "$run_dir"
