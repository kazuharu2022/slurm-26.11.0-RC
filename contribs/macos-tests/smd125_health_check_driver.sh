#!/bin/sh

set -u

if [ "${SMD125_HEALTH_CHECK_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD125_HEALTH_CHECK_CONFIRMED=YES after confirming PC-210 is idle' >&2
	exit 64
fi

mode=${1:-}
case "$mode" in
success|nonzero|timeout) ;;
*)
	/usr/bin/printf 'usage: %s success|nonzero|timeout\n' "$0" >&2
	exit 64
	;;
esac

source_root=/Users/REDACTED_USER/dev/slurm.26-05
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
production_log=/var/log/slurm/slurmd.log
plist_buddy=/usr/libexec/PlistBuddy
plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_label=org.schedmd.slurmd
service_target=system/${service_label}
sack_socket=/var/run/slurm/sack.socket
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
timeout_seconds=3
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd125-${mode}-${run_stamp}
hook_dir=${run_dir}/hooks
output_dir=${run_dir}/output
event_log=${run_dir}/health-events.log
evidence_log=${run_dir}/health-events-evidence.txt
backup_conf=${run_dir}/slurm.conf.before
candidate_conf=${run_dir}/slurm.conf.smd125
smoke_script=${run_dir}/smoke.sh
smoke_job=
old_pid=
active_pid=
before_start=
active_start=
config_modified=0
restart_required=0
phase_started=0
success=0
production_log_start=0

export SLURM_CONF="$slurm_conf"

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
}

is_running()
{
	[ -n "$1" ] && /bin/kill -0 "$1" >/dev/null 2>&1
}

service_loaded()
{
	/bin/launchctl print "$service_target" >/dev/null 2>&1
}

get_service_pid()
{
	/bin/launchctl print "$service_target" 2>/dev/null | /usr/bin/awk '
		$1 == "pid" && $2 == "=" { print $3; exit }
	'
}

field_from_file()
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

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }'
}

cancel_if_active()
{
	[ -n "$smoke_job" ] || return 0
	state=$(queue_state "$smoke_job")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$smoke_job" "$state" >&2
		"$scancel" "$smoke_job" >/dev/null 2>&1 || true
	fi
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ -z "$(queue_state "$job_id")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' "$job_id" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_accounting_complete()
{
	job_id=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		"$sacct" -j "$job_id" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList >"$file" \
			2>"${file%.txt}.err" || true
		if /usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
			$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { job_ok = 1 }
			$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" { batch_ok = 1 }
			END { exit !(job_ok && batch_ok) }
		' "$file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_reload()
{
	previous_start=$1
	output_file=$2
	expected=$3
	attempt=0
	stable=0
	observed_start=
	while [ "$attempt" -lt 180 ]; do
		if "$scontrol" show node "$node_name" >"$output_file" 2>"${output_file}.err"; then
			state=$(field_from_file State "$output_file")
			candidate_start=$(field_from_file SlurmdStartTime "$output_file")
			state_ok=0
			case "$state" in
			*NOT_RESPONDING*) state_ok=0 ;;
			*)
				case "$expected:$state" in
				idle:IDLE) state_ok=1 ;;
				drain:*DRAIN*) state_ok=1 ;;
				any:*) state_ok=1 ;;
				esac
			;;
			esac
			if [ "$state_ok" -eq 1 ] && [ -n "$candidate_start" ] && \
				[ "$candidate_start" != None ] && \
				[ "$candidate_start" != "$previous_start" ]; then
				observed_start=$candidate_start
				stable=$((stable + 1))
			else
				stable=0
			fi
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			/usr/bin/printf '%s\n' "$observed_start"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_service_unloaded()
{
	previous_pid=$1
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		if ! service_loaded && ! is_running "$previous_pid"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

bootstrap_service()
{
	/bin/launchctl enable "$service_target" >/dev/null 2>&1 || return 1
	/bin/launchctl bootstrap system "$plist" >/dev/null 2>&1 || return 1
	return 0
}

wait_service_phase()
{
	previous_pid=$1
	previous_start=$2
	expected=$3
	output_file=$4
	launchd_file=$5
	attempt=0
	stable=0
	while [ "$attempt" -lt 180 ]; do
		observed_pid=
		pid_from_file=
		service_loaded && observed_pid=$(get_service_pid 2>/dev/null || true)
		[ -f "$pid_file" ] && pid_from_file=$(/bin/cat "$pid_file" 2>/dev/null)
		if [ -n "$observed_pid" ] && [ "$observed_pid" != "$previous_pid" ] && \
			[ "$pid_from_file" = "$observed_pid" ] && is_running "$observed_pid" && \
			[ -S "$sack_socket" ] && \
			"$scontrol" show node "$node_name" >"$output_file" 2>"${output_file}.err"; then
			state=$(field_from_file State "$output_file")
			candidate_start=$(field_from_file SlurmdStartTime "$output_file")
			state_ok=0
			case "$state" in
			*NOT_RESPONDING*) state_ok=0 ;;
			*)
				case "$expected:$state" in
				idle:IDLE) state_ok=1 ;;
				drain:*DRAIN*) state_ok=1 ;;
				esac
			;;
			esac
			if [ "$state_ok" -eq 1 ] && [ -n "$candidate_start" ] && \
				[ "$candidate_start" != None ] && \
				[ "$candidate_start" != "$previous_start" ]; then
				active_pid=$observed_pid
				active_start=$candidate_start
				stable=$((stable + 1))
			else
				stable=0
			fi
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			/bin/launchctl print "$service_target" >"$launchd_file" 2>&1 || return 1
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_any_service()
{
	output_file=$1
	launchd_file=$2
	attempt=0
	stable=0
	while [ "$attempt" -lt 180 ]; do
		observed_pid=
		pid_from_file=
		service_loaded && observed_pid=$(get_service_pid 2>/dev/null || true)
		[ -f "$pid_file" ] && pid_from_file=$(/bin/cat "$pid_file" 2>/dev/null)
		if [ -n "$observed_pid" ] && [ "$pid_from_file" = "$observed_pid" ] && \
			is_running "$observed_pid" && [ -S "$sack_socket" ] && \
			"$scontrol" show node "$node_name" >"$output_file" 2>"${output_file}.err"; then
			state=$(field_from_file State "$output_file")
			case "$state" in
			*NOT_RESPONDING*|'') stable=0 ;;
			*) stable=$((stable + 1)) ;;
			esac
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			/bin/launchctl print "$service_target" >"$launchd_file" 2>&1 || return 1
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_idle()
{
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$scontrol" show node "$node_name" >"${run_dir}/node-recovered.txt" \
			2>"${run_dir}/node-recovered.err" || true
		state=$(field_from_file State "${run_dir}/node-recovered.txt")
		cpu=$(field_from_file CPUAlloc "${run_dir}/node-recovered.txt")
		mem=$(field_from_file AllocMem "${run_dir}/node-recovered.txt")
		if [ "$state" = IDLE ] && [ "$cpu" = 0 ] && [ "$mem" = 0 ]; then
			/usr/bin/printf 'node_recovered state=%s CPUAlloc=%s AllocMem=%s wait_seconds=%s\n' \
				"$state" "$cpu" "$mem" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_event()
{
	pattern=$1
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		/usr/bin/grep -Eq "$pattern" "$event_log" 2>/dev/null && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

snapshot_events()
{
	[ -f "$event_log" ] || return 0
	/bin/cp "$event_log" "$evidence_log" || return 1
	/usr/sbin/chown 0:0 "$evidence_log" || return 1
	/bin/chmod 0444 "$evidence_log" || return 1
}

restore_config()
{
	[ "$config_modified" -eq 1 ] || return 0
	/usr/bin/printf 'restore production_config=%s\n' "$slurm_conf" >&2
	/bin/cp "$backup_conf" "$slurm_conf" || return 1
	service_loaded || return 1
	current_pid=$(get_service_pid)
	is_running "$current_pid" || return 1
	"$scontrol" reconfigure >"${run_dir}/reconfigure-restore.out" \
		2>"${run_dir}/reconfigure-restore.err" || return 1
	restored_start=$(wait_reload "$active_start" "${run_dir}/node-restored.txt" any) || \
		return 1
	/usr/bin/cmp -s "$backup_conf" "$slurm_conf" || return 1
	config_modified=0
	restart_required=0
	/usr/bin/printf 'production_restored slurmd_pid=%s start=%s\n' \
		"$current_pid" "$restored_start"
	return 0
}

recover_production_service()
{
	/bin/cp "$backup_conf" "$slurm_conf" || return 1
	/usr/bin/cmp -s "$backup_conf" "$slurm_conf" || return 1
	recovery_pid=
	service_loaded && recovery_pid=$(get_service_pid 2>/dev/null || true)
	if service_loaded && is_running "$recovery_pid"; then
		"$scontrol" show node "$node_name" >"${run_dir}/recovery-node-before.txt" \
			2>"${run_dir}/recovery-node-before.err" || return 1
		recovery_start=$(field_from_file SlurmdStartTime \
			"${run_dir}/recovery-node-before.txt")
		[ -n "$recovery_start" ] && [ "$recovery_start" != None ] || return 1
		"$scontrol" reconfigure >/dev/null 2>&1 || return 1
		wait_reload "$recovery_start" "${run_dir}/recovery-node.txt" any \
			>/dev/null || return 1
	else
		if service_loaded; then
			/bin/launchctl bootout "$service_target" >/dev/null 2>&1 || true
			wait_service_unloaded "$recovery_pid" || return 1
		fi
		bootstrap_service || return 1
	fi
	wait_any_service "${run_dir}/recovery-node.txt" \
		"${run_dir}/recovery-launchd.txt"
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active
	if [ "$config_modified" -eq 1 ] || [ "$restart_required" -eq 1 ]; then
		if recover_production_service; then
			/usr/bin/printf 'recovery: production launchd service/config restored\n' >&2
		else
			/usr/bin/printf 'fatal recovery: production launchd service/config restore failed\n' >&2
			rc=1
		fi
	fi
	snapshot_events || rc=1
	if [ "$success" -ne 1 ]; then
		if [ "$phase_started" -eq 1 ] && [ "$mode" != success ]; then
			/usr/bin/printf 'recovery: node may remain DRAINED intentionally; inspect run_dir=%s before RESUME\n' \
				"$run_dir" >&2
		elif [ "$phase_started" -eq 1 ]; then
			/usr/bin/printf 'recovery: success-mode harness failed; no intentional DRAIN was requested; inspect run_dir=%s\n' \
				"$run_dir" >&2
		else
			/usr/bin/printf 'recovery: stopped before HealthCheck runtime; inspect run_dir=%s\n' \
				"$run_dir" >&2
		fi
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$slurmd" "$scontrol" "$squeue" \
	"$sbatch" "$scancel" "$sacct" "$pid_file" "$production_log" \
	"$plist_buddy" "$plist" \
	"${source_root}/contribs/macos-tests/smd125_health_check.sh"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for required_command in /bin/cat /bin/chmod /bin/cp /bin/date /bin/kill \
	/bin/launchctl /bin/mkdir /bin/ps /bin/sleep /usr/bin/awk /usr/bin/cmp /usr/bin/env \
	/usr/bin/grep /usr/bin/id /usr/bin/plutil /usr/bin/sed /usr/bin/shasum /usr/bin/sudo \
	/usr/bin/tr /usr/bin/wc /usr/sbin/chown; do
	[ -x "$required_command" ] || fail "required command is not executable: $required_command"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$hook_dir" || fail 'cannot create run directories'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
/bin/cp "${source_root}/contribs/macos-tests/smd125_health_check.sh" \
	"${hook_dir}/health-check.sh" || fail 'cannot stage health check'
/bin/chmod 0555 "${hook_dir}/health-check.sh" || fail 'cannot set health check mode'
/usr/sbin/chown 0:0 "${hook_dir}/health-check.sh" || fail 'cannot set health check owner'
/usr/bin/printf '%s\n' "$mode" >"${run_dir}/mode" || fail 'cannot write mode'
/bin/chmod 0444 "${run_dir}/mode" || fail 'cannot set mode-file permissions'
: >"$event_log" || fail 'cannot create event log'
/bin/chmod 0600 "$event_log" || fail 'cannot protect event log'
/usr/sbin/chown 0:0 "$event_log" || fail 'cannot set event log owner'
{
	/usr/bin/printf '#!/bin/sh\n'
	/usr/bin/printf '/bin/hostname\n'
} >"$smoke_script" || fail 'cannot create smoke script'
/bin/chmod 0555 "$smoke_script" || fail 'cannot set smoke mode'
/usr/sbin/chown 0:0 "$smoke_script" || fail 'cannot set smoke owner'
/usr/bin/printf 'mode=%s run_dir=%s\n' "$mode" "$run_dir"

trap cleanup EXIT HUP INT TERM

/usr/bin/plutil -lint "$plist" >"${run_dir}/plist-lint.txt" 2>&1 || \
	fail 'production launchd plist is invalid'
[ "$("$plist_buddy" -c 'Print :Label' "$plist")" = "$service_label" ] || \
	fail 'production launchd plist Label mismatch'
[ "$("$plist_buddy" -c 'Print :ProgramArguments:0' "$plist")" = "$slurmd" ] || \
	fail 'production launchd plist slurmd path mismatch'
service_loaded || fail "launchd service is not loaded: $service_target"
/bin/launchctl print "$service_target" >"${run_dir}/launchd-before.txt" 2>&1 || \
	fail 'cannot read launchd service'
/usr/bin/grep -q 'state = running' "${run_dir}/launchd-before.txt" || \
	fail 'launchd service is not running'
/bin/launchctl print-disabled system >"${run_dir}/launchd-disabled-before.txt" 2>&1 || \
	fail 'cannot read launchd enabled state'
/usr/bin/grep -Fq "\"${service_label}\" => enabled" \
	"${run_dir}/launchd-disabled-before.txt" || fail 'launchd service is not enabled'
"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
[ "$(field_from_file State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(field_from_file CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(field_from_file AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'

old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$old_pid" ;;
esac
/bin/kill -0 "$old_pid" >/dev/null 2>&1 || fail "slurmd pid=$old_pid is not running"
[ "$(get_service_pid)" = "$old_pid" ] || fail 'launchd and pidfile PID mismatch'
[ -S "$sack_socket" ] || fail 'SACK socket is absent'
before_start=$(field_from_file SlurmdStartTime "${run_dir}/node-before.txt")
[ -n "$before_start" ] && [ "$before_start" != None ] || fail 'invalid SlurmdStartTime'
production_log_start=$(/usr/bin/wc -l <"$production_log" | /usr/bin/tr -d ' ')

if /usr/bin/grep -Eq '^[[:space:]]*HealthCheck(Interval|NodeState|Program|Timeout)[[:space:]]*=' \
	"$slurm_conf"; then
	fail 'production config already has active HealthCheck settings; refusing to replace them'
fi

/bin/cp -p "$slurm_conf" "$backup_conf" || fail 'cannot back up slurm.conf'
/bin/cp "$backup_conf" "$candidate_conf" || fail 'cannot create candidate config'
{
	/usr/bin/printf '\n# SMD-125 temporary health-check test\n'
	/usr/bin/printf 'HealthCheckInterval=0\n'
	/usr/bin/printf 'HealthCheckNodeState=START_ONLY\n'
	/usr/bin/printf 'HealthCheckProgram=%s\n' "${hook_dir}/health-check.sh"
	/usr/bin/printf 'HealthCheckTimeout=%s\n' "$timeout_seconds"
} >>"$candidate_conf" || fail 'cannot append HealthCheck settings'
"$slurmd" -C -f "$candidate_conf" >"${run_dir}/candidate-parse.txt" \
	2>"${run_dir}/candidate-parse.err" || fail 'candidate configuration did not parse'
/usr/bin/shasum -a 256 "$backup_conf" >"${run_dir}/config-before.sha256"
/usr/bin/shasum -a 256 "$candidate_conf" >"${run_dir}/config-candidate.sha256"

/bin/cp "$candidate_conf" "$slurm_conf" || fail 'cannot apply candidate config'
config_modified=1
phase_started=1
restart_required=1
/usr/bin/printf 'start_health_instance old_pid=%s method=launchctl_bootout_bootstrap\n' "$old_pid"
/bin/launchctl bootout "$service_target" >"${run_dir}/bootout-candidate.out" \
	2>"${run_dir}/bootout-candidate.err" || fail 'launchctl bootout failed'
wait_service_unloaded "$old_pid" || fail 'old slurmd/service remained after bootout'
bootstrap_service || fail 'candidate launchd bootstrap failed'

wait_event "^event=health_begin mode=${mode} node=${node_name} node_health=unset .*euid=0 egid=0 pid=[0-9]+ pgid=[0-9]+$" || \
	fail 'health-check begin event not observed or environment/identity mismatch'

if [ "$mode" = success ]; then
	wait_event "^event=health_success mode=success node=${node_name} .*exit_code=0$" || \
		fail 'health-check success event not observed'
	wait_service_phase "$old_pid" "$before_start" idle \
		"${run_dir}/node-active.txt" "${run_dir}/launchd-active.txt" || \
		fail 'node did not remain stably IDLE after successful health check'
	[ "$(/usr/bin/wc -l <"$event_log" | /usr/bin/tr -d ' ')" = 2 ] || \
		fail 'unexpected successful health-check event count'
	/usr/bin/printf 'health_result=PASS mode=success node_state=IDLE identity=0:0 environment=PASS\n'
else
	wait_event "^event=health_drain mode=${mode} node=${node_name} .*scontrol_rc=0 reason=SMD125_health_${mode}$" || \
		fail 'health-check drain action did not succeed'
	if [ "$mode" = nonzero ]; then
		wait_event "^event=health_nonzero mode=nonzero node=${node_name} .*exit_code=42$" || \
			fail 'health-check nonzero event not observed'
	else
		wait_event "^event=health_timeout_begin mode=timeout node=${node_name} .*pid=[0-9]+ pgid=[0-9]+$" || \
			fail 'health-check timeout event not observed'
	fi
	wait_service_phase "$old_pid" "$before_start" drain \
		"${run_dir}/node-active.txt" "${run_dir}/launchd-active.txt" || \
		fail 'node did not become stably DRAINED after health-check failure'
	node_reason=$(field_from_file Reason "${run_dir}/node-active.txt")
	case "$node_reason" in
	SMD125_health_${mode}*) ;;
	*) fail "unexpected node reason=$node_reason" ;;
	esac
	if [ "$mode" = timeout ]; then
		/bin/sleep $((timeout_seconds + 2))
		timeout_pid=$(/usr/bin/awk '$1 == "event=health_timeout_begin" { for (i=1;i<=NF;i++) if ($i ~ /^pid=/) { sub(/^pid=/,"",$i); print $i; exit } }' "$event_log")
		timeout_pgid=$(/usr/bin/awk '$1 == "event=health_timeout_begin" { for (i=1;i<=NF;i++) if ($i ~ /^pgid=/) { sub(/^pgid=/,"",$i); print $i; exit } }' "$event_log")
		[ "$timeout_pid" = "$timeout_pgid" ] || fail "timeout process was not group leader pid=$timeout_pid pgid=$timeout_pgid"
		/bin/ps -axo pid=,ppid=,pgid=,command= >"${run_dir}/timeout-processes-after.txt" || \
			fail 'cannot capture timeout process table'
		if /usr/bin/awk -v pgid="$timeout_pgid" '$3 == pgid { found=1 } END { exit !found }' \
			"${run_dir}/timeout-processes-after.txt"; then
			fail "timeout process group remains pgid=$timeout_pgid"
		fi
		/usr/bin/printf 'timeout_process_group_cleanup=PASS pid=%s pgid=%s\n' \
			"$timeout_pid" "$timeout_pgid"
	fi
	log_first=$((production_log_start + 1))
	/usr/bin/sed -n "${log_first},\$p" "$production_log" >"${run_dir}/slurmd-health.log"
	if [ "$mode" = nonzero ]; then
		/usr/bin/grep -Eq 'health_check failed: rc:42' "${run_dir}/slurmd-health.log" || \
			fail 'worker log lacks health-check exit 42 evidence'
	else
		/usr/bin/grep -Eq 'health_check poll timeout @ 3000 msec|health_check: timeout after 3000 ms|health_check killed by signal' \
			"${run_dir}/slurmd-health.log" || fail 'worker log lacks health-check timeout evidence'
	fi
	[ "$(/usr/bin/wc -l <"$event_log" | /usr/bin/tr -d ' ')" = 3 ] || \
		fail 'unexpected failed health-check event count'
	/usr/bin/printf 'health_result=PASS mode=%s node_state=DRAIN node_reason=%s\n' \
		"$mode" "$node_reason"
	[ "$(/usr/bin/wc -l <"$event_log" | /usr/bin/tr -d ' ')" = 3 ] || \
		fail 'unexpected failed health-check event count'
fi

[ "$(/bin/cat "$pid_file")" = "$active_pid" ] || fail 'pidfile and active slurmd PID mismatch'
/usr/bin/printf 'health_instance_ready old_pid=%s active_pid=%s old_start=%s active_start=%s\n' \
	"$old_pid" "$active_pid" "$before_start" "$active_start"
snapshot_events || fail 'cannot snapshot health events'
restore_config || fail 'production configuration restore failed'

"$scontrol" show node "$node_name" >"${run_dir}/node-before-resume.txt" || fail 'node readback before recovery failed'
case "$(field_from_file State "${run_dir}/node-before-resume.txt")" in
*DRAIN*)
	"$scontrol" update NodeName="$node_name" State=RESUME \
		>"${run_dir}/resume.out" 2>"${run_dir}/resume.err" || fail 'node RESUME failed'
	;;
esac
wait_idle || fail 'node did not recover to IDLE'

smoke_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=128M --time=00:01:00 --chdir=/tmp \
		--job-name="smd125-${mode}-smoke" --output="${output_dir}/smoke-%j.out" \
		--error="${output_dir}/smoke-%j.err" "$smoke_script"
) || fail 'post-recovery smoke submission failed'
smoke_job=${smoke_job%%;*}
/usr/bin/printf 'submitted smoke_job=%s\n' "$smoke_job"
wait_job_gone "$smoke_job" || fail 'post-recovery smoke did not leave queue'
wait_accounting_complete "$smoke_job" "${run_dir}/smoke-sacct.txt" || \
	fail 'post-recovery smoke accounting did not reach COMPLETED 0:0'
/usr/bin/grep -Eq '^PC-210(\.local)?$' "${output_dir}/smoke-${smoke_job}.out" || \
	fail 'post-recovery smoke hostname mismatch'
[ ! -s "${output_dir}/smoke-${smoke_job}.err" ] || fail 'post-recovery smoke stderr is not empty'

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || fail 'final node readback failed'
[ "$(field_from_file State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(field_from_file CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(field_from_file AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$active_pid" ] || fail 'final slurmd PID changed unexpectedly'
/usr/bin/cmp -s "$backup_conf" "$slurm_conf" || fail 'final config is not byte-for-byte restored'
/usr/bin/shasum -a 256 "$slurm_conf" >"${run_dir}/config-restored.sha256"

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD125_PHASE_COMPLETE mode=%s smoke_job=%s slurmd_pid=%s run_dir=%s\n' \
	"$mode" "$smoke_job" "$active_pid" "$run_dir"
