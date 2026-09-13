#!/bin/sh

set -u

mode=${1:-}
source_root=/Users/REDACTED_USER/dev/slurm.26-05
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
payload_source=${source_root}/contribs/macos-tests/smd015_job_sleep_payload.sh
service_target=system/org.schedmd.slurmd
pid_file=/var/run/slurmd.pid
node_name=PC-210
test_user=testuser
expected_ip=${SMD015_EXPECTED_IP:-192.168.10.128}
minimum_pause_seconds=${SMD015_MINIMUM_PAUSE_SECONDS:-30}
marker=${prefix}/.smd015-job-sleep.env
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd015-job-${mode:-invalid}-${run_stamp}
active_job=
finish_requested=0
preserve_job=0
success=0

export SLURM_CONF="$slurm_conf"

usage()
{
	printf '%s\n' \
		"usage: $0 prepare" \
		"       $0 verify" >&2
	exit 64
}

is_running()
{
	check_pid=$1
	[ -n "$check_pid" ] && /bin/kill -0 "$check_pid" >/dev/null 2>&1
}

get_service_pid()
{
	/bin/launchctl print "$service_target" 2>/dev/null | /usr/bin/awk '
		$1 == "pid" && $2 == "=" { print $3; exit }
	'
}

get_boot_epoch()
{
	/usr/sbin/sysctl -n kern.boottime | /usr/bin/awk -F '[=,]' '
	{
		value = $2
		gsub(/[^0-9]/, "", value)
		print value
		exit
	}'
}

get_sleep_count()
{
	/usr/bin/pmset -g log | /usr/bin/awk '
		/Total Sleep\/Wakes since boot/ {
			value = $NF
			gsub(/[^0-9]/, "", value)
			print value
			exit
		}
	'
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

read_marker()
{
	marker_key=$1
	/usr/bin/awk -F '=' -v key="$marker_key" '
		$1 == key {
			sub(/^[^=]*=/, "")
			print
			exit
		}
	' "$marker"
}

heartbeat_field()
{
	heartbeat_key=$1
	heartbeat_path=$2
	/usr/bin/awk -v key="$heartbeat_key" '
	{
		for (i = 1; i <= NF; i++) {
			split($i, item, "=")
			if (item[1] == key) {
				print item[2]
				exit
			}
		}
	}' "$heartbeat_path"
}

queue_state()
{
	"$squeue" -h -j "$1" -o '%T'
}

request_finish()
{
	[ -n "${job_dir:-}" ] || return 0
	printf 'finish\n' >"${job_dir}/finish-requested.txt" 2>/dev/null || return 1
	/usr/sbin/chown "$test_user" "${job_dir}/finish-requested.txt" \
		>/dev/null 2>&1 || return 1
	finish_requested=1
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
	if [ "$success" -ne 1 ] && [ "$preserve_job" -ne 1 ]; then
		if [ "$finish_requested" -ne 1 ]; then
			request_finish >/dev/null 2>&1 || true
		fi
		/bin/sleep 2
		cancel_if_active "$active_job"
	fi
	if [ "$success" -ne 1 ]; then
		printf 'recovery: inspect run_dir=%s marker=%s preserve_job=%s\n' \
			"$run_dir" "$marker" "$preserve_job" >&2
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
	while [ "$attempt" -lt 30 ]; do
		"$sacct" -j "$job_id" \
			--format=JobID,JobName,User,State,ReqTRES,AllocTRES,ExitCode,NodeList \
			-P >"$output_file" || return 1
		if /usr/bin/awk -F '|' -v id="$job_id" '
			$1 == id && $4 == "COMPLETED" && $7 == "0:0" { job_ok = 1 }
			$1 == id ".batch" && $4 == "COMPLETED" && $7 == "0:0" { batch_ok = 1 }
			END { exit !(job_ok && batch_ok) }
		' "$output_file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

capture_common_state()
{
	prefix_name=$1
	/bin/launchctl print "$service_target" \
		>"${run_dir}/launchd-${prefix_name}.txt" 2>&1 || return 1
	/usr/bin/grep -q 'state = running' \
		"${run_dir}/launchd-${prefix_name}.txt" || return 1
	"$scontrol" ping >"${run_dir}/controller-${prefix_name}.txt" 2>&1 || return 1
	"$scontrol" show node "$node_name" \
		>"${run_dir}/node-${prefix_name}.txt" 2>&1 || return 1
	"$squeue" -w "$node_name" >"${run_dir}/queue-${prefix_name}.txt" || return 1
	return 0
}

prepare_job_sleep()
{
	if [ "${SMD015_JOB_SLEEP_CONFIRMED:-}" != YES ]; then
		printf '%s\n' \
			'error: this test sleeps a Mac while a test job is running' \
			'confirm physical wake access and run with SMD015_JOB_SLEEP_CONFIRMED=YES' >&2
		exit 77
	fi
	if [ -e "$marker" ]; then
		printf 'error: existing marker must be inspected first: %s\n' "$marker" >&2
		exit 75
	fi

	phase_a_marker=
	for candidate in "${prefix}"/.smd015-idle-sleep.env.completed-*; do
		if [ -f "$candidate" ]; then
			phase_a_marker=$candidate
			break
		fi
	done
	if [ -z "$phase_a_marker" ]; then
		printf 'error: completed SMD-015 idle Phase A marker not found\n' >&2
		exit 75
	fi

	capture_common_state before || {
		printf 'error: launchd/slurmd/controller preflight failed\n' >&2
		exit 75
	}
	active_jobs=$("$squeue" -h -w "$node_name" -o '%i %T %u %j') || exit 1
	if [ -n "$active_jobs" ]; then
		printf 'error: node has active jobs; job sleep test not prepared\n%s\n' \
			"$active_jobs" >&2
		exit 75
	fi
	if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-before.txt" || \
		! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-before.txt" || \
		! /usr/bin/grep -q 'AllocTRES=$' "${run_dir}/node-before.txt"; then
		observed_state=$(/usr/bin/awk '
		{
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^State=/) {
					sub(/^State=/, "", $i)
					print $i
					exit
				}
			}
		}' "${run_dir}/node-before.txt")
		observed_reason=$(/usr/bin/sed -n 's/^[[:space:]]*Reason=//p' \
			"${run_dir}/node-before.txt")
		printf 'error: node is not idle and unallocated state=%s reason=%s\n' \
			"${observed_state:-unparsed}" "${observed_reason:-none}" >&2
		exit 75
	fi

	"$scontrol" show config >"${run_dir}/controller-config.txt" || exit 1
	slurmd_timeout=$(/usr/bin/awk '$1 == "SlurmdTimeout" { print $3; exit }' \
		"${run_dir}/controller-config.txt")
	case "$slurmd_timeout" in
	''|*[!0-9]*) printf 'error: invalid SlurmdTimeout=%s\n' "$slurmd_timeout" >&2; exit 1 ;;
	esac
	if [ "$slurmd_timeout" -lt 300 ]; then
		printf 'error: SlurmdTimeout=%s is below the required 300 seconds\n' \
			"$slurmd_timeout" >&2
		exit 75
	fi
	case "$minimum_pause_seconds" in
	''|*[!0-9]*|0) printf 'error: invalid minimum pause=%s\n' \
		"$minimum_pause_seconds" >&2; exit 64 ;;
	esac

	current_ip=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || true)
	if [ "$current_ip" != "$expected_ip" ]; then
		printf 'error: en0 address changed expected=%s actual=%s\n' \
			"$expected_ip" "$current_ip" >&2
		exit 75
	fi
	old_pid=$(get_service_pid)
	case "$old_pid" in
	''|*[!0-9]*) printf 'error: invalid launchd slurmd pid=%s\n' "$old_pid" >&2; exit 1 ;;
	esac
	if ! is_running "$old_pid" || [ "$(/bin/cat "$pid_file")" != "$old_pid" ]; then
		printf 'error: launchd slurmd and pidfile are not stable\n' >&2
		exit 1
	fi
	old_start=$(extract_start_time "${run_dir}/node-before.txt")
	old_boot=$(get_boot_epoch)
	old_sleep_count=$(get_sleep_count)
	case "$old_boot:$old_sleep_count" in
	*[!0-9:]*|:|*:) printf 'error: invalid boot/sleep counters\n' >&2; exit 1 ;;
	esac
	[ -n "$old_start" ] && [ "$old_start" != None ] || exit 1

	/usr/bin/pmset -g assertions >"${run_dir}/assertions-before.txt" 2>&1 || true
	/usr/bin/pmset -g log >"${run_dir}/pmset-log-before.txt" || exit 1
	old_pm_log_lines=$(/usr/bin/wc -l <"${run_dir}/pmset-log-before.txt" | \
		/usr/bin/tr -d ' ')
	/bin/ps -p "$old_pid" -o user=,pid=,ppid=,lstart=,command= \
		>"${run_dir}/slurmd-before.txt" || exit 1

	job_dir=${run_dir}/job
	/bin/mkdir -m 0755 "$job_dir" || exit 1
	/usr/sbin/chown "$test_user" "$job_dir" || exit 1
	/usr/bin/install -o "$test_user" -m 0755 "$payload_source" \
		"${job_dir}/job-sleep-payload.sh" || exit 1

	submit_result=$(
		cd /tmp || exit 1
		/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
			SLURM_CONF="$slurm_conf" \
			"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
			--cpus-per-task=1 --mem=1G --time=00:30:00 --chdir=/tmp \
			--job-name=smd015-job-sleep \
			--output="${job_dir}/job.out" \
			--error="${job_dir}/job.err" \
			"${job_dir}/job-sleep-payload.sh" "$job_dir"
	) || exit 1
	active_job=${submit_result%%;*}
	printf 'submitted target_job=%s\n' "$active_job"

	attempt=0
	while [ "$attempt" -lt 90 ]; do
		state=$(queue_state "$active_job") || exit 1
		if [ "$state" = RUNNING ] && [ -s "${job_dir}/ready.txt" ] && \
			[ -s "${job_dir}/heartbeat.txt" ]; then
			break
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	if [ "$state" != RUNNING ]; then
		printf 'error: target job did not become RUNNING state=%s\n' "$state" >&2
		exit 1
	fi

	batch_pid=$(/usr/bin/sed -n 's/^batch_pid=//p' "${job_dir}/ready.txt")
	child_pid=$(/usr/bin/sed -n 's/^child_pid=//p' "${job_dir}/ready.txt")
	/bin/sleep 2
	heartbeat_count=$(heartbeat_field count "${job_dir}/heartbeat.txt")
	heartbeat_epoch=$(heartbeat_field epoch "${job_dir}/heartbeat.txt")
	case "$batch_pid:$child_pid:$heartbeat_count:$heartbeat_epoch" in
	*[!0-9:]*|:*|*:) printf 'error: invalid job process or heartbeat data\n' >&2; exit 1 ;;
	esac
	if ! is_running "$batch_pid" || ! is_running "$child_pid"; then
		printf 'error: target process tree is not running\n' >&2
		exit 1
	fi

	"$scontrol" show node "$node_name" >"${run_dir}/node-allocated.txt" || exit 1
	if /usr/bin/grep -Eq 'State=(DOWN|DRAIN|UNKNOWN)' "${run_dir}/node-allocated.txt"; then
		printf 'error: node entered an invalid state after job allocation\n' >&2
		exit 1
	fi

	marker_tmp=${run_dir}/marker.env
	{
		printf 'old_boot=%s\n' "$old_boot"
		printf 'old_sleep_count=%s\n' "$old_sleep_count"
		printf 'old_pm_log_lines=%s\n' "$old_pm_log_lines"
		printf 'old_pid=%s\n' "$old_pid"
		printf 'old_start=%s\n' "$old_start"
		printf 'expected_ip=%s\n' "$expected_ip"
		printf 'slurmd_timeout=%s\n' "$slurmd_timeout"
		printf 'minimum_pause_seconds=%s\n' "$minimum_pause_seconds"
		printf 'job_id=%s\n' "$active_job"
		printf 'job_dir=%s\n' "$job_dir"
		printf 'batch_pid=%s\n' "$batch_pid"
		printf 'child_pid=%s\n' "$child_pid"
		printf 'heartbeat_count=%s\n' "$heartbeat_count"
		printf 'heartbeat_epoch=%s\n' "$heartbeat_epoch"
		printf 'phase_a_marker=%s\n' "$phase_a_marker"
	} >"$marker_tmp"
	/usr/bin/install -o root -g wheel -m 0600 "$marker_tmp" "$marker" || exit 1

	success=1
	printf '%s\n' \
		"SMD015_JOB_SLEEP_PREPARED job_id=${active_job} batch_pid=${batch_pid} child_pid=${child_pid} heartbeat=${heartbeat_count}@${heartbeat_epoch} slurmd_pid=${old_pid} sleep_count=${old_sleep_count} SlurmdTimeout=${slurmd_timeout} marker=${marker} run_dir=${run_dir}" \
		'NEXT_USER_ACTION_FROM_PHYSICAL_CONSOLE: disconnect Screen Sharing, run sudo /usr/bin/pmset sleepnow, wait 60 to 120 seconds, then wake the Mac physically' \
		"AFTER_WAKE: sudo /bin/sh ${source_root}/contribs/macos-tests/smd015_job_sleep_wake.sh verify"
}

verify_job_sleep()
{
	if [ ! -f "$marker" ]; then
		printf 'error: marker is missing: %s\n' "$marker" >&2
		exit 66
	fi
	old_boot=$(read_marker old_boot)
	old_sleep_count=$(read_marker old_sleep_count)
	old_pm_log_lines=$(read_marker old_pm_log_lines)
	old_pid=$(read_marker old_pid)
	old_start=$(read_marker old_start)
	expected_ip=$(read_marker expected_ip)
	slurmd_timeout=$(read_marker slurmd_timeout)
	minimum_pause_seconds=$(read_marker minimum_pause_seconds)
	active_job=$(read_marker job_id)
	job_dir=$(read_marker job_dir)
	batch_pid=$(read_marker batch_pid)
	child_pid=$(read_marker child_pid)
	heartbeat_count_before=$(read_marker heartbeat_count)
	heartbeat_epoch_before=$(read_marker heartbeat_epoch)
	case "$old_boot:$old_sleep_count:$old_pm_log_lines:$old_pid:$slurmd_timeout:$minimum_pause_seconds:$active_job:$batch_pid:$child_pid:$heartbeat_count_before:$heartbeat_epoch_before" in
	*[!0-9:]*|:*|*::*|*:)
		printf 'error: marker contains invalid numeric state\n' >&2
		exit 1
		;;
	esac
	if [ -z "$old_start" ] || [ -z "$expected_ip" ] || [ ! -d "$job_dir" ]; then
		printf 'error: marker contains incomplete path or identity state\n' >&2
		exit 1
	fi

	/usr/bin/pmset -g assertions >"${run_dir}/assertions-after.txt" 2>&1 || true
	/usr/bin/pmset -g log >"${run_dir}/pmset-log-after.txt" 2>&1 || true
	start_line=$((old_pm_log_lines + 1))
	/usr/bin/sed -n "${start_line},\$p" "${run_dir}/pmset-log-after.txt" \
		>"${run_dir}/pmset-log-new.txt" 2>/dev/null || true
	new_sleep_count=$(/usr/bin/awk '
		/Total Sleep\/Wakes since boot/ {
			value = $NF
			gsub(/[^0-9]/, "", value)
			print value
			exit
		}
	' "${run_dir}/pmset-log-after.txt")
	case "$new_sleep_count" in
	''|*[!0-9]*) printf 'error: invalid current sleep count\n' >&2; exit 1 ;;
	esac
	if [ "$new_sleep_count" -le "$old_sleep_count" ]; then
		state=$(queue_state "$active_job" 2>/dev/null || true)
		if [ "$state" = RUNNING ]; then
			preserve_job=1
		fi
		printf 'error: no completed sleep/wake cycle old=%s new=%s job_state=%s\n' \
			"$old_sleep_count" "$new_sleep_count" "${state:-gone}" >&2
		if /usr/bin/grep -q 'screensharingd.*PreventSystemSleep' \
			"${run_dir}/assertions-after.txt"; then
			printf 'hint: disconnect Screen Sharing before physical-console sleep\n' >&2
		fi
		exit 75
	fi

	new_boot=$(get_boot_epoch)
	new_pid=$(get_service_pid)
	current_ip=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || true)
	case "$new_boot:$new_pid" in
	*[!0-9:]*|:|*:) printf 'error: invalid post-wake boot or PID state\n' >&2; exit 1 ;;
	esac
	if [ "$new_boot" != "$old_boot" ] || [ "$new_pid" != "$old_pid" ]; then
		printf 'error: reboot or slurmd restart detected boot=%s->%s pid=%s->%s\n' \
			"$old_boot" "$new_boot" "$old_pid" "$new_pid" >&2
		exit 1
	fi
	if [ "$current_ip" != "$expected_ip" ]; then
		printf 'error: address changed expected=%s actual=%s\n' \
			"$expected_ip" "$current_ip" >&2
		exit 1
	fi

	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if capture_common_state after; then
			new_start=$(extract_start_time "${run_dir}/node-after.txt")
			state=$(queue_state "$active_job" 2>/dev/null || true)
			if [ "$new_start" = "$old_start" ] && [ "$state" = RUNNING ] && \
				/usr/bin/grep -Eq 'State=(MIXED|ALLOCATED)' \
				"${run_dir}/node-after.txt"; then
				break
			fi
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	if [ "$attempt" -ge 60 ]; then
		printf 'error: job/controller did not return to running state after wake\n' >&2
		exit 1
	fi

	attempt=0
	while [ "$attempt" -lt 30 ]; do
		heartbeat_count_after=$(heartbeat_field count "${job_dir}/heartbeat.txt")
		heartbeat_epoch_after=$(heartbeat_field epoch "${job_dir}/heartbeat.txt")
		case "$heartbeat_count_after:$heartbeat_epoch_after" in
		*[!0-9:]*|:|*:) ;;
		*)
			if [ "$heartbeat_count_after" -gt "$heartbeat_count_before" ]; then
				break
			fi
			;;
		esac
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	if [ "$attempt" -ge 30 ]; then
		printf 'error: job heartbeat did not advance after wake\n' >&2
		exit 1
	fi
	if ! is_running "$batch_pid" || ! is_running "$child_pid"; then
		printf 'error: original job process tree did not survive sleep\n' >&2
		exit 1
	fi

	wall_delta=$((heartbeat_epoch_after - heartbeat_epoch_before))
	count_delta=$((heartbeat_count_after - heartbeat_count_before))
	pause_estimate=$((wall_delta - count_delta))
	printf 'survivor_after_wake job_id=%s state=%s heartbeat=%s@%s->%s@%s pause_estimate_seconds=%s\n' \
		"$active_job" "$state" "$heartbeat_count_before" "$heartbeat_epoch_before" \
		"$heartbeat_count_after" "$heartbeat_epoch_after" "$pause_estimate"
	if [ "$pause_estimate" -lt "$minimum_pause_seconds" ]; then
		printf 'error: measured execution pause is below minimum expected=%s actual=%s\n' \
			"$minimum_pause_seconds" "$pause_estimate" >&2
		exit 1
	fi
	if [ "$pause_estimate" -ge "$slurmd_timeout" ]; then
		printf 'error: sleep exceeded SlurmdTimeout=%s pause_estimate=%s; this is not the short-sleep case\n' \
			"$slurmd_timeout" "$pause_estimate" >&2
		exit 75
	fi

	request_finish || exit 1
	wait_job_gone "$active_job" || exit 1
	if ! wait_accounting_complete "$active_job" "${run_dir}/target-sacct.txt"; then
		printf 'error: target job did not converge to COMPLETED 0:0\n' >&2
		exit 1
	fi
	if ! /usr/bin/grep -q 'finish_seen ' "${job_dir}/job.out" || \
		! /usr/bin/grep -q 'payload_complete .* rc=0 ' "${job_dir}/job.out"; then
		printf 'error: workload did not record a clean finish\n' >&2
		exit 1
	fi

	attempt=0
	while [ "$attempt" -lt 30 ]; do
		if ! is_running "$batch_pid" && ! is_running "$child_pid"; then
			break
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	if is_running "$batch_pid" || is_running "$child_pid"; then
		printf 'error: residual workload process detected\n' >&2
		exit 1
	fi

	attempt=0
	while [ "$attempt" -lt 60 ]; do
		"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || exit 1
		if /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-final.txt" && \
			/usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-final.txt" && \
			/usr/bin/grep -q 'AllocTRES=$' "${run_dir}/node-final.txt"; then
			break
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	"$squeue" -w "$node_name" >"${run_dir}/queue-final.txt" || exit 1
	if [ "$attempt" -ge 60 ] || [ -n "$("$squeue" -h -w "$node_name")" ]; then
		printf 'error: node resources or queue did not return to idle\n' >&2
		exit 1
	fi
	/bin/ps -p "$new_pid" -o user=,pid=,ppid=,lstart=,command= \
		>"${run_dir}/slurmd-after.txt" || exit 1

	completed_marker=${marker}.completed-${run_stamp}
	/bin/mv "$marker" "$completed_marker" || exit 1
	completed_job=$active_job
	active_job=
	success=1
	printf 'SMD015_JOB_SLEEP_COMPLETE job_id=%s sleep_count=%s->%s boot=%s pid=%s start=%s pause_estimate_seconds=%s marker=%s run_dir=%s\n' \
		"$completed_job" "$old_sleep_count" "$new_sleep_count" "$new_boot" \
		"$new_pid" "$old_start" "$pause_estimate" "$completed_marker" "$run_dir"
}

case "$mode" in
prepare|verify) ;;
*) usage ;;
esac

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	printf 'error: run as root with sudo\n' >&2
	exit 77
fi

for required_file in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" \
	"$scancel" "$sacct" "$payload_source" "$pid_file"; do
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
printf 'mode=%s run_dir=%s marker=%s\n' "$mode" "$run_dir" "$marker"
trap cleanup EXIT HUP INT TERM

case "$mode" in
prepare) prepare_job_sleep ;;
verify) verify_job_sleep ;;
esac
