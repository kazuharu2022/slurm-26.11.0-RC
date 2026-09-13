#!/bin/sh

set -u

if [ "${SMD306_PROC_ABSENCE_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD306_PROC_ABSENCE_CONFIRMED=YES after accepting 15 jobs' >&2
	exit 64
fi

source_root=/Users/REDACTED_USER/dev/slurm.26-05
source_dir=${source_root}/contribs/macos-tests
source_payload=${source_dir}/smd306_proc_absence_payload.sh
source_driver=${source_dir}/smd306_proc_absence_driver.sh
source_req=${source_root}/src/slurmd/slurmstepd/req.c
source_oom=${source_root}/src/slurmd/common/set_oomadj.c
source_proctrack=${source_root}/src/plugins/proctrack/pgid/proctrack_pgid.c
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
slurmd_log=/var/log/slurm/slurmd.log
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
normal_count=12
cancel_count=3
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd306-${run_stamp}
input_dir=${run_dir}/input
output_dir=${run_dir}/output
record_dir=${run_dir}/records
evidence_dir=${run_dir}/evidence
payload=${input_dir}/payload.sh
active_jobs=${run_dir}/active-jobs.txt
expected_jobs=${run_dir}/expected-jobs.tsv
slurmd_pid=
slurmd_start=
log_start_line=1
success=0

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

record_field()
{
	field=$1
	file=$2
	/usr/bin/awk -F '=' -v key="$field" '$1 == key { print $2; exit }' "$file"
}

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }'
}

wait_job_running()
{
	target=$1
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		state=$(queue_state "$target")
		[ "$state" = RUNNING ] && return 0
		[ -n "$state" ] || return 1
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_job_gone()
{
	target=$1
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		if [ -z "$(queue_state "$target")" ]; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

process_exists()
{
	/bin/ps -p "$1" -o pid= >/dev/null 2>&1
}

wait_process_gone()
{
	target=$1
	attempt=0
	while [ "$attempt" -lt 100 ]; do
		process_exists "$target" || return 0
		/bin/sleep 0.1
		attempt=$((attempt + 1))
	done
	return 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ -f "$active_jobs" ]; then
		while IFS= read -r job; do
			case "$job" in
			''|*[!0-9]*) continue ;;
			esac
			state=$(queue_state "$job")
			if [ -n "$state" ]; then
				/usr/bin/printf 'cleanup job_id=%s state=%s\n' \
					"$job" "$state" >&2
				"$scancel" "$job" >/dev/null 2>&1 || true
			fi
		done <"$active_jobs"
	fi
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf '%s\n' \
			"recovery: production was not changed; inspect run_dir=$run_dir" >&2
	fi
	exit "$rc"
}

submit_job()
{
	mode=$1
	sequence=$2
	oom_value=$3
	submit_err=${evidence_dir}/submit-${mode}-${sequence}.err
	if [ "$oom_value" = UNSET ]; then
		export_arg=NONE
	else
		export_arg=SLURMSTEPD_OOM_ADJ=${oom_value}
	fi
	job=$(
		cd /tmp || exit 1
		/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
			"SLURM_CONF=${slurm_conf}" "$sbatch" --parsable \
			"--export=${export_arg}" --partition="$partition" \
			--nodes=1 --ntasks=1 --cpus-per-task=1 --mem=64M \
			--time=00:02:00 --chdir=/tmp \
			--job-name="smd306-${mode}-${sequence}" \
			--output="${output_dir}/%j.out" \
			--error="${output_dir}/%j.err" \
			"$payload" "$mode" "$sequence" "$record_dir" \
			2>"$submit_err"
	) || return 1
	job=${job%%;*}
	case "$job" in
	''|*[!0-9]*) return 1 ;;
	esac
	[ ! -s "$submit_err" ] || return 1
	/usr/bin/printf '%s\n' "$job" >>"$active_jobs"
	/usr/bin/printf '%s\t%s\t%s\t%s\n' \
		"$job" "$mode" "$sequence" "$oom_value" >>"$expected_jobs"
	/usr/bin/printf '%s\n' "$job"
}

accounting_valid()
{
	file=$1
	/usr/bin/awk -F '|' '
	FNR == NR {
		split($0, f, "\t")
		expected[f[1]] = f[2]
		count++
		next
	}
	{
		id = $1
		if (id in expected) {
			root_seen[id] = 1
			if ($2 != "testuser") bad = 1
			if (expected[id] == "normal" &&
			    ($3 != "COMPLETED" || $4 != "0:0")) bad = 1
			if (expected[id] == "cancel" &&
			    index($3, "CANCELLED") != 1) bad = 1
			next
		}
		parent = id
		sub(/\.batch$/, "", parent)
		if ((parent in expected) && id == parent ".batch") {
			batch_seen[parent] = 1
			if (expected[parent] == "normal" &&
			    ($3 != "COMPLETED" || $4 != "0:0")) bad = 1
			if (expected[parent] == "cancel" &&
			    index($3, "CANCELLED") != 1) bad = 1
		}
	}
	END {
		for (id in expected) {
			if (!root_seen[id] || !batch_seen[id]) bad = 1
		}
		exit bad || count == 0
	}' "$expected_jobs" "$file"
}

wait_accounting()
{
	ids=$(/usr/bin/paste -sd, "$active_jobs")
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		"$sacct" -j "$ids" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList,AllocTRES \
			>"${evidence_dir}/accounting.txt" \
			2>"${evidence_dir}/accounting.err" || true
		accounting_valid "${evidence_dir}/accounting.txt" && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for macOS'

for required_file in "$source_payload" "$source_driver" "$source_req" \
	"$source_oom" "$source_proctrack" "$slurm_conf" "$scontrol" \
	"$squeue" "$sbatch" "$scancel" "$sacct" "$pid_file" "$slurmd_log"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
[ ! -e /proc ] || fail '/proc unexpectedly exists; this is not the target host state'
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$input_dir" "$evidence_dir" || \
	fail 'cannot create test directories'
/bin/mkdir -m 0700 "$output_dir" "$record_dir" || \
	fail 'cannot create user directories'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" "$record_dir" || \
	fail 'cannot set user directory ownership'
/bin/cp "$source_payload" "$payload" || fail 'cannot stage payload'
/bin/chmod 0555 "$payload" || fail 'cannot set payload mode'
/usr/sbin/chown 0:0 "$payload" || fail 'cannot set payload owner'
: >"$active_jobs"
: >"$expected_jobs"
/usr/bin/printf 'run_dir=%s normal_jobs=%s cancel_jobs=%s proc=ABSENT\n' \
	"$run_dir" "$normal_count" "$cancel_count"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${evidence_dir}/controller-before.txt" 2>&1 || \
	fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${evidence_dir}/controller-before.txt" || \
	fail 'controller is not UP'
"$scontrol" show config >"${evidence_dir}/config-before.txt" || \
	fail 'cannot read effective config'
"$scontrol" show node "$node_name" >"${evidence_dir}/node-before.txt" || \
	fail 'cannot read node state'
[ "$(node_field State "${evidence_dir}/node-before.txt")" = IDLE ] || \
	fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${evidence_dir}/node-before.txt")" = 0 ] || \
	fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${evidence_dir}/node-before.txt")" = 0 ] || \
	fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'node has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${evidence_dir}/stepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi
/usr/bin/grep -Eq '^[[:space:]]*ProctrackType=proctrack/pgid([[:space:]]|$)' \
	"$slurm_conf" || fail 'worker is not configured for proctrack/pgid'
/usr/bin/grep -Eq '^[[:space:]]*JobAcctGatherType=jobacct_gather/none([[:space:]]|$)' \
	"$slurm_conf" || fail 'worker is not configured for jobacct_gather/none'

slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail 'slurmd is not running'
slurmd_start=$(node_field SlurmdStartTime "${evidence_dir}/node-before.txt")
log_start_line=$(( $(/usr/bin/wc -l <"$slurmd_log") + 1 ))
/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" "$source_driver" \
	"$source_req" "$source_oom" "$source_proctrack" \
	>"${evidence_dir}/inputs-before.sha256"

sequence=1
while [ "$sequence" -le "$normal_count" ]; do
	case $((sequence % 4)) in
	1) oom_value=UNSET ;;
	2) oom_value=-1000 ;;
	3) oom_value=0 ;;
	0) oom_value=1000 ;;
	esac
	job_id=$(submit_job normal "$sequence" "$oom_value") || \
		fail "normal submit failed sequence=$sequence"
	/usr/bin/printf 'submitted mode=normal sequence=%s job_id=%s oom=%s\n' \
		"$sequence" "$job_id" "$oom_value"
	wait_job_gone "$job_id" || fail "normal job remained job_id=$job_id"
	stdout=${output_dir}/${job_id}.out
	stderr=${output_dir}/${job_id}.err
	[ -f "$stdout" ] || fail "normal stdout missing job_id=$job_id"
	[ -f "$stderr" ] || fail "normal stderr missing job_id=$job_id"
	[ ! -s "$stderr" ] || fail "normal stderr is not empty job_id=$job_id"
	/usr/bin/grep -Fqx 'proc_state=ABSENT' "$stdout" || \
		fail "normal proc observation mismatch job_id=$job_id"
	/usr/bin/grep -Fqx "oom_adj=${oom_value}" "$stdout" || \
		fail "normal OOM environment mismatch job_id=$job_id"
	/usr/bin/grep -Fq 'SMD306_PAYLOAD_PASS ' "$stdout" || \
		fail "normal payload marker missing job_id=$job_id"
	sequence=$((sequence + 1))
done
/usr/bin/printf 'normal_phase=PASS jobs=%s oom_values=UNSET,-1000,0,1000\n' \
	"$normal_count"

sequence=1
while [ "$sequence" -le "$cancel_count" ]; do
	job_id=$(submit_job cancel "$sequence" 0) || \
		fail "cancel submit failed sequence=$sequence"
	/usr/bin/printf 'submitted mode=cancel sequence=%s job_id=%s\n' \
		"$sequence" "$job_id"
	wait_job_running "$job_id" || fail "cancel job did not run job_id=$job_id"
	ready=${record_dir}/cancel-${sequence}-ready.txt
	child=${record_dir}/cancel-${sequence}-child.txt
	attempt=0
	while [ "$attempt" -lt 100 ]; do
		[ -s "$ready" ] && [ -s "$child" ] && break
		[ "$(queue_state "$job_id")" = RUNNING ] || \
			fail "cancel fixture ended early job_id=$job_id"
		/bin/sleep 0.1
		attempt=$((attempt + 1))
	done
	[ -s "$ready" ] && [ -s "$child" ] || \
		fail "cancel fixture not ready job_id=$job_id"
	coordinator_pid=$(record_field coordinator_pid "$ready")
	child_pid=$(record_field child_pid "$ready")
	sibling_pid=$(record_field sibling_pid "$ready")
	grandchild_pid=$(record_field grandchild_pid "$child")
	for pid in "$coordinator_pid" "$child_pid" "$sibling_pid" \
		"$grandchild_pid"; do
		case "$pid" in
		''|*[!0-9]*) fail "invalid fixture pid=$pid job_id=$job_id" ;;
		esac
		process_exists "$pid" || fail "fixture pid missing pid=$pid job_id=$job_id"
	done
	/bin/ps -p "$coordinator_pid,$child_pid,$sibling_pid,$grandchild_pid" \
		-o pid=,uid=,ppid=,pgid=,state=,command= \
		>"${evidence_dir}/cancel-${sequence}-processes-before.txt" || \
		fail "cannot capture cancel process tree job_id=$job_id"
	process_count=$(/usr/bin/wc -l \
		<"${evidence_dir}/cancel-${sequence}-processes-before.txt" |
		/usr/bin/tr -d ' ')
	[ "$process_count" = 4 ] || \
		fail "cancel process count mismatch job_id=$job_id"
	/usr/bin/awk -v uid="$test_uid" '
		$2 != uid || $5 ~ /^Z/ { bad = 1 }
		NR == 1 { pgid = $4 }
		$4 != pgid { bad = 1 }
		END { exit bad || NR != 4 }
	' "${evidence_dir}/cancel-${sequence}-processes-before.txt" || \
		fail "cancel process identity or PGID mismatch job_id=$job_id"
	"$scancel" "$job_id" || fail "cancel request failed job_id=$job_id"
	wait_job_gone "$job_id" || fail "cancel job remained job_id=$job_id"
	for pid in "$coordinator_pid" "$child_pid" "$sibling_pid" \
		"$grandchild_pid"; do
		wait_process_gone "$pid" || fail "process remains pid=$pid job_id=$job_id"
	done
	stderr=${output_dir}/${job_id}.err
	[ -f "$stderr" ] || fail "cancel stderr missing job_id=$job_id"
	/usr/bin/grep -Fq 'CANCELLED' "$stderr" || \
		fail "cancel evidence missing job_id=$job_id"
	/usr/bin/printf 'cancel_cycle=PASS sequence=%s job_id=%s processes=4\n' \
		"$sequence" "$job_id"
	sequence=$((sequence + 1))
done

wait_accounting || fail 'aggregate accounting mismatch'

"$scontrol" show node "$node_name" >"${evidence_dir}/node-final.txt" || \
	fail 'cannot read final node state'
[ "$(node_field State "${evidence_dir}/node-final.txt")" = IDLE ] || \
	fail 'final node is not IDLE'
[ "$(node_field CPUAlloc "${evidence_dir}/node-final.txt")" = 0 ] || \
	fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${evidence_dir}/node-final.txt")" = 0 ] || \
	fail 'final AllocMem is not zero'
[ -z "$(node_field AllocTRES "${evidence_dir}/node-final.txt")" ] || \
	fail 'final AllocTRES is not empty'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final queue is not empty'
[ ! -e /proc ] || fail '/proc state changed during test'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed'
[ "$(node_field SlurmdStartTime "${evidence_dir}/node-final.txt")" = \
	"$slurmd_start" ] || fail 'SlurmdStartTime changed'
if /usr/bin/pgrep -x slurmstepd >"${evidence_dir}/stepd-final.txt" 2>/dev/null; then
	fail 'slurmstepd remains after test'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= \
	>"${evidence_dir}/processes-final.txt"
/usr/bin/grep -F "$run_dir" "${evidence_dir}/processes-final.txt" \
	>"${evidence_dir}/residual-processes.txt" || true
[ ! -s "${evidence_dir}/residual-processes.txt" ] || \
	fail 'test payload process remains'

/usr/bin/tail -n "+${log_start_line}" "$slurmd_log" \
	>"${evidence_dir}/slurmd-log-delta.txt"
/usr/bin/printf '%s\n' \
	'/proc/self/oom_(score_adj|adj).*not found' \
	'opendir\(/proc\)' \
	'failed to open /proc' \
	'cannot open /proc' \
	'fatal' \
	'pthread_mutex.*Invalid argument' \
	'Protocol not available' \
	'symbol not found' >"${evidence_dir}/forbidden-patterns.txt"
/usr/bin/grep -Ei \
	-f "${evidence_dir}/forbidden-patterns.txt" \
	"${evidence_dir}/slurmd-log-delta.txt" \
	>"${evidence_dir}/unexpected-errors.txt" || true
[ ! -s "${evidence_dir}/unexpected-errors.txt" ] || \
	fail 'unexpected runtime error found'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" "$source_driver" \
	"$source_req" "$source_oom" "$source_proctrack" \
	>"${evidence_dir}/inputs-after.sha256"
/usr/bin/cmp -s "${evidence_dir}/inputs-before.sha256" \
	"${evidence_dir}/inputs-after.sha256" || fail 'input changed during test'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s%s%s\n' \
	'SMD306_PROC_ABSENCE_COMPLETE' \
	" total_jobs=$((normal_count + cancel_count))" \
	" normal_jobs=$normal_count cancel_jobs=$cancel_count" \
	" process_cleanup=PASS proc_errors=0 slurmd_pid=$slurmd_pid" \
	" production_unchanged=PASS run_dir=$run_dir"
