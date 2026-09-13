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
service_target=system/org.schedmd.slurmd
pid_file=/var/run/slurmd.pid
sack_socket=/var/run/slurm/sack.socket
node_name=PC-210
test_user=testuser
expected_ip=${SMD015_EXPECTED_IP:-192.168.10.128}
stable_wait_seconds=${SMD015_STABLE_WAIT_SECONDS:-2100}
marker=${prefix}/.smd015-idle-sleep.env
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd015-idle-${mode:-invalid}-${run_stamp}
active_job=
success=0

export SLURM_CONF="$slurm_conf"

usage()
{
	printf '%s\n' \
		"usage: $0 prepare" \
		"       $0 verify" >&2
	exit 64
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

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$active_job"
	if [ "$success" -ne 1 ]; then
		printf 'recovery: no power, daemon, launchd, or controller setting was changed; inspect run_dir=%s marker=%s\n' \
			"$run_dir" "$marker" >&2
	fi
	exit "$rc"
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

wait_accounting_complete()
{
	job_id=$1
	output_file=$2
	attempt=0
	while [ "$attempt" -lt 20 ]; do
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
	/bin/launchctl print "$service_target" >"${run_dir}/launchd-${prefix_name}.txt" 2>&1 || return 1
	/usr/bin/grep -q 'state = running' "${run_dir}/launchd-${prefix_name}.txt" || return 1
	"$scontrol" ping >"${run_dir}/controller-${prefix_name}.txt" 2>&1 || return 1
	"$scontrol" show node "$node_name" >"${run_dir}/node-${prefix_name}.txt" 2>&1 || return 1
	return 0
}

prepare_sleep()
{
	if [ "${SMD015_PHYSICAL_WAKE_CONFIRMED:-}" != YES ]; then
		printf '%s\n' \
			'error: this test disconnects remote sessions and requires physical wake access' \
			'confirm local physical access and rerun with SMD015_PHYSICAL_WAKE_CONFIRMED=YES' >&2
		exit 77
	fi
	if [ -e "$marker" ]; then
		printf 'error: existing marker must be inspected first: %s\n' "$marker" >&2
		exit 75
	fi

	capture_common_state before || {
		printf 'error: launchd/slurmd/controller preflight failed\n' >&2
		exit 75
	}
	active_jobs=$("$squeue" -h -w "$node_name" -o '%i %T %u %j') || exit 1
	if [ -n "$active_jobs" ]; then
		printf 'error: node has active jobs; sleep test not prepared\n%s\n' \
			"$active_jobs" >&2
		exit 75
	fi
	if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-before.txt" || \
		! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-before.txt" || \
		! /usr/bin/grep -q 'AllocTRES=$' "${run_dir}/node-before.txt"; then
		printf 'error: node is not idle and unallocated\n' >&2
		exit 75
	fi

	"$scontrol" show config >"${run_dir}/controller-config.txt" || exit 1
	slurmd_timeout=$(/usr/bin/awk '$1 == "SlurmdTimeout" { print $3; exit }' \
		"${run_dir}/controller-config.txt")
	return_to_service=$(/usr/bin/awk '$1 == "ReturnToService" { print $3; exit }' \
		"${run_dir}/controller-config.txt")
	case "$slurmd_timeout" in
	''|*[!0-9]*) printf 'error: invalid SlurmdTimeout=%s\n' "$slurmd_timeout" >&2; exit 1 ;;
	esac
	if [ "$slurmd_timeout" -lt 120 ]; then
		printf 'error: SlurmdTimeout=%s is too short for the controlled 60-second sleep test\n' \
			"$slurmd_timeout" >&2
		exit 75
	fi

	current_ip=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || true)
	[ "$current_ip" = "$expected_ip" ] || {
		printf 'error: en0 address changed expected=%s actual=%s\n' \
			"$expected_ip" "$current_ip" >&2
		exit 75
	}
	current_mac=$(/sbin/ifconfig en0 | /usr/bin/awk '/ether / { print $2; exit }')
	old_pid=$(get_service_pid)
	case "$old_pid" in
	''|*[!0-9]*) printf 'error: invalid launchd slurmd pid=%s\n' "$old_pid" >&2; exit 1 ;;
	esac
	/bin/kill -0 "$old_pid" >/dev/null 2>&1 || exit 1
	pid_file_value=$(/bin/cat "$pid_file")
	[ "$old_pid" = "$pid_file_value" ] || {
		printf 'error: launchd pid and pidfile differ launchd=%s pidfile=%s\n' \
			"$old_pid" "$pid_file_value" >&2
		exit 1
	}
	old_start=$(extract_start_time "${run_dir}/node-before.txt")
	[ -n "$old_start" ] && [ "$old_start" != None ] || exit 1
	old_boot=$(get_boot_epoch)
	old_sleep_count=$(get_sleep_count)
	case "$old_boot:$old_sleep_count" in
	*[!0-9:]*|:|*:) printf 'error: invalid boot/sleep counters\n' >&2; exit 1 ;;
	esac

	/usr/bin/pmset -g assertions >"${run_dir}/assertions-before.txt" || exit 1
	/usr/bin/pmset -g custom >"${run_dir}/pmset-custom.txt" || exit 1
	/usr/bin/pmset -g sched >"${run_dir}/pmset-sched.txt" || exit 1
	/usr/bin/pmset -g log >"${run_dir}/pmset-log-before.txt" || exit 1
	old_pm_log_lines=$(/usr/bin/wc -l <"${run_dir}/pmset-log-before.txt" | /usr/bin/tr -d ' ')
	/bin/ps -p "$old_pid" -o user=,pid=,ppid=,lstart=,command= \
		>"${run_dir}/slurmd-before.txt" || exit 1
	/usr/bin/stat -f 'sack=%N mode=%Sp owner=%Su group=%Sg device=%d inode=%i' \
		"$sack_socket" >"${run_dir}/sack-before.txt" || exit 1

	marker_tmp=${run_dir}/marker.env
	{
		printf 'old_boot=%s\n' "$old_boot"
		printf 'old_sleep_count=%s\n' "$old_sleep_count"
		printf 'old_pm_log_lines=%s\n' "$old_pm_log_lines"
		printf 'old_pid=%s\n' "$old_pid"
		printf 'old_start=%s\n' "$old_start"
		printf 'expected_ip=%s\n' "$expected_ip"
		printf 'current_mac=%s\n' "$current_mac"
		printf 'slurmd_timeout=%s\n' "$slurmd_timeout"
		printf 'return_to_service=%s\n' "$return_to_service"
		printf 'prepared_epoch=%s\n' "$(/bin/date '+%s')"
	} >"$marker_tmp"
	/usr/bin/install -o root -g wheel -m 0600 "$marker_tmp" "$marker" || exit 1

	if /usr/bin/grep -q 'screensharingd.*PreventSystemSleep' \
		"${run_dir}/assertions-before.txt"; then
		printf 'warning: Screen Sharing currently holds PreventSystemSleep; disconnect it before sleep\n' >&2
	fi
	success=1
	printf '%s\n' \
		"SMD015_IDLE_SLEEP_PREPARED pid=${old_pid} start=${old_start} sleep_count=${old_sleep_count} ip=${current_ip} mac=${current_mac} SlurmdTimeout=${slurmd_timeout} ReturnToService=${return_to_service} marker=${marker} run_dir=${run_dir}" \
		'NEXT_USER_ACTION_FROM_PHYSICAL_CONSOLE: disconnect Screen Sharing, run sudo /usr/bin/pmset sleepnow, wait at least 60 seconds, then wake the Mac physically' \
		"AFTER_WAKE: sudo /bin/sh ${source_root}/contribs/macos-tests/smd015_idle_sleep_wake.sh verify"
}

verify_sleep()
{
	[ -f "$marker" ] || {
		printf 'error: marker is missing: %s\n' "$marker" >&2
		exit 66
	}
	old_boot=$(read_marker old_boot)
	old_sleep_count=$(read_marker old_sleep_count)
	old_pm_log_lines=$(read_marker old_pm_log_lines)
	old_pid=$(read_marker old_pid)
	old_start=$(read_marker old_start)
	expected_ip=$(read_marker expected_ip)
	case "$old_boot:$old_sleep_count:$old_pm_log_lines:$old_pid" in
	*[!0-9:]*|:*|*::*|*:) printf 'error: invalid numeric marker state\n' >&2; exit 1 ;;
	esac
	[ -n "$old_start" ] && [ -n "$expected_ip" ] || {
		printf 'error: incomplete marker state\n' >&2
		exit 1
	}

	# Capture power evidence before the sleep-count gate so a blocked or skipped
	# sleep attempt remains diagnosable instead of leaving an empty run directory.
	/usr/bin/pmset -g assertions >"${run_dir}/assertions-after.txt" 2>&1 || true
	/usr/bin/pmset -g custom >"${run_dir}/pmset-custom-after.txt" 2>&1 || true
	/usr/bin/pmset -g sched >"${run_dir}/pmset-sched-after.txt" 2>&1 || true
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
		printf 'error: no completed sleep/wake cycle detected old=%s new=%s\n' \
			"$old_sleep_count" "$new_sleep_count" >&2
		if /usr/bin/grep -q 'screensharingd.*PreventSystemSleep' \
			"${run_dir}/assertions-after.txt"; then
			printf '%s\n' \
				'hint: Screen Sharing still holds PreventSystemSleep; disconnect it before running pmset sleepnow from the physical console' >&2
		fi
		exit 75
	fi
	new_boot=$(get_boot_epoch)
	new_pid=$(get_service_pid)
	case "$new_boot:$new_pid" in
	*[!0-9:]*|:|*:) printf 'error: invalid post-wake boot/PID state\n' >&2; exit 1 ;;
	esac
	if [ "$new_pid" != "$old_pid" ]; then
		printf 'error: slurmd PID changed; this was not an in-place sleep/wake old=%s new=%s\n' \
			"$old_pid" "$new_pid" >&2
		exit 1
	fi
	current_ip=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || true)
	[ "$current_ip" = "$expected_ip" ] || {
		printf 'error: address changed across sleep expected=%s actual=%s\n' \
			"$expected_ip" "$current_ip" >&2
		exit 75
	}

	case "$stable_wait_seconds" in
	''|*[!0-9]*|0) printf 'error: invalid SMD015_STABLE_WAIT_SECONDS=%s\n' \
		"$stable_wait_seconds" >&2; exit 64 ;;
	esac
	printf 'stable_idle_wait_limit_seconds=%s\n' "$stable_wait_seconds"
	attempt=0
	stable=0
	while [ "$attempt" -lt "$stable_wait_seconds" ]; do
		if capture_common_state after; then
			new_start=$(extract_start_time "${run_dir}/node-after.txt")
			if [ "$new_start" = "$old_start" ] && \
				/usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-after.txt"; then
				stable=$((stable + 1))
			else
				stable=0
			fi
		else
			stable=0
		fi
		[ "$stable" -ge 3 ] && break
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	if [ "$stable" -lt 3 ]; then
		printf 'error: controller/node did not return to stable IDLE after wake within %s seconds\n' \
			"$stable_wait_seconds" >&2
		exit 1
	fi

	/usr/bin/pmset -g assertions >"${run_dir}/assertions-after.txt" || exit 1
	/usr/bin/pmset -g log >"${run_dir}/pmset-log-after.txt" || exit 1
	start_line=$((old_pm_log_lines + 1))
	/usr/bin/sed -n "${start_line},\$p" "${run_dir}/pmset-log-after.txt" \
		>"${run_dir}/pmset-log-new.txt" || exit 1
	/bin/ps -p "$new_pid" -o user=,pid=,ppid=,lstart=,command= \
		>"${run_dir}/slurmd-after.txt" || exit 1

	smoke_dir=${run_dir}/smoke
	/bin/mkdir -m 0755 "$smoke_dir" || exit 1
	/usr/sbin/chown "$test_user" "$smoke_dir" || exit 1
	submit_result=$(
		cd /tmp || exit 1
		/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
			SLURM_CONF="$slurm_conf" \
			"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
			--cpus-per-task=1 --mem=1G --time=00:01:00 --chdir=/tmp \
			--job-name=smd015-idle-wake \
			--output="${smoke_dir}/hostname.out" \
			--error="${smoke_dir}/hostname.err" --wrap=/bin/hostname
	) || exit 1
	active_job=${submit_result%%;*}
	printf 'submitted smoke_job=%s\n' "$active_job"
	wait_job_gone "$active_job" || exit 1
	wait_accounting_complete "$active_job" "${smoke_dir}/sacct.txt" || exit 1
	/usr/bin/grep -Eq '^PC-210(\.local)?$' "${smoke_dir}/hostname.out" || exit 1
	completed_job=$active_job
	active_job=

	"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || exit 1
	"$squeue" -w "$node_name" >"${run_dir}/queue-final.txt" || exit 1
	if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-final.txt" || \
		! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-final.txt" || \
		! /usr/bin/grep -q 'AllocTRES=$' "${run_dir}/node-final.txt" || \
		[ -n "$("$squeue" -h -w "$node_name")" ]; then
		printf 'error: final node resources were not released\n' >&2
		exit 1
	fi

	completed_marker=${marker}.completed-${run_stamp}
	/bin/mv "$marker" "$completed_marker" || exit 1
	success=1
	printf '%s\n' \
		"SMD015_IDLE_SLEEP_COMPLETE old_sleep_count=${old_sleep_count} new_sleep_count=${new_sleep_count} old_boot=${old_boot} new_boot=${new_boot} pid=${new_pid} start=${old_start} ip=${current_ip} smoke_job=${completed_job} wait_seconds=${attempt} marker=${completed_marker} run_dir=${run_dir}"
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
	"$scancel" "$sacct" "$pid_file" "$sack_socket"; do
	[ -e "$required_file" ] || {
		printf 'error: missing %s\n' "$required_file" >&2
		exit 66
	}
done
for required_command in /bin/cat /bin/date /bin/kill /bin/launchctl \
	/bin/mkdir /bin/mv /bin/ps /bin/sleep /sbin/ifconfig \
	/usr/bin/awk /usr/bin/env /usr/bin/grep /usr/bin/id /usr/bin/install \
	/usr/bin/pmset /usr/bin/sed /usr/bin/stat /usr/bin/sudo /usr/bin/tr \
	/usr/bin/wc /usr/sbin/chown /usr/sbin/ipconfig /usr/sbin/sysctl; do
	[ -x "$required_command" ] || {
		printf 'error: required command is not executable: %s\n' \
			"$required_command" >&2
		exit 69
	}
done
/usr/bin/id "$test_user" >/dev/null 2>&1 || {
	printf 'error: test user %s does not exist\n' "$test_user" >&2
	exit 67
}

/bin/mkdir -m 0755 "$run_dir" || exit 1
printf 'mode=%s run_dir=%s marker=%s\n' "$mode" "$run_dir" "$marker"
trap cleanup EXIT HUP INT TERM

case "$mode" in
prepare) prepare_sleep ;;
verify) verify_sleep ;;
esac
