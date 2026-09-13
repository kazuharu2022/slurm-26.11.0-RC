#!/bin/sh

set -u

slurm_prefix=/opt/slurm/26.11.0
slurm_conf=${slurm_prefix}/etc/slurm.conf
slurmd=${slurm_prefix}/sbin/slurmd
scontrol=${slurm_prefix}/bin/scontrol
squeue=${slurm_prefix}/bin/squeue
sbatch=${slurm_prefix}/bin/sbatch
scancel=${slurm_prefix}/bin/scancel
sacct=${slurm_prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
sack_socket=/var/run/slurm/sack.socket
production_log=/var/log/slurm/slurmd.log
node_name=PC-210
test_user=testuser
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir="/tmp/slurm-smd012-${run_stamp}"
backup_conf=${run_dir}/slurm.conf.before
candidate_conf=${run_dir}/slurm.conf.alternate-log
alternate_log=${run_dir}/slurmd-alternate.log
smoke_dir=${run_dir}/smoke
smoke_job=
config_modified=0
success=0
old_pid=
old_start=
production_log_start=0
stable_count=0
reconfigure_start_epoch=0

export SLURM_CONF="$slurm_conf"

queue_state()
{
	"$squeue" -h -j "$1" -o '%T'
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

restore_config()
{
	[ "$config_modified" -eq 1 ] || return 0
	printf 'recovery: restoring %s and requesting reconfigure\n' "$slurm_conf" >&2
	/bin/cp "$backup_conf" "$slurm_conf" || return 1
	"$scontrol" reconfigure >/dev/null 2>&1 || return 1
	config_modified=0
	return 0
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$smoke_job"
	if ! restore_config; then
		printf 'fatal recovery: verify %s against %s, then reconfigure\n' \
			"$slurm_conf" "$backup_conf" >&2
		rc=1
	fi
	if [ "$success" -ne 1 ]; then
		printf 'recovery: inspect worker/controller state; evidence=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

extract_start_time()
{
	/usr/bin/awk '
	{
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^SlurmdStartTime=/) {
				sub(/^SlurmdStartTime=/, "", $i)
				print $i
				exit
			}
		}
	}' "$1"
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

for required_file in "$slurm_conf" "$slurmd" "$scontrol" "$squeue" \
	"$sbatch" "$scancel" "$sacct" "$pid_file" "$production_log"; do
	if [ ! -e "$required_file" ]; then
		printf 'error: missing %s\n' "$required_file" >&2
		exit 66
	fi
done
if ! /usr/bin/id "$test_user" >/dev/null 2>&1; then
	printf 'error: test user %s does not exist\n' "$test_user" >&2
	exit 67
fi

/bin/mkdir -m 0755 "$run_dir" "$smoke_dir" || exit 1
/usr/sbin/chown "$test_user" "$smoke_dir" || exit 1
printf 'run_dir=%s\n' "$run_dir"
trap cleanup EXIT HUP INT TERM

active_jobs=$("$squeue" -h -o '%i %T %u %j %N') || exit 1
if [ -n "$active_jobs" ]; then
	printf 'error: cluster has active jobs; reconfigure test not started\n%s\n' \
		"$active_jobs" >&2
	exit 75
fi
"$scontrol" ping >"${run_dir}/controller-before.txt" || exit 1
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-before.txt"; then
	printf 'error: node is not IDLE before test\n' >&2
	exit 75
fi

old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*)
	printf 'error: invalid slurmd pid=%s\n' "$old_pid" >&2
	exit 69
	;;
esac
if ! /bin/kill -0 "$old_pid" >/dev/null 2>&1; then
	printf 'error: slurmd pid=%s is not running\n' "$old_pid" >&2
	exit 69
fi
old_start=$(extract_start_time "${run_dir}/node-before.txt")
/bin/ps -p "$old_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/slurmd-before.txt" || exit 1
production_log_start=$(/usr/bin/wc -l <"$production_log" | /usr/bin/tr -d ' ')

/bin/cp -p "$slurm_conf" "$backup_conf" || exit 1
/usr/bin/shasum -a 256 "$slurm_conf" >"${run_dir}/config-before.sha256" || exit 1
if [ "$(/usr/bin/grep -c '^SlurmdLogFile=' "$slurm_conf")" -ne 1 ] || \
	! /usr/bin/grep -qx 'SlurmdLogFile=/var/log/slurm/slurmd.log' "$slurm_conf"; then
	printf 'error: expected exactly SlurmdLogFile=/var/log/slurm/slurmd.log\n' >&2
	exit 65
fi

/usr/bin/sed \
	"s#^SlurmdLogFile=/var/log/slurm/slurmd.log\$#SlurmdLogFile=${alternate_log}#" \
	"$backup_conf" >"$candidate_conf" || exit 1
if ! /usr/bin/grep -qx "SlurmdLogFile=${alternate_log}" "$candidate_conf"; then
	printf 'error: candidate log path was not generated\n' >&2
	exit 1
fi
"$slurmd" -C -f "$candidate_conf" >"${run_dir}/candidate-parse.txt" 2>&1 || {
	printf 'error: candidate configuration did not parse\n' >&2
	exit 1
}
: >"$alternate_log" || exit 1

/bin/sleep 2
/bin/cp "$candidate_conf" "$slurm_conf" || exit 1
config_modified=1
/usr/bin/shasum -a 256 "$slurm_conf" >"${run_dir}/config-alternate.sha256" || exit 1
printf 'apply alternate_log=%s\n' "$alternate_log"
reconfigure_start_epoch=$(/bin/date '+%s')
"$scontrol" reconfigure >"${run_dir}/reconfigure-alternate.out" \
	2>"${run_dir}/reconfigure-alternate.err" || exit 1

attempt=0
stable_count=0
while [ "$attempt" -lt 120 ]; do
	if "$scontrol" show node "$node_name" \
		>"${run_dir}/node-alternate.txt" 2>"${run_dir}/node-alternate.err"; then
		candidate_start=$(extract_start_time \
			"${run_dir}/node-alternate.txt" 2>/dev/null || true)
		if [ -s "$alternate_log" ] && [ -S "$sack_socket" ] && \
			[ -n "$candidate_start" ] && \
			[ "$candidate_start" != None ] && \
			[ "$candidate_start" != "$old_start" ] && \
			/usr/bin/grep -q 'State=IDLE ' \
				"${run_dir}/node-alternate.txt"; then
			new_start=$candidate_start
			stable_count=$((stable_count + 1))
		else
			stable_count=0
		fi
	else
		stable_count=0
	fi
	if [ "$stable_count" -ge 3 ]; then
		break
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if [ "$attempt" -ge 120 ]; then
	printf 'error: alternate log/re-registration not observed\n' >&2
	exit 1
fi
alternate_elapsed=$(( $(/bin/date '+%s') - reconfigure_start_epoch ))
printf 'alternate_reconfigure_elapsed_seconds=%s\n' "$alternate_elapsed"
if [ "$alternate_elapsed" -gt 30 ]; then
	printf 'error: alternate reconfigure exceeded 30-second regression limit\n' >&2
	exit 1
fi
if [ "$(/bin/cat "$pid_file")" != "$old_pid" ] || \
	! /bin/kill -0 "$old_pid" >/dev/null 2>&1; then
	printf 'error: foreground slurmd PID changed during reconfigure\n' >&2
	exit 1
fi
printf 'alternate_applied pid=%s old_start=%s new_start=%s wait_seconds=%s\n' \
	"$old_pid" "$old_start" "$new_start" "$attempt"

/bin/sleep 2
/bin/cp "$backup_conf" "$slurm_conf" || exit 1
printf 'restore production_log=%s\n' "$production_log"
reconfigure_start_epoch=$(/bin/date '+%s')
"$scontrol" reconfigure >"${run_dir}/reconfigure-restore.out" \
	2>"${run_dir}/reconfigure-restore.err" || exit 1

attempt=0
stable_count=0
while [ "$attempt" -lt 120 ]; do
	current_lines=$(/usr/bin/wc -l <"$production_log" | /usr/bin/tr -d ' ')
	if "$scontrol" show node "$node_name" \
		>"${run_dir}/node-restored.txt" 2>"${run_dir}/node-restored.err"; then
		candidate_start=$(extract_start_time \
			"${run_dir}/node-restored.txt" 2>/dev/null || true)
		if [ "$current_lines" -gt "$production_log_start" ] && \
			[ -S "$sack_socket" ] && [ -n "$candidate_start" ] && \
			[ "$candidate_start" != None ] && \
			[ "$candidate_start" != "$new_start" ] && \
			/usr/bin/grep -q 'State=IDLE ' \
				"${run_dir}/node-restored.txt"; then
			restored_start=$candidate_start
			stable_count=$((stable_count + 1))
		else
			stable_count=0
		fi
	else
		stable_count=0
	fi
	if [ "$stable_count" -ge 3 ]; then
		break
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if [ "$attempt" -ge 120 ]; then
	printf 'error: production log/re-registration was not restored\n' >&2
	exit 1
fi
restore_elapsed=$(( $(/bin/date '+%s') - reconfigure_start_epoch ))
printf 'restore_reconfigure_elapsed_seconds=%s\n' "$restore_elapsed"
if [ "$restore_elapsed" -gt 30 ]; then
	printf 'error: production reconfigure exceeded 30-second regression limit\n' >&2
	exit 1
fi
if [ "$(/bin/cat "$pid_file")" != "$old_pid" ] || \
	! /bin/kill -0 "$old_pid" >/dev/null 2>&1; then
	printf 'error: foreground slurmd PID changed after restore\n' >&2
	exit 1
fi
/usr/bin/shasum -a 256 "$slurm_conf" >"${run_dir}/config-restored.sha256" || exit 1
if ! /usr/bin/cmp -s "$backup_conf" "$slurm_conf"; then
	printf 'error: production configuration was not restored byte-for-byte\n' >&2
	exit 1
fi
config_modified=0
printf 'production_restored pid=%s restored_start=%s wait_seconds=%s\n' \
	"$old_pid" "$restored_start" "$attempt"

submit_result=$(
	cd /tmp || exit 1
	/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
		SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=1G --gres=gpu:apple:1 --time=00:01:00 \
		--chdir=/tmp --job-name=smd012-post-smoke \
		--output="${smoke_dir}/hostname.out" \
		--error="${smoke_dir}/hostname.err" --wrap=/bin/hostname
) || exit 1
smoke_job=${submit_result%%;*}
printf 'submitted smoke_job=%s\n' "$smoke_job"
wait_job_gone "$smoke_job" || exit 1
if ! wait_accounting_complete "$smoke_job" "${run_dir}/smoke-sacct.txt"; then
	printf 'error: post-reconfigure smoke job is not COMPLETED 0:0\n' >&2
	exit 1
fi
if ! /usr/bin/grep -Eq '^PC-210(\.local)?$' "${smoke_dir}/hostname.out"; then
	printf 'error: post-reconfigure hostname output mismatch\n' >&2
	exit 1
fi

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || exit 1
"$squeue" -j "$smoke_job" >"${run_dir}/queue-after.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-after.txt" || \
	! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-after.txt" || \
	! /usr/bin/grep -q 'AllocTRES=$' "${run_dir}/node-after.txt"; then
	printf 'error: node resources were not fully released\n' >&2
	exit 1
fi
/usr/bin/grep -Ei 'checksum.*(mismatch|different)|different.*slurm\.conf' \
	"$alternate_log" >"${run_dir}/worker-config-hash-warnings.txt" || true

log_first=$((production_log_start + 1))
/usr/bin/sed -n "${log_first},\$p" "$production_log" \
	>"${run_dir}/production-log-during-test.log"
/bin/ps -p "$old_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/slurmd-after.txt" || exit 1

success=1
trap - EXIT HUP INT TERM
printf 'SMD012_ROOT_RUN_COMPLETE slurmd_pid=%s smoke_job=%s run_dir=%s\n' \
	"$old_pid" "$smoke_job" "$run_dir"
