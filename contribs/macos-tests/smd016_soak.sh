#!/bin/sh

set -u

mode=${1:-}
source_root=/Users/REDACTED_USER/dev/slurm.26-05
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
service_target=system/org.schedmd.slurmd
pid_file=/var/run/slurmd.pid
slurmd_log=/var/log/slurm/slurmd.log
marker=${prefix}/.smd016-soak.env
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
payload=${source_root}/contribs/macos-tests/smd016_soak_payload.sh
script_path=${source_root}/contribs/macos-tests/smd016_soak.sh
node_name=PC-210
test_user=testuser
duration_seconds=${SMD016_DURATION_SECONDS:-86400}
interval_seconds=${SMD016_INTERVAL_SECONDS:-300}
rss_limit_kb=${SMD016_RSS_GROWTH_LIMIT_KB:-16384}
fd_final_limit=${SMD016_FD_FINAL_GROWTH_LIMIT:-2}
fd_peak_limit=${SMD016_FD_PEAK_GROWTH_LIMIT:-8}

export SLURM_CONF="$slurm_conf"

usage()
{
	printf '%s\n' \
		"usage: $0 start" \
		"       $0 status" \
		"       $0 verify" \
		"       $0 stop" >&2
	exit 64
}

require_root()
{
	if [ "$(/usr/bin/id -u)" -ne 0 ]; then
		printf 'error: run as root with sudo\n' >&2
		exit 77
	fi
}

is_uint()
{
	case "$1" in
	''|*[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
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

service_pid()
{
	/bin/launchctl print "$service_target" 2>/dev/null | /usr/bin/awk '
		$1 == "pid" && $2 == "=" { print $3; exit }
	'
}

service_state()
{
	/bin/launchctl print "$service_target" 2>/dev/null | /usr/bin/awk '
		$1 == "state" && $2 == "=" { print $3; exit }
	'
}

boot_epoch()
{
	/usr/sbin/sysctl -n kern.boottime | /usr/bin/awk -F '[=,]' '
	{
		value = $2
		gsub(/[^0-9]/, "", value)
		print value
		exit
	}'
}

node_field()
{
	field=$1
	file=$2
	/usr/bin/awk -v key="${field}=" '
	{
		for (i = 1; i <= NF; i++) {
			if (index($i, key) == 1) {
				sub(key, "", $i)
				print $i
				exit
			}
		}
	}' "$file"
}

controller_up()
{
	"$scontrol" ping 2>/dev/null | /usr/bin/grep -q ' is UP$'
}

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null | /usr/bin/awk 'NR == 1 { print; exit }'
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		if [ -z "$(queue_state "$job_id")" ]; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_accounting()
{
	job_id=$1
	output_file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		"$sacct" -j "$job_id" -n -P \
			--format=JobIDRaw,State,ExitCode >"$output_file" 2>/dev/null || true
		if /usr/bin/awk -F '|' -v job="$job_id" '
			$1 == job && $2 == "COMPLETED" && $3 == "0:0" { root_ok = 1 }
			$1 == job ".batch" && $2 == "COMPLETED" && $3 == "0:0" { batch_ok = 1 }
			END { exit !(root_ok && batch_ok) }
		' "$output_file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

capture_sample()
{
	phase=$1
	sequence=$2
	epoch=$(/bin/date '+%s')
	pid=$(service_pid)
	case "$pid" in
	''|*[!0-9]*) return 1 ;;
	esac
	node_file=${run_dir}/node-current.txt
	"$scontrol" show node "$node_name" >"$node_file" 2>/dev/null || return 1
	state=$(node_field State "$node_file")
	cpu_alloc=$(node_field CPUAlloc "$node_file")
	alloc_mem=$(node_field AllocMem "$node_file")
	rss_kb=$(/bin/ps -o rss= -p "$pid" 2>/dev/null | /usr/bin/awk 'NR == 1 { gsub(/ /, ""); print }')
	fd_count=$(/usr/sbin/lsof -a -p "$pid" -d 0-999999 -Ff 2>/dev/null | \
		/usr/bin/awk '/^f[0-9]+$/ { count++ } END { print count + 0 }')
	thread_count=$(/bin/ps -M -p "$pid" -o pid= 2>/dev/null | /usr/bin/awk 'END { print NR + 0 }')
	queue_count=$("$squeue" -h -w "$node_name" 2>/dev/null | /usr/bin/awk 'END { print NR + 0 }')
	for value in "$rss_kb" "$fd_count" "$thread_count" "$cpu_alloc" "$alloc_mem" "$queue_count"; do
		is_uint "$value" || return 1
	done
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$epoch" "$phase" "$sequence" "$pid" "$rss_kb" "$fd_count" \
		"$thread_count" "$state" "$cpu_alloc" "$alloc_mem" "$queue_count" \
		>>"${run_dir}/samples.tsv"
	return 0
}

write_result()
{
	result=$1
	reason=$2
	end_epoch=$(/bin/date '+%s')
	elapsed=$((end_epoch - start_epoch))
	{
		printf 'result=%s\n' "$result"
		printf 'reason=%s\n' "$reason"
		printf 'start_epoch=%s\n' "$start_epoch"
		printf 'end_epoch=%s\n' "$end_epoch"
		printf 'elapsed_seconds=%s\n' "$elapsed"
		printf 'successful_jobs=%s\n' "$successful_jobs"
		printf 'failed_jobs=%s\n' "$failed_jobs"
		printf 'last_sequence=%s\n' "$sequence"
	} >"${run_dir}/result.env"
}

run_soak()
{
	run_dir=${2:-}
	[ -d "$run_dir" ] || exit 66
	/bin/pwd >"${run_dir}/runner-cwd-inherited.txt" 2>&1 || true
	cd /tmp || {
		printf 'error: runner could not change directory to /tmp\n' >&2
		exit 1
	}
	/bin/pwd >"${run_dir}/runner-cwd-effective.txt" 2>&1 || true
	start_epoch=$(read_marker start_epoch)
	old_pid=$(read_marker old_pid)
	duration_seconds=$(read_marker duration_seconds)
	interval_seconds=$(read_marker interval_seconds)
	payload=$(read_marker payload_path)
	for value in "$start_epoch" "$old_pid" "$duration_seconds" "$interval_seconds"; do
		is_uint "$value" || exit 65
	done
	[ -f "$payload" ] && [ -r "$payload" ] || exit 66
	printf '%s\n' "$$" >"${run_dir}/runner.pid"
	printf 'epoch\tphase\tsequence\tslurmd_pid\trss_kb\tfd_count\tthread_count\tnode_state\tcpu_alloc\talloc_mem\tqueue_count\n' \
		>"${run_dir}/samples.tsv"
	sequence=0
	successful_jobs=0
	failed_jobs=0
	failure_reason=
	target_epoch=$((start_epoch + duration_seconds))
	printf 'state=RUNNING sequence=0 successful_jobs=0 epoch=%s\n' "$start_epoch" \
		>"${run_dir}/progress.txt"

	while [ "$(/bin/date '+%s')" -lt "$target_epoch" ]; do
		if [ -f "${run_dir}/stop-requested" ]; then
			write_result STOPPED user_requested
			exit 75
		fi
		sequence=$((sequence + 1))
		if ! controller_up; then
			failure_reason=controller_ping_failed
			break
		fi
		if ! capture_sample before "$sequence"; then
			failure_reason=sample_before_failed
			break
		fi
		current_pid=$(service_pid)
		if [ "$current_pid" != "$old_pid" ]; then
			failure_reason=slurmd_pid_changed
			break
		fi
		state=$(node_field State "${run_dir}/node-current.txt")
		if [ "$state" != IDLE ]; then
			failure_reason="unexpected_node_state_${state}"
			break
		fi
		if [ -n "$("$squeue" -h -w "$node_name" 2>/dev/null)" ]; then
			failure_reason=external_job_interference
			break
		fi

		job_dir=${run_dir}/jobs/$(/usr/bin/printf '%04d' "$sequence")
		/bin/mkdir -m 0755 "$job_dir" || {
			failure_reason=job_dir_create_failed
			break
		}
		/usr/sbin/chown "$test_user" "$job_dir" || {
			failure_reason=job_dir_chown_failed
			break
		}
		submit_out=$(/usr/bin/sudo -u "$test_user" -H /usr/bin/env \
			SLURM_CONF="$slurm_conf" "$sbatch" --parsable \
			--partition=debug --nodes=1 --ntasks=1 --cpus-per-task=1 \
			--mem=128M --time=00:01:00 --chdir=/tmp \
			--job-name=smd016-soak \
			--output="${job_dir}/job.out" --error="${job_dir}/job.err" \
			"$payload" "$sequence" 2>"${job_dir}/submit.err") || {
			failure_reason=sbatch_failed
			failed_jobs=$((failed_jobs + 1))
			break
		}
		job_id=${submit_out%%;*}
		case "$job_id" in
		''|*[!0-9]*)
			failure_reason=invalid_job_id
			failed_jobs=$((failed_jobs + 1))
			break
			;;
		esac
		printf '%s\n' "$job_id" >"${run_dir}/active-job.txt"
		printf '%s\t%s\t%s\n' "$sequence" "$job_id" "$(/bin/date '+%s')" \
			>>"${run_dir}/jobs.tsv"
		if ! wait_job_gone "$job_id"; then
			failure_reason=job_did_not_finish
			failed_jobs=$((failed_jobs + 1))
			"$scancel" "$job_id" >/dev/null 2>&1 || true
			break
		fi
		if ! wait_accounting "$job_id" "${job_dir}/sacct.txt"; then
			failure_reason=accounting_not_completed_0_0
			failed_jobs=$((failed_jobs + 1))
			break
		fi
		successful_jobs=$((successful_jobs + 1))
		: >"${run_dir}/active-job.txt"
		if ! capture_sample after "$sequence"; then
			failure_reason=sample_after_failed
			break
		fi
		state=$(node_field State "${run_dir}/node-current.txt")
		cpu_alloc=$(node_field CPUAlloc "${run_dir}/node-current.txt")
		alloc_mem=$(node_field AllocMem "${run_dir}/node-current.txt")
		if [ "$state" != IDLE ] || [ "$cpu_alloc" != 0 ] || [ "$alloc_mem" != 0 ]; then
			failure_reason=resource_cleanup_failed
			break
		fi
		printf 'state=RUNNING sequence=%s successful_jobs=%s last_job=%s epoch=%s\n' \
			"$sequence" "$successful_jobs" "$job_id" "$(/bin/date '+%s')" \
			>"${run_dir}/progress.txt"

		next_epoch=$((start_epoch + sequence * interval_seconds))
		while [ "$(/bin/date '+%s')" -lt "$next_epoch" ]; do
			if [ -f "${run_dir}/stop-requested" ]; then
				write_result STOPPED user_requested
				exit 75
			fi
			/bin/sleep 1
		done
	done

	if [ -n "$failure_reason" ]; then
		write_result FAILED "$failure_reason"
		printf 'state=FAILED reason=%s sequence=%s successful_jobs=%s epoch=%s\n' \
			"$failure_reason" "$sequence" "$successful_jobs" "$(/bin/date '+%s')" \
			>"${run_dir}/progress.txt"
		exit 1
	fi
	if ! capture_sample final "$sequence"; then
		write_result FAILED final_sample_failed
		exit 1
	fi
	start_log_line=$(read_marker start_log_line)
	/usr/bin/tail -n "+${start_log_line}" "$slurmd_log" >"${run_dir}/slurmd-new.log" 2>/dev/null || true
	/usr/bin/grep -Eic \
		'fatal:|pthread_mutex|Protocol not available|Unable to register|not responding|segmentation|abort' \
		"${run_dir}/slurmd-new.log" >"${run_dir}/slurmd-error-count.txt" || true
	write_result COMPLETE none
	printf 'state=COMPLETE sequence=%s successful_jobs=%s epoch=%s\n' \
		"$sequence" "$successful_jobs" "$(/bin/date '+%s')" >"${run_dir}/progress.txt"
}

start_test()
{
	if [ "${SMD016_24H_CONFIRMED:-NO}" != YES ]; then
		printf 'error: set SMD016_24H_CONFIRMED=YES after accepting the 24-hour test load\n' >&2
		exit 64
	fi
	for value in "$duration_seconds" "$interval_seconds" "$rss_limit_kb" \
		"$fd_final_limit" "$fd_peak_limit"; do
		is_uint "$value" || {
			printf 'error: invalid numeric test parameter\n' >&2
			exit 64
		}
	done
	if [ "$duration_seconds" -lt 86400 ]; then
		printf 'error: official SMD-016 requires at least 86400 seconds\n' >&2
		exit 64
	fi
	if [ "$interval_seconds" -lt 30 ] || [ "$interval_seconds" -gt 3600 ]; then
		printf 'error: interval must be between 30 and 3600 seconds\n' >&2
		exit 64
	fi
	if [ -e "$marker" ]; then
		printf 'error: active SMD-016 marker already exists: %s\n' "$marker" >&2
		exit 73
	fi
	for required in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" "$scancel" \
		"$sacct" "$payload" "$pid_file" "$slurmd_log" /usr/bin/caffeinate; do
		[ -e "$required" ] || {
			printf 'error: missing required path: %s\n' "$required" >&2
			exit 66
		}
	done
	controller_up || {
		printf 'error: controller is not UP\n' >&2
		exit 1
	}
	run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
	run_dir=/tmp/slurm-smd016-${run_stamp}
	/bin/mkdir -m 0755 "$run_dir" || exit 1
	/bin/mkdir -m 0755 "${run_dir}/jobs" || exit 1
	runtime_payload=${run_dir}/smd016_soak_payload.sh
	/usr/bin/install -o root -g wheel -m 0755 "$payload" "$runtime_payload" || exit 1
	"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || exit 1
	"$squeue" -w "$node_name" >"${run_dir}/queue-before.txt" || exit 1
	state=$(node_field State "${run_dir}/node-before.txt")
	cpu_alloc=$(node_field CPUAlloc "${run_dir}/node-before.txt")
	alloc_mem=$(node_field AllocMem "${run_dir}/node-before.txt")
	if [ "$state" != IDLE ] || [ "$cpu_alloc" != 0 ] || [ "$alloc_mem" != 0 ] || \
		[ -n "$("$squeue" -h -w "$node_name")" ]; then
		printf 'error: node is not idle and unallocated state=%s cpu=%s mem=%s\n' \
			"$state" "$cpu_alloc" "$alloc_mem" >&2
		exit 1
	fi
	/bin/launchctl print "$service_target" >"${run_dir}/launchd-before.txt" 2>&1 || {
		printf 'error: launchd service is not loaded: %s\n' "$service_target" >&2
		exit 1
	}
	old_pid=$(service_pid)
	launchd_state=$(service_state)
	pidfile_pid=$(/bin/cat "$pid_file")
	/usr/bin/od -An -tx1c "$pid_file" >"${run_dir}/pidfile-od.txt" 2>&1 || true
	case "$old_pid:$pidfile_pid" in
	*[!0-9:]*) printf 'error: invalid slurmd PID identity\n' >&2; exit 1 ;;
	esac
	if [ "$launchd_state" != running ]; then
		printf 'error: launchd service is not running state=%s pid=%s pidfile=%s\n' \
			"${launchd_state:-missing}" "${old_pid:-missing}" "${pidfile_pid:-missing}" >&2
		exit 1
	fi
	if [ "$old_pid" != "$pidfile_pid" ]; then
		printf 'error: launchd and pidfile PID differ launchd_pid=%s pidfile_pid=%s\n' \
			"$old_pid" "$pidfile_pid" >&2
		exit 1
	fi
	ps_command=$(/bin/ps -p "$old_pid" -o command= 2>/dev/null || true)
	printf '%s\n' "$ps_command" >"${run_dir}/slurmd-command-before.txt"
	case "$ps_command" in
	"${prefix}/sbin/slurmd "*) ;;
	*)
		printf 'error: launchd PID does not identify production slurmd pid=%s command=%s\n' \
			"$old_pid" "${ps_command:-missing}" >&2
		exit 1
		;;
	esac
	printf 'launchd_state=%s launchd_pid=%s pidfile_pid=%s identity=PASS\n' \
		"$launchd_state" "$old_pid" "$pidfile_pid" >"${run_dir}/slurmd-identity-before.txt"
	if ! /usr/bin/id "$test_user" >/dev/null 2>&1; then
		printf 'error: test user is missing: %s\n' "$test_user" >&2
		exit 67
	fi
	rss_probe=$(/bin/ps -o rss= -p "$old_pid" 2>/dev/null | /usr/bin/awk 'NR == 1 { gsub(/ /, ""); print }')
	fd_probe=$(/usr/sbin/lsof -a -p "$old_pid" -d 0-999999 -Ff 2>/dev/null | \
		/usr/bin/awk '/^f[0-9]+$/ { count++ } END { print count + 0 }')
	thread_probe=$(/bin/ps -M -p "$old_pid" -o pid= 2>/dev/null | /usr/bin/awk 'END { print NR + 0 }')
	for value in "$rss_probe" "$fd_probe" "$thread_probe"; do
		is_uint "$value" || {
			printf 'error: unable to measure slurmd process metrics\n' >&2
			exit 1
		}
	done
	if [ "$rss_probe" -eq 0 ] || [ "$fd_probe" -eq 0 ] || [ "$thread_probe" -eq 0 ]; then
		printf 'error: invalid zero slurmd metric rss=%s fd=%s threads=%s\n' \
			"$rss_probe" "$fd_probe" "$thread_probe" >&2
		exit 1
	fi
	printf 'rss_kb=%s\nfd_count=%s\nthread_count=%s\n' \
		"$rss_probe" "$fd_probe" "$thread_probe" >"${run_dir}/metrics-before.env"
	old_boot=$(boot_epoch)
	old_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")
	start_epoch=$(/bin/date '+%s')
	start_log_line=$(( $(/usr/bin/wc -l <"$slurmd_log") + 1 ))
	marker_tmp=${run_dir}/marker.env
	{
		printf 'run_dir=%s\n' "$run_dir"
		printf 'start_epoch=%s\n' "$start_epoch"
		printf 'duration_seconds=%s\n' "$duration_seconds"
		printf 'interval_seconds=%s\n' "$interval_seconds"
		printf 'payload_path=%s\n' "$runtime_payload"
		printf 'old_pid=%s\n' "$old_pid"
		printf 'old_boot=%s\n' "$old_boot"
		printf 'old_start=%s\n' "$old_start"
		printf 'start_log_line=%s\n' "$start_log_line"
		printf 'rss_limit_kb=%s\n' "$rss_limit_kb"
		printf 'fd_final_limit=%s\n' "$fd_final_limit"
		printf 'fd_peak_limit=%s\n' "$fd_peak_limit"
	} >"$marker_tmp"
	/usr/bin/install -o root -g wheel -m 0600 "$marker_tmp" "$marker" || exit 1
	cd /tmp || {
		printf 'error: could not change background launch directory to /tmp\n' >&2
		exit 1
	}
	/usr/bin/nohup /usr/bin/caffeinate -ims /bin/sh "$script_path" _run "$run_dir" \
		</dev/null >"${run_dir}/runner.log" 2>&1 &
	supervisor_pid=$!
	printf 'supervisor_pid=%s\n' "$supervisor_pid" >>"$marker"
	attempt=0
	while [ "$attempt" -lt 10 ] && [ ! -s "${run_dir}/runner.pid" ]; do
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	if [ ! -s "${run_dir}/runner.pid" ] || ! /bin/kill -0 "$supervisor_pid" 2>/dev/null; then
		failed_marker=${marker}.failed-${run_stamp}
		if [ -f "${run_dir}/result.env" ]; then
			result=$(/usr/bin/awk -F '=' '$1 == "result" { print $2 }' "${run_dir}/result.env")
			reason=$(/usr/bin/awk -F '=' '$1 == "reason" { print $2 }' "${run_dir}/result.env")
			printf 'error: soak runner exited early result=%s reason=%s run_dir=%s\n' \
				"${result:-unknown}" "${reason:-unknown}" "$run_dir" >&2
		else
			printf 'error: soak runner failed to start; inspect %s\n' "$run_dir" >&2
		fi
		/bin/mv "$marker" "$failed_marker" 2>/dev/null || true
		printf 'failed_marker=%s\n' "$failed_marker" >&2
		exit 1
	fi
	runner_pid=$(/bin/cat "${run_dir}/runner.pid")
	first_successful_jobs=0
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ -f "${run_dir}/progress.txt" ]; then
			first_successful_jobs=$(/usr/bin/awk '
			{
				for (i = 1; i <= NF; i++) {
					if ($i ~ /^successful_jobs=/) {
						sub(/^successful_jobs=/, "", $i)
						print $i
						exit
					}
				}
			}' "${run_dir}/progress.txt")
		fi
		case "$first_successful_jobs" in
		''|*[!0-9]*) first_successful_jobs=0 ;;
		esac
		if [ "$first_successful_jobs" -ge 1 ]; then
			break
		fi
		if [ -f "${run_dir}/result.env" ] || \
			! /bin/kill -0 "$supervisor_pid" 2>/dev/null; then
			break
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	if [ "$first_successful_jobs" -lt 1 ]; then
		failed_marker=${marker}.failed-${run_stamp}
		if [ -f "${run_dir}/result.env" ]; then
			result=$(/usr/bin/awk -F '=' '$1 == "result" { print $2 }' "${run_dir}/result.env")
			reason=$(/usr/bin/awk -F '=' '$1 == "reason" { print $2 }' "${run_dir}/result.env")
			printf 'error: first soak job failed result=%s reason=%s run_dir=%s\n' \
				"${result:-unknown}" "${reason:-unknown}" "$run_dir" >&2
		else
			printf 'error: first soak job did not complete within 180 seconds run_dir=%s\n' \
				"$run_dir" >&2
			: >"${run_dir}/stop-requested"
		fi
		if [ -f "${run_dir}/jobs/0001/submit.err" ]; then
			printf '%s\n' '[first job submit stderr]' >&2
			/usr/bin/sed -n '1,40p' "${run_dir}/jobs/0001/submit.err" >&2
		fi
		if [ -f "${run_dir}/result.env" ] || \
			! /bin/kill -0 "$supervisor_pid" 2>/dev/null; then
			/bin/mv "$marker" "$failed_marker" 2>/dev/null || true
			printf 'failed_marker=%s\n' "$failed_marker" >&2
		else
			printf 'active_marker_preserved=%s; use status or stop\n' "$marker" >&2
		fi
		exit 1
	fi
	first_job_id=$(/usr/bin/awk -F '\t' 'NR == 1 { print $2 }' "${run_dir}/jobs.tsv")
	/usr/bin/pmset -g assertions >"${run_dir}/assertions-after-start.txt" 2>&1 || true
	printf 'SMD016_STARTED first_job=%s first_successful_jobs=%s duration_seconds=%s interval_seconds=%s expected_jobs_about=%s slurmd_pid=%s supervisor_pid=%s runner_pid=%s marker=%s run_dir=%s\n' \
		"$first_job_id" "$first_successful_jobs" \
		"$duration_seconds" "$interval_seconds" "$((duration_seconds / interval_seconds))" \
		"$old_pid" "$supervisor_pid" "$runner_pid" "$marker" "$run_dir"
	printf 'STATUS: sudo /bin/sh %s status\n' "$script_path"
	printf 'VERIFY_AFTER_24H: sudo /bin/sh %s verify\n' "$script_path"
}

status_test()
{
	[ -f "$marker" ] || {
		printf 'error: no active SMD-016 marker\n' >&2
		exit 66
	}
	run_dir=$(read_marker run_dir)
	printf 'marker=%s run_dir=%s\n' "$marker" "$run_dir"
	[ -f "${run_dir}/progress.txt" ] && /bin/cat "${run_dir}/progress.txt"
	[ -f "${run_dir}/result.env" ] && /bin/cat "${run_dir}/result.env"
	[ -f "${run_dir}/runner.pid" ] && {
		runner_pid=$(/bin/cat "${run_dir}/runner.pid")
		if /bin/kill -0 "$runner_pid" 2>/dev/null; then
			printf 'runner_alive=YES pid=%s\n' "$runner_pid"
		else
			printf 'runner_alive=NO pid=%s\n' "$runner_pid"
		fi
	}
	/usr/bin/tail -n 20 "${run_dir}/runner.log" 2>/dev/null || true
}

analyse_samples()
{
	sample_file=$1
	/usr/bin/awk -F '\t' '
		NR == 1 { next }
		{
			n++
			rss[n] = $5
			fd[n] = $6
			thr[n] = $7
			if (n == 1 || $5 < rss_min) rss_min = $5
			if (n == 1 || $5 > rss_max) rss_max = $5
			if (n == 1 || $6 < fd_min) fd_min = $6
			if (n == 1 || $6 > fd_max) fd_max = $6
			if (n == 1 || $7 < thr_min) thr_min = $7
			if (n == 1 || $7 > thr_max) thr_max = $7
		}
		END {
			if (!n) exit 1
			window = (n < 12 ? n : 12)
			for (i = 1; i <= window; i++) rss_first_sum += rss[i]
			for (i = n - window + 1; i <= n; i++) rss_last_sum += rss[i]
			printf "samples=%d\n", n
			printf "rss_first_kb=%d\n", rss[1]
			printf "rss_final_kb=%d\n", rss[n]
			printf "rss_min_kb=%d\n", rss_min
			printf "rss_max_kb=%d\n", rss_max
			printf "rss_first_window_mean_kb=%.0f\n", rss_first_sum / window
			printf "rss_last_window_mean_kb=%.0f\n", rss_last_sum / window
			printf "rss_window_growth_kb=%.0f\n", (rss_last_sum - rss_first_sum) / window
			printf "fd_first=%d\n", fd[1]
			printf "fd_final=%d\n", fd[n]
			printf "fd_min=%d\n", fd_min
			printf "fd_max=%d\n", fd_max
			printf "fd_final_growth=%d\n", fd[n] - fd[1]
			printf "fd_peak_growth=%d\n", fd_max - fd[1]
			printf "threads_first=%d\n", thr[1]
			printf "threads_final=%d\n", thr[n]
			printf "threads_min=%d\n", thr_min
			printf "threads_max=%d\n", thr_max
		}
	' "$sample_file"
}

verify_test()
{
	[ -f "$marker" ] || {
		printf 'error: no active SMD-016 marker\n' >&2
		exit 66
	}
	run_dir=$(read_marker run_dir)
	[ -f "${run_dir}/result.env" ] || {
		printf 'error: test has not completed; use status\n' >&2
		exit 75
	}
	result=$(/usr/bin/awk -F '=' '$1 == "result" { print $2 }' "${run_dir}/result.env")
	if [ "$result" != COMPLETE ]; then
		printf 'error: soak result is %s\n' "$result" >&2
		/bin/cat "${run_dir}/result.env" >&2
		exit 1
	fi
	start_epoch=$(read_marker start_epoch)
	duration_seconds=$(read_marker duration_seconds)
	interval_seconds=$(read_marker interval_seconds)
	old_pid=$(read_marker old_pid)
	old_boot=$(read_marker old_boot)
	old_start=$(read_marker old_start)
	rss_limit_kb=$(read_marker rss_limit_kb)
	fd_final_limit=$(read_marker fd_final_limit)
	fd_peak_limit=$(read_marker fd_peak_limit)
	elapsed=$(/usr/bin/awk -F '=' '$1 == "elapsed_seconds" { print $2 }' "${run_dir}/result.env")
	successful_jobs=$(/usr/bin/awk -F '=' '$1 == "successful_jobs" { print $2 }' "${run_dir}/result.env")
	failed_jobs=$(/usr/bin/awk -F '=' '$1 == "failed_jobs" { print $2 }' "${run_dir}/result.env")
	for value in "$start_epoch" "$duration_seconds" "$interval_seconds" "$old_pid" "$old_boot" \
		"$rss_limit_kb" "$fd_final_limit" "$fd_peak_limit" "$elapsed" "$successful_jobs" \
		"$failed_jobs"; do
		is_uint "$value" || exit 65
	done
	expected_jobs=$((duration_seconds / interval_seconds))
	if [ "$elapsed" -lt "$duration_seconds" ] || [ "$successful_jobs" -lt "$expected_jobs" ] || \
		[ "$failed_jobs" -ne 0 ]; then
		printf 'error: duration or successful job count is insufficient\n' >&2
		exit 1
	fi
	controller_up || {
		printf 'error: controller is not UP at verify\n' >&2
		exit 1
	}
	"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || exit 1
	"$squeue" -w "$node_name" >"${run_dir}/queue-final.txt" || exit 1
	new_pid=$(service_pid)
	new_boot=$(boot_epoch)
	new_start=$(node_field SlurmdStartTime "${run_dir}/node-final.txt")
	state=$(node_field State "${run_dir}/node-final.txt")
	cpu_alloc=$(node_field CPUAlloc "${run_dir}/node-final.txt")
	alloc_mem=$(node_field AllocMem "${run_dir}/node-final.txt")
	if [ "$new_pid" != "$old_pid" ] || [ "$new_boot" != "$old_boot" ] || \
		[ "$new_start" != "$old_start" ]; then
		printf 'error: slurmd or boot identity changed\n' >&2
		exit 1
	fi
	if [ "$state" != IDLE ] || [ "$cpu_alloc" != 0 ] || [ "$alloc_mem" != 0 ] || \
		[ -n "$("$squeue" -h -w "$node_name")" ]; then
		printf 'error: final node or queue is not clean\n' >&2
		exit 1
	fi
	analyse_samples "${run_dir}/samples.tsv" >"${run_dir}/sample-analysis.env" || exit 1
	rss_growth=$(/usr/bin/awk -F '=' '$1 == "rss_window_growth_kb" { print $2 }' "${run_dir}/sample-analysis.env")
	fd_final_growth=$(/usr/bin/awk -F '=' '$1 == "fd_final_growth" { print $2 }' "${run_dir}/sample-analysis.env")
	fd_peak_growth=$(/usr/bin/awk -F '=' '$1 == "fd_peak_growth" { print $2 }' "${run_dir}/sample-analysis.env")
	error_count=$(/bin/cat "${run_dir}/slurmd-error-count.txt")
	if [ "$rss_growth" -gt "$rss_limit_kb" ]; then
		printf 'error: sustained RSS growth exceeds limit growth_kb=%s limit_kb=%s\n' \
			"$rss_growth" "$rss_limit_kb" >&2
		exit 1
	fi
	if [ "$fd_final_growth" -gt "$fd_final_limit" ] || \
		[ "$fd_peak_growth" -gt "$fd_peak_limit" ]; then
		printf 'error: FD growth exceeds limit final=%s peak=%s\n' \
			"$fd_final_growth" "$fd_peak_growth" >&2
		exit 1
	fi
	if [ "$error_count" -ne 0 ]; then
		printf 'error: matching slurmd errors detected count=%s\n' "$error_count" >&2
		exit 1
	fi
	completed_marker=${marker}.completed-$(/bin/date '+%Y%m%dT%H%M%S')
	/bin/mv "$marker" "$completed_marker" || exit 1
	printf 'SMD016_COMPLETE duration_seconds=%s successful_jobs=%s slurmd_pid=%s rss_growth_kb=%s fd_final_growth=%s fd_peak_growth=%s slurmd_error_count=%s marker=%s run_dir=%s\n' \
		"$elapsed" "$successful_jobs" "$new_pid" "$rss_growth" \
		"$fd_final_growth" "$fd_peak_growth" "$error_count" "$completed_marker" "$run_dir"
	/bin/cat "${run_dir}/sample-analysis.env"
}

stop_test()
{
	if [ "${SMD016_STOP_CONFIRMED:-NO}" != YES ]; then
		printf 'error: set SMD016_STOP_CONFIRMED=YES to stop the soak test\n' >&2
		exit 64
	fi
	[ -f "$marker" ] || {
		printf 'error: no active SMD-016 marker\n' >&2
		exit 66
	}
	run_dir=$(read_marker run_dir)
	: >"${run_dir}/stop-requested"
	printf 'SMD016_STOP_REQUESTED run_dir=%s\n' "$run_dir"
}

case "$mode" in
start|status|verify|stop|_run) ;;
*) usage ;;
esac

require_root

case "$mode" in
start) start_test ;;
status) status_test ;;
verify) verify_test ;;
stop) stop_test ;;
_run) run_soak "$@" ;;
esac
