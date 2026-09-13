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
pid_file=/var/run/slurmd.pid
slurmd_log=/var/log/slurm/slurmd.log
node_name=PC-210
test_user=testuser
controller_addr=192.168.10.180
controller_port=6817
route_interface=en0
source_addr=192.168.10.127
test_anchor=com.apple/slurm-smd010
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir="/tmp/slurm-smd010-${run_stamp}"
job_dir="${run_dir}/job"
smoke_dir="${run_dir}/smoke"
rule_file="${run_dir}/smd010.pf"
pf_token=
pf_enabled_by_test=0
block_loaded=0
target_job=
smoke_job=
batch_pid=
child_pid=
slurmd_pid=
slurmd_log_start=0
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

clear_block()
{
	if [ "$block_loaded" -eq 1 ]; then
		if ! /sbin/pfctl -a "$test_anchor" -F rules \
			>"${run_dir}/pf-clear-last.txt" 2>&1; then
			return 1
		fi
		block_loaded=0
	fi
	return 0
}

release_pf_reference()
{
	if [ "$pf_enabled_by_test" -eq 1 ] && [ -n "$pf_token" ]; then
		if ! /sbin/pfctl -X "$pf_token" \
			>"${run_dir}/pf-release.txt" 2>&1; then
			return 1
		fi
		pf_enabled_by_test=0
		pf_token=
	fi
	return 0
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
	clear_block || true
	release_pf_reference || true
	cancel_if_active "$target_job"
	cancel_if_active "$smoke_job"
	if [ "$success" -ne 1 ]; then
		/usr/bin/nc -vz -G 3 "$controller_addr" "$controller_port" \
			>"${run_dir}/recovery-connectivity.txt" 2>&1 || true
		printf 'recovery: PF test anchor cleared and enable token released; inspect %s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

load_block()
{
	phase=$1
	/sbin/pfctl -a "$test_anchor" -f "$rule_file" \
		>"${run_dir}/pf-load-${phase}.txt" 2>&1 || return 1
	block_loaded=1
	/sbin/pfctl -a "$test_anchor" -sr \
		>"${run_dir}/pf-rule-${phase}.txt" 2>&1 || return 1
	if ! /usr/bin/grep -q 'block drop out quick' \
		"${run_dir}/pf-rule-${phase}.txt"; then
		printf 'error: PF block rule was not visible for phase=%s\n' "$phase" >&2
		return 1
	fi
	if /usr/bin/nc -vz -G 3 "$controller_addr" "$controller_port" \
		>"${run_dir}/blocked-nc-${phase}.txt" 2>&1; then
		printf 'error: controller remained reachable during phase=%s\n' "$phase" >&2
		return 1
	fi
	/sbin/pfctl -a "$test_anchor" -vvsr \
		>"${run_dir}/pf-counter-${phase}.txt" 2>&1 || true
	printf 'blocked phase=%s destination=%s:%s\n' \
		"$phase" "$controller_addr" "$controller_port"
}

unload_block()
{
	phase=$1
	/sbin/pfctl -a "$test_anchor" -F rules \
		>"${run_dir}/pf-clear-${phase}.txt" 2>&1 || return 1
	block_loaded=0
	/sbin/pfctl -a "$test_anchor" -sr \
		>"${run_dir}/pf-rule-after-${phase}.txt" 2>&1 || return 1
	if /usr/bin/grep -q 'block drop out quick' \
		"${run_dir}/pf-rule-after-${phase}.txt"; then
		printf 'error: PF block rule remained after phase=%s\n' "$phase" >&2
		return 1
	fi
	/usr/bin/nc -vz -G 3 "$controller_addr" "$controller_port" \
		>"${run_dir}/recovered-nc-${phase}.txt" 2>&1 || return 1
	printf 'recovered phase=%s destination=%s:%s\n' \
		"$phase" "$controller_addr" "$controller_port"
}

wait_accounting_complete()
{
	job_id=$1
	output_file=$2
	attempt=0
	while [ "$attempt" -lt 15 ]; do
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

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 90 ]; do
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

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	printf 'error: run as root with sudo\n' >&2
	exit 77
fi

for required_file in "$slurm_conf" "$squeue" "$scontrol" "$sbatch" \
	"$scancel" "$sacct" "$pid_file" "$slurmd_log" /sbin/pfctl \
	"${source_dir}/smd010_completion_job.sh"; do
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
	"${source_dir}/smd010_completion_job.sh" \
	"${job_dir}/completion-job.sh" || exit 1
printf 'run_dir=%s\n' "$run_dir"
trap cleanup EXIT HUP INT TERM

actual_interface=$(/sbin/route -n get "$controller_addr" |
	/usr/bin/awk '/interface:/ { print $2; exit }')
actual_source=$(/usr/sbin/ipconfig getifaddr "$actual_interface" 2>/dev/null || true)
if [ "$actual_interface" != "$route_interface" ] || \
	[ "$actual_source" != "$source_addr" ]; then
	printf 'error: route changed interface=%s source=%s\n' \
		"$actual_interface" "$actual_source" >&2
	exit 75
fi

active_jobs=$("$squeue" -h -w "$node_name" -o '%i %T %u %j') || exit 1
if [ -n "$active_jobs" ]; then
	printf 'error: node has active jobs; PF test not started\n%s\n' \
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

/sbin/pfctl -s info >"${run_dir}/pf-info-before.txt" 2>&1 || exit 1
/sbin/pfctl -s References >"${run_dir}/pf-references-before.txt" 2>&1 || exit 1
if ! /usr/bin/grep -q 'Status: Disabled' "${run_dir}/pf-info-before.txt" || \
	! /usr/bin/grep -q 'No pf starter references held' \
		"${run_dir}/pf-references-before.txt"; then
	printf 'error: PF baseline differs from approved preflight; no change made\n' >&2
	exit 75
fi

/usr/bin/nc -vz -G 3 "$controller_addr" "$controller_port" \
	>"${run_dir}/baseline-nc.txt" 2>&1 || exit 1

/usr/bin/printf \
	'block drop out quick on %s inet proto tcp from %s to %s port %s label "SMD010-controller-6817"\n' \
	"$route_interface" "$source_addr" "$controller_addr" "$controller_port" \
	>"$rule_file" || exit 1
/sbin/pfctl -n -a "$test_anchor" -f "$rule_file" \
	>"${run_dir}/pf-syntax.txt" 2>&1 || exit 1

pf_enable_output=$(/sbin/pfctl -E 2>&1)
pf_enable_rc=$?
printf '%s\n' "$pf_enable_output" >"${run_dir}/pf-enable.txt"
if [ "$pf_enable_rc" -ne 0 ]; then
	printf 'error: failed to enable PF with reference token\n' >&2
	exit 1
fi
pf_enabled_by_test=1
pf_token=$(printf '%s\n' "$pf_enable_output" |
	/usr/bin/sed -n 's/.*Token : \([0-9][0-9]*\).*/\1/p' |
	/usr/bin/sed -n '1p')
if [ -z "$pf_token" ]; then
	/sbin/pfctl -d >"${run_dir}/pf-emergency-disable.txt" 2>&1 || true
	pf_enabled_by_test=0
	printf 'error: PF token was not returned; restored the preflight Disabled baseline\n' >&2
	exit 1
fi
printf 'pf_enabled token=%s\n' "$pf_token"

/sbin/pfctl -s info >"${run_dir}/pf-info-enabled.txt" 2>&1 || exit 1
/sbin/pfctl -s References >"${run_dir}/pf-references-enabled.txt" 2>&1 || exit 1
if ! /usr/bin/grep -q 'Status: Enabled' "${run_dir}/pf-info-enabled.txt" || \
	! /usr/bin/grep -q "$pf_token" "${run_dir}/pf-references-enabled.txt"; then
	printf 'error: PF enable state or token reference not visible\n' >&2
	exit 1
fi

/sbin/pfctl -a "$test_anchor" -sr \
	>"${run_dir}/pf-anchor-before.txt" 2>&1 || exit 1
if /usr/bin/grep -Eq '^(block|pass|match)[[:space:]]' \
	"${run_dir}/pf-anchor-before.txt"; then
	printf 'error: test anchor already contains rules\n' >&2
	exit 75
fi

# Idle phase: only TCP/6817 is blocked; slurmd must remain alive.
load_block idle || exit 1
/bin/sleep 5
if ! is_running "$slurmd_pid" || [ "$(/bin/cat "$pid_file")" != "$slurmd_pid" ]; then
	printf 'error: slurmd changed or stopped during idle outage\n' >&2
	exit 1
fi
unload_block idle || exit 1
"$scontrol" show node "$node_name" >"${run_dir}/node-after-idle.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-after-idle.txt"; then
	printf 'error: node did not remain IDLE after idle outage\n' >&2
	exit 1
fi
printf 'idle_phase=PASS slurmd_pid=%s\n' "$slurmd_pid"

# Job phase: the workload finishes while TCP/6817 is blocked.
submit_result=$(
	cd /tmp || exit 1
	/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
		SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
		--exclusive --mem=1G --time=00:02:00 --chdir=/tmp \
		--job-name=smd010-outage \
		--output="${job_dir}/completion.out" \
		--error="${job_dir}/completion.err" \
		"${job_dir}/completion-job.sh" "$job_dir"
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
if ! is_running "$batch_pid" || ! is_running "$child_pid"; then
	printf 'error: recorded job processes are not running\n' >&2
	exit 1
fi
printf 'target_ready job_id=%s batch_pid=%s child_pid=%s\n' \
	"$target_job" "$batch_pid" "$child_pid"

load_block job || exit 1
attempt=0
while [ ! -s "${job_dir}/complete.txt" ] && [ "$attempt" -lt 30 ]; do
	/bin/sleep 1
	attempt=$((attempt + 1))
done
if [ ! -s "${job_dir}/complete.txt" ]; then
	printf 'error: workload did not complete during controller outage\n' >&2
	exit 1
fi
printf 'workload_completed_while_blocked wait_seconds=%s\n' "$attempt"
/bin/sleep 5
if ! is_running "$slurmd_pid" || [ "$(/bin/cat "$pid_file")" != "$slurmd_pid" ]; then
	printf 'error: slurmd changed or stopped during job outage\n' >&2
	exit 1
fi
{
	/bin/ps -p "$batch_pid" -o user=,pid=,ppid=,pgid=,state=,command=
	/bin/ps -p "$child_pid" -o user=,pid=,ppid=,pgid=,state=,command=
} >"${run_dir}/job-processes-before-recovery.txt" 2>&1 || true
/sbin/pfctl -a "$test_anchor" -vvsr \
	>"${run_dir}/pf-counter-job-final.txt" 2>&1 || true

unload_block job || exit 1
wait_job_gone "$target_job" || exit 1
if ! wait_accounting_complete "$target_job" "${run_dir}/target-sacct.txt"; then
	printf 'error: target job did not converge to COMPLETED 0:0\n' >&2
	exit 1
fi
if is_running "$batch_pid" || is_running "$child_pid"; then
	printf 'error: target process remained after recovery\n' >&2
	exit 1
fi
printf 'job_phase=PASS job_id=%s\n' "$target_job"

submit_result=$(
	cd /tmp || exit 1
	/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
		SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=1G --gres=gpu:apple:1 --time=00:01:00 \
		--chdir=/tmp --job-name=smd010-post-smoke \
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
if ! /usr/bin/grep -Eq '^PC-210(\.local)?$' \
	"${smoke_dir}/hostname.out"; then
	printf 'error: post-recovery hostname output mismatch\n' >&2
	exit 1
fi
if ! wait_accounting_complete "$smoke_job" "${run_dir}/smoke-sacct.txt"; then
	printf 'error: post-recovery smoke job is not COMPLETED 0:0\n' >&2
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

clear_block || exit 1
/sbin/pfctl -a "$test_anchor" -sr \
	>"${run_dir}/pf-anchor-final-enabled.txt" 2>&1 || exit 1
release_pf_reference || exit 1
/sbin/pfctl -s info >"${run_dir}/pf-info-after.txt" 2>&1 || exit 1
/sbin/pfctl -s References >"${run_dir}/pf-references-after.txt" 2>&1 || exit 1
if ! /usr/bin/grep -q 'Status: Disabled' "${run_dir}/pf-info-after.txt" || \
	! /usr/bin/grep -q 'No pf starter references held' \
		"${run_dir}/pf-references-after.txt"; then
	printf 'error: PF did not return to disabled/no-reference baseline\n' >&2
	exit 1
fi
printf 'pf_restore=PASS status=Disabled references=none\n'

log_first=$((slurmd_log_start + 1))
/usr/bin/sed -n "${log_first},\$p" "$slurmd_log" \
	>"${run_dir}/slurmd-during-test.log"
/bin/ps -p "$slurmd_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/slurmd-after.txt" || exit 1

success=1
trap - EXIT HUP INT TERM
printf 'SMD010_ROOT_RUN_COMPLETE slurmd_pid=%s target_job=%s smoke_job=%s run_dir=%s\n' \
	"$slurmd_pid" "$target_job" "$smoke_job" "$run_dir"
