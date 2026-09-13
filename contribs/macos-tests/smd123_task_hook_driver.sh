#!/bin/sh

set -u

if [ "${SMD123_TASK_HOOK_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf 'error: set SMD123_TASK_HOOK_CONFIRMED=YES after confirming PC-210 is idle\n' >&2
	exit 64
fi

source_root=/Users/REDACTED_USER/dev/slurm.26-05
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
task_count=2
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd123-${run_stamp}
hook_dir=${run_dir}/hooks
event_dir=${run_dir}/events
payload_dir=${run_dir}/payloads
output_dir=${run_dir}/output
backup_conf=${run_dir}/slurm.conf.before
candidate_conf=${run_dir}/slurm.conf.smd123
client_conf=${run_dir}/slurm-client.conf
payload=${run_dir}/task-payload.sh
smoke_script=${run_dir}/smoke.sh
test_job=
smoke_job=
config_modified=0
success=0
old_pid=
before_start=
active_start=
node_ipv4=

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
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
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

accounting_complete_srun()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList >"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { job_ok = 1 }
		$1 == job ".0" && $3 == "COMPLETED" && $4 == "0:0" { step_ok = 1 }
		END { exit !(job_ok && step_ok) }
	' "$file"
}

accounting_complete_batch()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList >"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { job_ok = 1 }
		$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" { batch_ok = 1 }
		END { exit !(job_ok && batch_ok) }
	' "$file"
}

wait_batch_accounting()
{
	job_id=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if accounting_complete_batch "$job_id" "$file"; then
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
		/usr/bin/printf 'recovery: inspect run_dir=%s; production config restore was attempted\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$slurmd" "$scontrol" "$squeue" \
	"$srun" "$sbatch" "$scancel" "$sacct" "$pid_file" \
	"${source_root}/contribs/macos-tests/smd123_task_prolog.sh" \
	"${source_root}/contribs/macos-tests/smd123_task_epilog.sh" \
	"${source_root}/contribs/macos-tests/smd123_task_payload.sh"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$hook_dir" || fail 'cannot create run directories'
/bin/mkdir -m 0700 "$event_dir" "$payload_dir" "$output_dir" || fail 'cannot create user directories'
/usr/sbin/chown "$test_uid:$test_gid" "$event_dir" "$payload_dir" "$output_dir" || \
	fail 'cannot chown user directories'
/bin/cp "${source_root}/contribs/macos-tests/smd123_task_prolog.sh" \
	"${hook_dir}/task-prolog.sh" || fail 'cannot stage TaskProlog'
/bin/cp "${source_root}/contribs/macos-tests/smd123_task_epilog.sh" \
	"${hook_dir}/task-epilog.sh" || fail 'cannot stage TaskEpilog'
/bin/cp "${source_root}/contribs/macos-tests/smd123_task_payload.sh" "$payload" || \
	fail 'cannot stage payload'
/bin/chmod 0555 "${hook_dir}/task-prolog.sh" "${hook_dir}/task-epilog.sh" \
	"$payload" || fail 'cannot set executable modes'
/usr/sbin/chown 0:0 "${hook_dir}/task-prolog.sh" "${hook_dir}/task-epilog.sh" \
	"$payload" || fail 'cannot set staged owners'
{
	/usr/bin/printf '#!/bin/sh\n'
	/usr/bin/printf 'exit 0\n'
} >"$smoke_script" || fail 'cannot create smoke script'
/bin/chmod 0555 "$smoke_script" || fail 'cannot set smoke mode'
/usr/sbin/chown 0:0 "$smoke_script" || fail 'cannot set smoke owner'
/usr/bin/printf 'run_dir=%s task_count=%s\n' "$run_dir" "$task_count"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
before_state=$(node_field State "${run_dir}/node-before.txt")
[ "$before_state" = IDLE ] || fail "node state is $before_state, expected IDLE"
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'

old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$old_pid" ;;
esac
/bin/kill -0 "$old_pid" >/dev/null 2>&1 || fail "slurmd pid=$old_pid is not running"
before_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")
node_ipv4=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || true)
case "$node_ipv4" in
''|*[!0-9.]*) fail "invalid en0 IPv4 address=$node_ipv4" ;;
esac
/usr/bin/dscacheutil -q host -a name "${node_name}.local" \
	>"${run_dir}/node-address-readback.txt" 2>"${run_dir}/node-address-readback.err" || \
	fail "cannot resolve ${node_name}.local"
/usr/bin/grep -Fqx "ip_address: ${node_ipv4}" "${run_dir}/node-address-readback.txt" || \
	fail "${node_name}.local does not resolve to en0 address $node_ipv4"

if /usr/bin/grep -Eq '^[[:space:]]*(TaskProlog|TaskEpilog)[[:space:]]*=' "$slurm_conf"; then
	fail 'production config already has TaskProlog/TaskEpilog; refusing to replace them'
fi

/bin/cp -p "$slurm_conf" "$backup_conf" || fail 'cannot back up slurm.conf'
/bin/cp "$backup_conf" "$candidate_conf" || fail 'cannot create candidate config'
{
	/usr/bin/printf '\n# SMD-123 temporary per-task hook test\n'
	/usr/bin/printf 'TaskProlog=%s\n' "${hook_dir}/task-prolog.sh"
	/usr/bin/printf 'TaskEpilog=%s\n' "${hook_dir}/task-epilog.sh"
} >>"$candidate_conf" || fail 'cannot append task hook settings'

"$slurmd" -C -f "$candidate_conf" >"${run_dir}/candidate-parse.txt" \
	2>"${run_dir}/candidate-parse.err" || fail 'candidate configuration did not parse'
/usr/bin/awk -v node="$node_name" -v addr="$node_ipv4" '
	$1 == "NodeName=" node {
		for (i = 1; i <= NF; i++)
			if ($i ~ /^NodeAddr=/)
				found_addr = 1
		if (!found_addr)
			$0 = $0 " NodeAddr=" addr
		found_node = 1
	}
	{ print }
	END { if (!found_node) exit 1 }
' "$candidate_conf" >"$client_conf" || fail 'cannot create numeric NodeAddr client config'
/bin/chmod 0644 "$client_conf" || fail 'cannot set client config mode'
"$slurmd" -C -f "$client_conf" >"${run_dir}/client-parse.txt" \
	2>"${run_dir}/client-parse.err" || fail 'numeric NodeAddr client configuration did not parse'
/usr/bin/shasum -a 256 "$backup_conf" >"${run_dir}/config-before.sha256"
/usr/bin/shasum -a 256 "$candidate_conf" >"${run_dir}/config-candidate.sha256"
/usr/bin/shasum -a 256 "$client_conf" >"${run_dir}/config-client.sha256"

/bin/cp "$candidate_conf" "$slurm_conf" || fail 'cannot apply candidate config'
config_modified=1
"$scontrol" reconfigure >"${run_dir}/reconfigure-apply.out" \
	2>"${run_dir}/reconfigure-apply.err" || fail 'candidate reconfigure failed'
active_start=$(wait_reconfigure "$before_start" "${run_dir}/node-active.txt") || \
	fail 'worker did not become stably IDLE with task hooks'
[ "$(/bin/cat "$pid_file")" = "$old_pid" ] || fail 'slurmd PID changed during reconfigure'
/usr/bin/printf 'task_hook_config_active slurmd_pid=%s old_start=%s new_start=%s\n' \
	"$old_pid" "$before_start" "$active_start"
/usr/bin/printf 'client_node_addr=%s client_config=%s\n' "$node_ipv4" "$client_conf"

set +e
/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
	SLURM_CONF="$client_conf" \
	SMD123_EVENT_DIR="$event_dir" \
	SMD123_PAYLOAD_DIR="$payload_dir" \
	SMD123_SHOULD_BE_UNSET=present \
	"$srun" --partition="$partition" --nodes=1 --ntasks="$task_count" \
	--cpus-per-task=1 --mem=256M --time=00:01:00 --chdir=/tmp \
	--job-name=smd123-task-hooks --kill-on-bad-exit=1 "$payload" \
	>"${run_dir}/srun.out" 2>"${run_dir}/srun.err"
srun_rc=$?
set -e
/usr/bin/printf 'srun_rc=%s\n' "$srun_rc"
[ "$srun_rc" -eq 0 ] || fail "task-hook srun failed rc=$srun_rc"

payload_count=$(/usr/bin/find "$payload_dir" -type f -name 'payload.*.txt' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
[ "$payload_count" = "$task_count" ] || fail "unexpected payload file count=$payload_count"
test_job=$(/usr/bin/awk '
	{
		for (i = 1; i <= NF; i++) if ($i ~ /^job_id=/) {
			sub(/^job_id=/, "", $i); print $i
		}
	}' "${payload_dir}"/payload.*.txt | /usr/bin/sort -u)
case "$test_job" in
''|*[!0-9]*) fail "invalid or non-unique test job id=$test_job" ;;
esac

for proc_id in 0 1; do
	prolog_file=${event_dir}/prolog.${test_job}.0.${proc_id}.txt
	payload_file=${payload_dir}/payload.${test_job}.0.${proc_id}.txt
	epilog_file=${event_dir}/epilog.${test_job}.0.${proc_id}.txt
	[ -f "$prolog_file" ] || fail "missing $prolog_file"
	[ -f "$payload_file" ] || fail "missing $payload_file"
	[ -f "$epilog_file" ] || fail "missing $epilog_file"
	/usr/bin/grep -Eq "^event=task_prolog job_id=${test_job} step_id=0 procid=${proc_id} localid=${proc_id} euid=${test_uid} egid=${test_gid} context=prolog_task task_pid=[0-9]+$" \
		"$prolog_file" || fail "TaskProlog event mismatch procid=$proc_id"
	/usr/bin/grep -Fqx "event=payload job_id=${test_job} step_id=0 procid=${proc_id} localid=${proc_id} euid=${test_uid} egid=${test_gid} prolog_value=job_${test_job}_step_0_proc_${proc_id} unset_verified=YES" \
		"$payload_file" || fail "payload environment mismatch procid=$proc_id"
	/usr/bin/grep -Fqx "event=task_epilog job_id=${test_job} step_id=0 procid=${proc_id} localid=${proc_id} euid=${test_uid} egid=${test_gid} context=epilog_task payload_seen=YES" \
		"$epilog_file" || fail "TaskEpilog event mismatch procid=$proc_id"
done

prolog_count=$(/usr/bin/find "$event_dir" -type f -name 'prolog.*.txt' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
epilog_count=$(/usr/bin/find "$event_dir" -type f -name 'epilog.*.txt' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
print_count=$(/usr/bin/grep -c '^SMD123_TASK_PROLOG_PRINT ' "${run_dir}/srun.out" || true)
[ "$prolog_count" = "$task_count" ] || fail "unexpected TaskProlog count=$prolog_count"
[ "$epilog_count" = "$task_count" ] || fail "unexpected TaskEpilog count=$epilog_count"
[ "$print_count" = "$task_count" ] || fail "unexpected TaskProlog print count=$print_count"
accounting_complete_srun "$test_job" "${run_dir}/test-sacct.txt" || \
	fail 'srun job/step accounting did not reach COMPLETED 0:0'
/usr/bin/printf 'task_lifecycle=PASS job_id=%s tasks=%s prolog=%s payload=%s epilog=%s user=%s:%s environment=PASS\n' \
	"$test_job" "$task_count" "$prolog_count" "$payload_count" "$epilog_count" \
	"$test_uid" "$test_gid"

restore_config || fail 'production configuration restore failed'

smoke_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=128M --time=00:01:00 --chdir=/tmp \
		--job-name=smd123-smoke --output="${output_dir}/smoke-%j.out" \
		--error="${output_dir}/smoke-%j.err" "$smoke_script"
) || fail 'post-restore smoke submission failed'
smoke_job=${smoke_job%%;*}
/usr/bin/printf 'submitted smoke_job=%s\n' "$smoke_job"
wait_job_gone "$smoke_job" || fail 'post-restore smoke did not leave queue'
wait_batch_accounting "$smoke_job" "${run_dir}/smoke-sacct.txt" || \
	fail 'post-restore smoke accounting did not reach COMPLETED 0:0'

[ "$prolog_count" = "$(/usr/bin/find "$event_dir" -type f -name 'prolog.*.txt' | /usr/bin/wc -l | /usr/bin/tr -d ' ')" ] || \
	fail 'TaskProlog executed after production config restore'
[ "$epilog_count" = "$(/usr/bin/find "$event_dir" -type f -name 'epilog.*.txt' | /usr/bin/wc -l | /usr/bin/tr -d ' ')" ] || \
	fail 'TaskEpilog executed after production config restore'

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final node queue is not empty'
/usr/bin/cmp -s "$backup_conf" "$slurm_conf" || fail 'final config is not byte-for-byte restored'
/usr/bin/shasum -a 256 "$slurm_conf" >"${run_dir}/config-restored.sha256"

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD123_ROOT_RUN_COMPLETE test_job=%s smoke_job=%s tasks=%s slurmd_pid=%s run_dir=%s\n' \
	"$test_job" "$smoke_job" "$task_count" "$old_pid" "$run_dir"
