#!/bin/sh

set -u

if [ "${SMD121_PROLOG_FAILURE_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf 'error: set SMD121_PROLOG_FAILURE_CONFIRMED=YES after confirming intentional node DRAIN is acceptable\n' >&2
	exit 64
fi

mode=${1:-}
case "$mode" in
nonzero|timeout) ;;
*)
	/usr/bin/printf 'usage: %s nonzero|timeout\n' "$0" >&2
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
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
timeout_seconds=5
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd121-${mode}-${run_stamp}
hook_dir=${run_dir}/hooks
output_dir=${run_dir}/output
event_log=${run_dir}/hook-events.log
backup_conf=${run_dir}/slurm.conf.before
candidate_conf=${run_dir}/slurm.conf.smd121
payload=${run_dir}/payload.sh
payload_marker=${output_dir}/payload.marker
smoke_marker=${output_dir}/smoke.marker
test_job=
smoke_job=
config_modified=0
failure_injected=0
success=0
old_pid=
before_start=
before_state=
active_start=
production_log_start=0
scheduler_parameters=
timeout_pid=
timeout_pgid=

export SLURM_CONF="$slurm_conf"

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
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
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null | \
		/usr/bin/awk 'NR == 1 { print; exit }'
}

cancel_if_active()
{
	job_id=$1
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state" >&2
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ -z "$(queue_state "$job_id")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' \
				"$job_id" "$attempt"
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
	require_idle=$3
	attempt=0
	stable_count=0
	observed_start=
	while [ "$attempt" -lt 180 ]; do
		if "$scontrol" show node "$node_name" >"$output_file" 2>/dev/null; then
			state=$(field_from_file State "$output_file")
			candidate_start=$(field_from_file SlurmdStartTime "$output_file")
			state_ok=1
			case "$state" in
			*NOT_RESPONDING*) state_ok=0 ;;
			esac
			if [ "$require_idle" -eq 1 ] && [ "$state" != IDLE ]; then
				state_ok=0
			fi
			if [ "$state_ok" -eq 1 ] && [ -n "$candidate_start" ] && \
				[ "$candidate_start" != None ] && \
				[ "$candidate_start" != "$previous_start" ]; then
				observed_start=$candidate_start
				stable_count=$((stable_count + 1))
			else
				stable_count=0
			fi
		else
			stable_count=0
		fi
		if [ "$stable_count" -ge 3 ]; then
			/usr/bin/printf '%s\n' "$observed_start"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_failure_state()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$scontrol" show node "$node_name" >"${run_dir}/node-failure.txt" \
			2>"${run_dir}/node-failure.err" || true
		"$scontrol" show job -dd "$job_id" >"${run_dir}/job-held.txt" \
			2>"${run_dir}/job-held.err" || true
		node_state=$(field_from_file State "${run_dir}/node-failure.txt")
		job_state=$(field_from_file JobState "${run_dir}/job-held.txt")
		priority=$(field_from_file Priority "${run_dir}/job-held.txt")
		case "$node_state" in
		*DRAIN*) node_drained=1 ;;
		*) node_drained=0 ;;
		esac
		if [ "$node_drained" -eq 1 ] && [ "$job_state" = PENDING ] && \
			[ "$priority" = 0 ]; then
			/usr/bin/printf 'failure_observed mode=%s job_id=%s node_state=%s job_state=%s priority=%s wait_seconds=%s\n' \
				"$mode" "$job_id" "$node_state" "$job_state" \
				"$priority" "$attempt"
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

wait_accounting_complete()
{
	job_id=$1
	output_file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		"$sacct" -j "$job_id" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList \
			>"$output_file" 2>/dev/null || true
		if /usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
			$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { job_ok = 1 }
			$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" { batch_ok = 1 }
			END { exit !(job_ok && batch_ok) }
		' "$output_file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

restore_config()
{
	[ "$config_modified" -eq 1 ] || return 0
	/usr/bin/printf 'restore production_config=%s\n' "$slurm_conf" >&2
	/bin/cp "$backup_conf" "$slurm_conf" || return 1
	"$scontrol" reconfigure >"${run_dir}/reconfigure-restore.out" \
		2>"${run_dir}/reconfigure-restore.err" || return 1
	if ! restored_start=$(wait_reload "$active_start" \
		"${run_dir}/node-restored-drained.txt" 0); then
		return 1
	fi
	/usr/bin/cmp -s "$backup_conf" "$slurm_conf" || return 1
	config_modified=0
	/usr/bin/printf 'production_restored slurmd_pid=%s start=%s\n' \
		"$old_pid" "$restored_start"
	return 0
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$test_job"
	cancel_if_active "$smoke_job"
	if ! restore_config; then
		/usr/bin/printf 'fatal recovery: verify %s against %s and reconfigure\n' \
			"$slurm_conf" "$backup_conf" >&2
		rc=1
	fi
	if [ "$success" -ne 1 ]; then
		if [ "$failure_injected" -eq 1 ]; then
			/usr/bin/printf 'recovery: node may remain DRAINED intentionally; inspect run_dir=%s before manual RESUME\n' \
				"$run_dir" >&2
		else
			/usr/bin/printf 'recovery: stopped before intentional Prolog failure injection; no failure job was submitted; inspect run_dir=%s\n' \
				"$run_dir" >&2
		fi
	fi
	exit "$rc"
}

submit_payload()
{
	job_name=$1
	marker=$2
	stdout_path=$3
	stderr_path=$4
	(
		cd /tmp || exit 1
		/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
			SLURM_CONF="$slurm_conf" \
			"$sbatch" --parsable --requeue --partition="$partition" \
			--nodes=1 --ntasks=1 --cpus-per-task=1 --mem=256M \
			--time=00:01:00 --chdir=/tmp --job-name="$job_name" \
			--output="$stdout_path" --error="$stderr_path" \
			"$payload" "$marker"
	)
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

if [ "$mode" = nonzero ]; then
	hook_source=${source_root}/contribs/macos-tests/smd121_prolog_nonzero.sh
else
	hook_source=${source_root}/contribs/macos-tests/smd121_prolog_timeout.sh
fi

for required_file in "$slurm_conf" "$slurmd" "$scontrol" "$squeue" \
	"$sbatch" "$scancel" "$sacct" "$pid_file" "$production_log" \
	"$hook_source" "${source_root}/contribs/macos-tests/smd121_payload.sh"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$hook_dir" || fail 'cannot create run directories'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
/bin/cp "$hook_source" "${hook_dir}/prolog.sh" || fail 'cannot stage prolog'
/bin/cp "${source_root}/contribs/macos-tests/smd121_payload.sh" "$payload" || \
	fail 'cannot stage payload'
/bin/chmod 0555 "${hook_dir}/prolog.sh" "$payload" || fail 'cannot set executable modes'
/usr/sbin/chown 0:0 "${hook_dir}/prolog.sh" "$payload" || fail 'cannot set staged owners'
: >"$event_log" || fail 'cannot create hook event log'
/bin/chmod 0600 "$event_log" || fail 'cannot protect hook event log'
/usr/sbin/chown 0:0 "$event_log" || fail 'cannot set hook event log owner'
/usr/bin/printf 'mode=%s run_dir=%s\n' "$mode" "$run_dir"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
before_state=$(field_from_file State "${run_dir}/node-before.txt")
[ "$before_state" = IDLE ] || \
	fail "node state is $before_state, expected IDLE; no config change or job submission"
[ "$(field_from_file CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(field_from_file AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'

old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$old_pid" ;;
esac
/bin/kill -0 "$old_pid" >/dev/null 2>&1 || fail "slurmd pid=$old_pid is not running"
before_start=$(field_from_file SlurmdStartTime "${run_dir}/node-before.txt")
production_log_start=$(/usr/bin/wc -l <"$production_log" | /usr/bin/tr -d ' ')

if /usr/bin/grep -Eq '^[[:space:]]*(Prolog|Epilog|PrologFlags|PrologTimeout|EpilogTimeout)[[:space:]]*=' \
	"$slurm_conf"; then
	fail 'production config has an existing hook, PrologFlags, or individual timeout; refusing to replace it'
fi
scheduler_parameters=$(/usr/bin/awk -F= '
	/^[[:space:]]*SchedulerParameters[[:space:]]*=/ {
		value = $2
		gsub(/[[:space:]]/, "", value)
		print value
		exit
	}' "$slurm_conf")
case ",$scheduler_parameters," in
*,nohold_on_prolog_fail,*)
	fail 'nohold_on_prolog_fail is configured; expected held-job behavior is not applicable'
	;;
esac

/bin/cp -p "$slurm_conf" "$backup_conf" || fail 'cannot back up slurm.conf'
/bin/cp "$backup_conf" "$candidate_conf" || fail 'cannot create candidate config'
{
	/usr/bin/printf '\n# SMD-121 temporary intentional Prolog failure test\n'
	/usr/bin/printf 'Prolog=%s\n' "${hook_dir}/prolog.sh"
	if [ "$mode" = timeout ]; then
		/usr/bin/printf 'PrologTimeout=%s\n' "$timeout_seconds"
	fi
} >>"$candidate_conf" || fail 'cannot append candidate Prolog settings'

"$slurmd" -C -f "$candidate_conf" >"${run_dir}/candidate-parse.txt" \
	2>"${run_dir}/candidate-parse.err" || fail 'candidate configuration did not parse'
/usr/bin/shasum -a 256 "$backup_conf" >"${run_dir}/config-before.sha256"
/usr/bin/shasum -a 256 "$candidate_conf" >"${run_dir}/config-candidate.sha256"

/bin/cp "$candidate_conf" "$slurm_conf" || fail 'cannot apply candidate config'
config_modified=1
"$scontrol" reconfigure >"${run_dir}/reconfigure-apply.out" \
	2>"${run_dir}/reconfigure-apply.err" || fail 'candidate reconfigure failed'
active_start=$(wait_reload "$before_start" "${run_dir}/node-active.txt" 1) || \
	fail 'worker did not become stably IDLE with failure config'
[ "$(/bin/cat "$pid_file")" = "$old_pid" ] || fail 'slurmd PID changed during reconfigure'
/usr/bin/printf 'failure_config_active mode=%s slurmd_pid=%s old_start=%s new_start=%s\n' \
	"$mode" "$old_pid" "$before_start" "$active_start"

test_result=$(submit_payload "smd121-${mode}" "$payload_marker" \
	"${output_dir}/failure-%j.out" "${output_dir}/failure-%j.err") || \
	fail 'failure job submission failed'
test_job=${test_result%%;*}
failure_injected=1
/usr/bin/printf 'submitted failure_job=%s mode=%s\n' "$test_job" "$mode"
wait_failure_state "$test_job" || fail 'expected DRAIN and held job state were not observed'

node_reason=$(field_from_file Reason "${run_dir}/node-failure.txt")
job_reason=$(field_from_file Reason "${run_dir}/job-held.txt")
restarts=$(field_from_file Restarts "${run_dir}/job-held.txt")
case "$node_reason" in
*Prolog*) ;;
*) fail "unexpected node reason=$node_reason" ;;
esac
case "$restarts" in
''|*[!0-9]*) fail "invalid job Restarts=$restarts" ;;
esac
[ "$restarts" -ge 1 ] || fail "job was not requeued Restarts=$restarts"
[ ! -e "$payload_marker" ] || fail 'payload marker exists despite Prolog failure'
failure_stdout=${output_dir}/failure-${test_job}.out
if [ -f "$failure_stdout" ] && /usr/bin/grep -q 'SMD121_PAYLOAD_EXECUTED=YES' "$failure_stdout"; then
	fail 'payload stdout marker exists despite Prolog failure'
fi

if [ "$mode" = nonzero ]; then
	/usr/bin/grep -Eq "^event=prolog_nonzero job_id=${test_job} epoch=[0-9]+ euid=0 egid=0 context=prolog_slurmd exit_code=42$" \
		"$event_log" || fail 'nonzero Prolog event mismatch'
else
	/usr/bin/grep -Eq "^event=prolog_timeout_begin job_id=${test_job} epoch=[0-9]+ euid=0 egid=0 context=prolog_slurmd pid=[0-9]+ pgid=[0-9]+$" \
		"$event_log" || fail 'timeout Prolog event mismatch'
	timeout_pid=$(/usr/bin/awk -v job="$test_job" '
		$1 == "event=prolog_timeout_begin" && $2 == "job_id=" job {
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^pid=/) {
					sub(/^pid=/, "", $i)
					print $i
					exit
				}
			}
		}' "$event_log")
	timeout_pgid=$(/usr/bin/awk -v job="$test_job" '
		$1 == "event=prolog_timeout_begin" && $2 == "job_id=" job {
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^pgid=/) {
					sub(/^pgid=/, "", $i)
					print $i
					exit
				}
			}
		}' "$event_log")
	case "$timeout_pid:$timeout_pgid" in
	*[!0-9:]*|:|*:|:*) fail "invalid timeout process identity pid=$timeout_pid pgid=$timeout_pgid" ;;
	esac
	[ "$timeout_pid" = "$timeout_pgid" ] || \
		fail "timeout hook was not process-group leader pid=$timeout_pid pgid=$timeout_pgid"
	/bin/ps -axo pid=,ppid=,pgid=,command= >"${run_dir}/timeout-processes-after.txt" || \
		fail 'cannot capture process table after timeout'
	if /usr/bin/awk -v pgid="$timeout_pgid" '$3 == pgid { found = 1 } END { exit !found }' \
		"${run_dir}/timeout-processes-after.txt"; then
		fail "timeout process group remains pgid=$timeout_pgid"
	fi
	/usr/bin/printf 'timeout_process_group_cleanup=PASS pid=%s pgid=%s\n' \
		"$timeout_pid" "$timeout_pgid"
fi

log_first=$((production_log_start + 1))
/usr/bin/sed -n "${log_first},\$p" "$production_log" \
	>"${run_dir}/slurmd-failure.log"
if [ "$mode" = nonzero ]; then
	/usr/bin/grep -Eq 'prolog failed: rc:42|prolog failed status=42:0' \
		"${run_dir}/slurmd-failure.log" || fail 'worker log lacks Prolog exit 42 evidence'
else
	/usr/bin/grep -Eq 'prolog poll timeout @ 5000 msec|timeout after 5000 ms|prolog.*timed out' \
		"${run_dir}/slurmd-failure.log" || fail 'worker log lacks Prolog timeout evidence'
fi
/usr/bin/printf 'failure_state=PASS mode=%s job_id=%s node_reason=%s job_reason=%s restarts=%s payload_executed=NO\n' \
	"$mode" "$test_job" "$node_reason" "$job_reason" "$restarts"

"$scancel" "$test_job" >"${run_dir}/cancel.out" 2>"${run_dir}/cancel.err" || \
	fail 'failed to cancel held test job'
wait_job_gone "$test_job" || fail 'held test job did not leave queue after cancel'
"$sacct" -j "$test_job" -n -P \
	--format=JobIDRaw,User,State,ExitCode,NodeList >"${run_dir}/failure-sacct.txt" \
	2>"${run_dir}/failure-sacct.err" || true

restore_config || fail 'production configuration restore failed'
"$scontrol" update NodeName="$node_name" State=RESUME \
	>"${run_dir}/resume.out" 2>"${run_dir}/resume.err" || fail 'node RESUME failed'
wait_idle || fail 'node did not recover to IDLE after config restore and RESUME'

smoke_result=$(submit_payload "smd121-${mode}-smoke" "$smoke_marker" \
	"${output_dir}/smoke-%j.out" "${output_dir}/smoke-%j.err") || \
	fail 'post-recovery smoke submission failed'
smoke_job=${smoke_result%%;*}
/usr/bin/printf 'submitted smoke_job=%s\n' "$smoke_job"
wait_job_gone "$smoke_job" || fail 'post-recovery smoke job did not leave queue'
wait_accounting_complete "$smoke_job" "${run_dir}/smoke-sacct.txt" || \
	fail 'post-recovery smoke accounting did not reach COMPLETED 0:0'
[ -f "$smoke_marker" ] || fail 'post-recovery smoke payload marker is missing'
/usr/bin/grep -Fq "SMD121_PAYLOAD_EXECUTED=YES job_id=${smoke_job} uid=${test_uid} gid=${test_gid}" \
	"$smoke_marker" || fail 'post-recovery smoke payload identity mismatch'

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || fail 'final node readback failed'
[ "$(field_from_file State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(field_from_file CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(field_from_file AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final node queue is not empty'
/usr/bin/cmp -s "$backup_conf" "$slurm_conf" || fail 'final config is not byte-for-byte restored'
/usr/bin/shasum -a 256 "$slurm_conf" >"${run_dir}/config-restored.sha256"

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD121_PHASE_COMPLETE mode=%s failure_job=%s smoke_job=%s slurmd_pid=%s run_dir=%s\n' \
	"$mode" "$test_job" "$smoke_job" "$old_pid" "$run_dir"
