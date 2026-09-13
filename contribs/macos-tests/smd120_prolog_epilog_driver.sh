#!/bin/sh

set -u

if [ "${SMD120_HOOK_TEST_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf 'error: set SMD120_HOOK_TEST_CONFIRMED=YES after confirming PC-210 is idle\n' >&2
	exit 64
fi

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
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd120-${run_stamp}
hook_dir=${run_dir}/hooks
output_dir=${run_dir}/output
event_log=${run_dir}/hook-events.log
backup_conf=${run_dir}/slurm.conf.before
candidate_conf=${run_dir}/slurm.conf.smd120
test_job=
smoke_job=
config_modified=0
success=0
old_pid=
before_start=
active_start=
production_log_start=0
hook_timeout=

export SLURM_CONF="$slurm_conf"

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
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
			$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" {
				job_ok = 1
			}
			$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" {
				batch_ok = 1
			}
			END { exit !(job_ok && batch_ok) }
		' "$output_file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_reconfigure()
{
	previous_start=$1
	output_file=$2
	attempt=0
	stable_count=0
	observed_start=
	while [ "$attempt" -lt 180 ]; do
		if "$scontrol" show node "$node_name" >"$output_file" 2>/dev/null; then
			state=$(node_field State "$output_file")
			candidate_start=$(node_field SlurmdStartTime "$output_file")
			if [ "$state" = IDLE ] && [ -n "$candidate_start" ] && \
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

restore_config()
{
	[ "$config_modified" -eq 1 ] || return 0
	/usr/bin/printf 'restore production_config=%s\n' "$slurm_conf" >&2
	/bin/cp "$backup_conf" "$slurm_conf" || return 1
	"$scontrol" reconfigure >"${run_dir}/reconfigure-restore.out" \
		2>"${run_dir}/reconfigure-restore.err" || return 1
	if ! restored_start=$(wait_reconfigure "$active_start" \
		"${run_dir}/node-restored.txt"); then
		return 1
	fi
	if ! /usr/bin/cmp -s "$backup_conf" "$slurm_conf"; then
		return 1
	fi
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
		/usr/bin/printf 'recovery: inspect run_dir=%s; do not RESUME a DRAIN node before reviewing hook errors\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

submit_job()
{
	job_name=$1
	script_path=$2
	stdout_path=$3
	stderr_path=$4
	(
		cd /tmp || exit 1
		/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
			SLURM_CONF="$slurm_conf" \
			"$sbatch" --parsable --partition="$partition" \
			--nodes=1 --ntasks=1 --cpus-per-task=1 --mem=256M \
			--time=00:01:00 --chdir=/tmp --job-name="$job_name" \
			--output="$stdout_path" --error="$stderr_path" \
			"$script_path"
	)
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$slurmd" "$scontrol" "$squeue" \
	"$sbatch" "$scancel" "$sacct" "$pid_file" "$production_log" \
	"${source_root}/contribs/macos-tests/smd120_prolog.sh" \
	"${source_root}/contribs/macos-tests/smd120_epilog.sh" \
	"${source_root}/contribs/macos-tests/smd120_payload.sh"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$hook_dir" || fail 'cannot create run directories'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
/bin/cp "${source_root}/contribs/macos-tests/smd120_prolog.sh" \
	"${hook_dir}/prolog.sh" || fail 'cannot stage prolog'
/bin/cp "${source_root}/contribs/macos-tests/smd120_epilog.sh" \
	"${hook_dir}/epilog.sh" || fail 'cannot stage epilog'
/bin/cp "${source_root}/contribs/macos-tests/smd120_payload.sh" \
	"${run_dir}/payload.sh" || fail 'cannot stage payload'
/bin/chmod 0555 "${hook_dir}/prolog.sh" "${hook_dir}/epilog.sh" \
	"${run_dir}/payload.sh" || fail 'cannot set executable modes'
/usr/sbin/chown 0:0 "${hook_dir}/prolog.sh" "${hook_dir}/epilog.sh" \
	"${run_dir}/payload.sh" || fail 'cannot set staged owners'
: >"$event_log" || fail 'cannot create hook event log'
/bin/chmod 0600 "$event_log" || fail 'cannot protect hook event log'
/usr/sbin/chown 0:0 "$event_log" || fail 'cannot set hook event log owner'
/usr/bin/printf 'run_dir=%s\n' "$run_dir"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || \
	fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || \
	fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || \
	fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || \
	fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || \
	fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || \
	fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'

old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$old_pid" ;;
esac
/bin/kill -0 "$old_pid" >/dev/null 2>&1 || fail "slurmd pid=$old_pid is not running"
before_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")
production_log_start=$(/usr/bin/wc -l <"$production_log" | /usr/bin/tr -d ' ')

if /usr/bin/grep -Eq '^[[:space:]]*(Prolog|Epilog)[[:space:]]*=' \
	"$slurm_conf"; then
	fail 'production config already has Prolog or Epilog; refusing to replace them'
fi
if /usr/bin/grep -Eq '^[[:space:]]*(PrologTimeout|EpilogTimeout)[[:space:]]*=' \
	"$slurm_conf"; then
	fail 'individual PrologTimeout/EpilogTimeout is configured; review effective timeout before testing'
fi
if [ "$(/usr/bin/grep -Ec '^[[:space:]]*PrologEpilogTimeout[[:space:]]*=' "$slurm_conf")" -ne 1 ]; then
	fail 'expected exactly one existing PrologEpilogTimeout setting'
fi
hook_timeout=$(/usr/bin/awk -F= '
	/^[[:space:]]*PrologEpilogTimeout[[:space:]]*=/ {
		value = $2
		gsub(/[[:space:]]/, "", value)
		print value
		exit
	}' "$slurm_conf")
case "$hook_timeout" in
''|*[!0-9]*) fail "invalid PrologEpilogTimeout=$hook_timeout" ;;
esac
if [ "$hook_timeout" -lt 1 ] || [ "$hook_timeout" -gt 300 ]; then
	fail "PrologEpilogTimeout=$hook_timeout is outside the test safety range 1..300 seconds"
fi
/usr/bin/printf 'existing_hook_timeout_seconds=%s\n' "$hook_timeout"

/bin/cp -p "$slurm_conf" "$backup_conf" || fail 'cannot back up slurm.conf'
/bin/cp "$backup_conf" "$candidate_conf" || fail 'cannot create candidate config'
{
	/usr/bin/printf '\n# SMD-120 temporary normal-path hook test\n'
	/usr/bin/printf 'Prolog=%s\n' "${hook_dir}/prolog.sh"
	/usr/bin/printf 'Epilog=%s\n' "${hook_dir}/epilog.sh"
} >>"$candidate_conf" || fail 'cannot append candidate hook settings'

"$slurmd" -C -f "$candidate_conf" >"${run_dir}/candidate-parse.txt" \
	2>"${run_dir}/candidate-parse.err" || fail 'candidate configuration did not parse'
/usr/bin/shasum -a 256 "$backup_conf" >"${run_dir}/config-before.sha256"
/usr/bin/shasum -a 256 "$candidate_conf" >"${run_dir}/config-candidate.sha256"

/bin/cp "$candidate_conf" "$slurm_conf" || fail 'cannot apply candidate config'
config_modified=1
"$scontrol" reconfigure >"${run_dir}/reconfigure-apply.out" \
	2>"${run_dir}/reconfigure-apply.err" || fail 'candidate reconfigure failed'
active_start=$(wait_reconfigure "$before_start" "${run_dir}/node-active.txt") || \
	fail 'worker did not become stably IDLE with candidate config'
[ "$(/bin/cat "$pid_file")" = "$old_pid" ] || fail 'slurmd PID changed during reconfigure'
/bin/kill -0 "$old_pid" >/dev/null 2>&1 || fail 'slurmd exited during reconfigure'
/usr/bin/printf 'hook_config_active slurmd_pid=%s old_start=%s new_start=%s\n' \
	"$old_pid" "$before_start" "$active_start"

test_result=$(submit_job smd120-normal "${run_dir}/payload.sh" \
	"${output_dir}/smd120-%j.out" "${output_dir}/smd120-%j.err") || \
	fail 'SMD-120 job submission failed'
test_job=${test_result%%;*}
/usr/bin/printf 'submitted test_job=%s\n' "$test_job"
wait_job_gone "$test_job" || fail "job $test_job did not leave queue"
wait_accounting_complete "$test_job" "${run_dir}/test-sacct.txt" || \
	fail "job $test_job accounting did not reach COMPLETED 0:0"

test_stdout=${output_dir}/smd120-${test_job}.out
test_stderr=${output_dir}/smd120-${test_job}.err
[ -f "$test_stdout" ] || fail 'test stdout is missing'
[ -f "$test_stderr" ] || fail 'test stderr is missing'
[ ! -s "$test_stderr" ] || fail 'test stderr is not empty'

prolog_count=$(/usr/bin/grep -Ec "^event=prolog job_id=${test_job} " "$event_log" || true)
epilog_count=$(/usr/bin/grep -Ec "^event=epilog job_id=${test_job} " "$event_log" || true)
[ "$prolog_count" -eq 1 ] || fail "prolog count=$prolog_count, expected 1"
[ "$epilog_count" -eq 1 ] || fail "epilog count=$epilog_count, expected 1"

prolog_epoch=$(/usr/bin/awk -v job="$test_job" '
	$1 == "event=prolog" && $2 == "job_id=" job {
		sub(/^epoch=/, "", $3); print $3; exit
	}' "$event_log")
epilog_epoch=$(/usr/bin/awk -v job="$test_job" '
	$1 == "event=epilog" && $2 == "job_id=" job {
		sub(/^epoch=/, "", $3); print $3; exit
	}' "$event_log")
payload_begin=$(/usr/bin/awk -v job="$test_job" '
	$1 == "payload_event=begin" && $2 == "job_id=" job {
		sub(/^epoch=/, "", $3); print $3; exit
	}' "$test_stdout")
payload_end=$(/usr/bin/awk -v job="$test_job" '
	$1 == "payload_event=end" && $2 == "job_id=" job {
		sub(/^epoch=/, "", $3); print $3; exit
	}' "$test_stdout")

for measured_epoch in "$prolog_epoch" "$payload_begin" "$payload_end" "$epilog_epoch"; do
	case "$measured_epoch" in
	''|*[!0-9]*) fail 'missing or invalid lifecycle timestamp' ;;
	esac
done
[ "$prolog_epoch" -le "$payload_begin" ] || fail 'prolog ran after payload began'
[ "$payload_begin" -le "$payload_end" ] || fail 'payload timestamps are reversed'
[ "$payload_end" -le "$epilog_epoch" ] || fail 'epilog ran before payload ended'

/usr/bin/grep -Eq "^event=prolog job_id=${test_job} epoch=[0-9]+ euid=0 egid=0 context=prolog_slurmd$" \
	"$event_log" || fail 'prolog identity/context mismatch'
/usr/bin/grep -Eq "^event=epilog job_id=${test_job} epoch=[0-9]+ euid=0 egid=0 context=epilog_slurmd$" \
	"$event_log" || fail 'epilog identity/context mismatch'
/usr/bin/grep -Eq "^payload_event=begin job_id=${test_job} epoch=[0-9]+ euid=${test_uid} egid=${test_gid}$" \
	"$test_stdout" || fail 'payload identity mismatch'
[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$event_log")" = 0:0:600 ] || \
	fail 'hook event log owner or mode mismatch'
/usr/bin/printf 'lifecycle=PASS job_id=%s order=prolog,payload,epilog hook_identity=0:0\n' \
	"$test_job"

restore_config || fail 'production configuration restore failed'

smoke_result=$(submit_job smd120-post-restore "${run_dir}/payload.sh" \
	"${output_dir}/smoke-%j.out" "${output_dir}/smoke-%j.err") || \
	fail 'post-restore smoke submission failed'
smoke_job=${smoke_result%%;*}
/usr/bin/printf 'submitted smoke_job=%s\n' "$smoke_job"
wait_job_gone "$smoke_job" || fail "smoke job $smoke_job did not leave queue"
wait_accounting_complete "$smoke_job" "${run_dir}/smoke-sacct.txt" || \
	fail "smoke job $smoke_job accounting did not reach COMPLETED 0:0"
if /usr/bin/grep -Eq "job_id=${smoke_job}([[:space:]]|$)" "$event_log"; then
	fail 'restored config still executed SMD-120 hook for smoke job'
fi

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || \
	fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final node queue is not empty'

log_first=$((production_log_start + 1))
/usr/bin/sed -n "${log_first},\$p" "$production_log" \
	>"${run_dir}/slurmd-during-test.log"
/usr/bin/shasum -a 256 "$slurm_conf" >"${run_dir}/config-restored.sha256"
/usr/bin/cmp -s "$backup_conf" "$slurm_conf" || fail 'final config is not byte-for-byte restored'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD120_ROOT_RUN_COMPLETE test_job=%s smoke_job=%s slurmd_pid=%s run_dir=%s\n' \
	"$test_job" "$smoke_job" "$old_pid" "$run_dir"
