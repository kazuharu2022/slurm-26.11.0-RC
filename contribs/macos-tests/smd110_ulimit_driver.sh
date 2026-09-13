#!/bin/sh

set -u

if [ "${SMD110_ULIMIT_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD110_ULIMIT_CONFIRMED=YES after accepting two short rlimit probe jobs' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
log_file=/var/log/slurm/slurmd.log
source_dir=/Users/REDACTED_USER/dev/slurm.26-05/contribs/macos-tests
source_probe=${source_dir}/smd110_rlimit_probe.c
source_job=${source_dir}/smd110_rlimit_job.sh
source_submit=${source_dir}/smd110_submit_case.sh
source_driver=${source_dir}/smd110_ulimit_driver.sh
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd110-${run_stamp}
input_dir=${run_dir}/input
cases_dir=${run_dir}/cases
evidence_dir=${run_dir}/evidence
active_job=
completed_jobs=
slurmd_pid=
slurmd_start=
log_size=0
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

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }'
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ -n "$active_job" ]; then
		state=$(queue_state "$active_job")
		if [ -n "$state" ]; then
			/usr/bin/printf 'cleanup job_id=%s state=%s\n' \
				"$active_job" "$state" >&2
			"$scancel" "$active_job" >/dev/null 2>&1 || true
		fi
	fi
	if [ -d "$run_dir" ]; then
		/bin/chmod 0755 "$run_dir" "$input_dir" "$cases_dir" \
			"$evidence_dir" 2>/dev/null || true
		/usr/bin/find "$input_dir" "$evidence_dir" -type f \
			-exec /bin/chmod 0644 {} \; 2>/dev/null || true
	fi
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf '%s\n' \
			"recovery: no production configuration was changed; inspect run_dir=${run_dir}" >&2
	fi
	exit "$rc"
}

wait_job_gone()
{
	job=$1
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		if [ -z "$(queue_state "$job")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' \
				"$job" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

accounting_complete()
{
	job=$1
	file=$2
	"$sacct" -j "$job" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job" -v user="$test_user" '
	$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" {
		root_ok = 1
	}
	$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" {
		batch_ok = 1
	}
	END { exit !(root_ok && batch_ok) }
	' "$file"
}

wait_accounting()
{
	job=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if accounting_complete "$job" "$file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

limit_value()
{
	name=$1
	field=$2
	file=$3
	/usr/bin/awk -v wanted="limit=${name}" -v key="${field}=" '
	$1 == wanted {
		for (i = 2; i <= NF; i++) {
			if (index($i, key) == 1) {
				sub(key, "", $i)
				print $i
				exit
			}
		}
	}' "$file"
}

limit_is_valid()
{
	soft=$1
	hard=$2
	if [ "$soft" = infinity ]; then
		[ "$hard" = infinity ]
		return
	fi
	case "$soft" in
	''|*[!0-9]*) return 1 ;;
	esac
	if [ "$hard" = infinity ]; then
		return 0
	fi
	case "$hard" in
	''|*[!0-9]*) return 1 ;;
	esac
	[ "$soft" -le "$hard" ]
}

validate_probe()
{
	role=$1
	file=$2
	/usr/bin/grep -Fxq 'smd110_schema=1' "$file" || return 1
	/usr/bin/grep -Fxq "role=${role}" "$file" || return 1
	/usr/bin/grep -Fxq 'uid=3001' "$file" || return 1
	/usr/bin/grep -Fxq 'gid=3001' "$file" || return 1
	/usr/bin/grep -Fxq 'slurm_rlimit_env_count=0' "$file" || return 1
	/usr/bin/grep -Fxq "SMD110_PROBE_PASS role=${role}" "$file" || return 1
	for name in CPU CORE STACK NOFILE; do
		[ -n "$(limit_value "$name" soft "$file")" ] || return 1
		[ -n "$(limit_value "$name" hard "$file")" ] || return 1
	done
}

validate_case()
{
	case_name=$1
	mode=$2
	submit_file=$3
	job_file=$4
	validate_probe submit "$submit_file" || return 1
	validate_probe job "$job_file" || return 1
	/usr/bin/grep -Fxq "case=${case_name}" "$job_file" || return 1
	for name in CPU CORE STACK NOFILE; do
		submit_soft=$(limit_value "$name" soft "$submit_file")
		job_soft=$(limit_value "$name" soft "$job_file")
		job_hard=$(limit_value "$name" hard "$job_file")
		[ "$submit_soft" = "$job_soft" ] || return 1
		limit_is_valid "$job_soft" "$job_hard" || return 1
	done
	if [ "$mode" = explicit ]; then
		[ "$(limit_value CPU soft "$job_file")" = 60 ] || return 1
		[ "$(limit_value CORE soft "$job_file")" = 0 ] || return 1
		[ "$(limit_value STACK soft "$job_file")" = 4194304 ] || return 1
		[ "$(limit_value NOFILE soft "$job_file")" = 256 ] || return 1
	fi
}

submit_case()
{
	case_name=$1
	mode=$2
	case_dir=${cases_dir}/${case_name}
	/bin/mkdir -m 0700 "$case_dir" || fail "cannot create case=$case_name"
	/usr/sbin/chown "$test_uid:$test_gid" "$case_dir" ||
		fail "cannot chown case=$case_name"

	active_job=$(
		cd /tmp || exit 1
		/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env -i \
			"HOME=/Users/${test_user}" "USER=${test_user}" \
			"LOGNAME=${test_user}" \
			'PATH=/opt/slurm/26.11.0/bin:/usr/bin:/bin' \
			"SLURM_CONF=${slurm_conf}" /bin/sh "${input_dir}/submit.sh" \
			"$case_name" "$mode" "${input_dir}/rlimit-probe" \
			"${case_dir}/submit-limits.txt" "$sbatch" "$slurm_conf" \
			"$partition" "${case_dir}/slurm-%j.out" \
			"${case_dir}/slurm-%j.err" "${input_dir}/job.sh"
	) || fail "submission failed case=$case_name"
	active_job=${active_job%%;*}
	case "$active_job" in
	''|*[!0-9]*) fail "invalid job id case=$case_name id=$active_job" ;;
	esac
	job=$active_job
	/usr/bin/printf 'submitted case=%s mode=%s job_id=%s\n' \
		"$case_name" "$mode" "$job"
	wait_job_gone "$job" || fail "job remained in queue case=$case_name"
	active_job=

	accounting_file=${evidence_dir}/${case_name}-accounting.txt
	wait_accounting "$job" "$accounting_file" ||
		fail "accounting mismatch case=$case_name job=$job"
	submit_file=${case_dir}/submit-limits.txt
	stdout_file=${case_dir}/slurm-${job}.out
	stderr_file=${case_dir}/slurm-${job}.err
	[ -f "$submit_file" ] || fail "missing submit limits case=$case_name"
	[ -f "$stdout_file" ] || fail "missing stdout case=$case_name"
	[ -f "$stderr_file" ] || fail "missing stderr case=$case_name"
	[ ! -s "$stderr_file" ] || fail "stderr is not empty case=$case_name"
	validate_case "$case_name" "$mode" "$submit_file" "$stdout_file" ||
		fail "rlimit mismatch case=$case_name"
	for path in "$submit_file" "$stdout_file" "$stderr_file"; do
		[ "$(/usr/bin/stat -f '%u:%g' "$path")" = "${test_uid}:${test_gid}" ] ||
			fail "owner mismatch case=$case_name path=$path"
	done
	/bin/cp "$submit_file" "${evidence_dir}/${case_name}-submit.txt" ||
		fail "cannot snapshot submit limits case=$case_name"
	/bin/cp "$stdout_file" "${evidence_dir}/${case_name}-job.txt" ||
		fail "cannot snapshot job limits case=$case_name"
	/bin/cp "$stderr_file" "${evidence_dir}/${case_name}-stderr.txt" ||
		fail "cannot snapshot stderr case=$case_name"
	/usr/bin/stat -f '%N owner=%u:%g mode=%Lp size=%z' \
		"$submit_file" "$stdout_file" "$stderr_file" \
		>"${evidence_dir}/${case_name}-metadata.txt" ||
		fail "cannot save metadata case=$case_name"
	/bin/chmod 0644 "${evidence_dir}/${case_name}-"*.txt ||
		fail "cannot set evidence mode case=$case_name"
	completed_jobs="${completed_jobs}${completed_jobs:+,}${job}"
	/usr/bin/printf 'verified case=%s job_id=%s limits=CPU,CORE,STACK,NOFILE\n' \
		"$case_name" "$job"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for macOS'
for path in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" "$scancel" \
	"$sacct" "$pid_file" "$log_file" "$source_probe" "$source_job" \
	"$source_submit" "$source_driver"; do
	[ -e "$path" ] || fail "missing $path"
done
for command in /usr/bin/awk /usr/bin/clang /usr/bin/diff /usr/bin/find \
	/usr/bin/grep /usr/bin/id /usr/bin/pgrep /usr/bin/shasum /usr/bin/stat \
	/usr/bin/sudo /usr/sbin/chown /bin/cat /bin/chmod /bin/cp /bin/date \
	/bin/kill /bin/mkdir /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$input_dir" "$cases_dir" \
	"$evidence_dir" || fail 'cannot create run directories'
/bin/cp "$source_job" "${input_dir}/job.sh" || fail 'cannot stage job script'
/bin/cp "$source_submit" "${input_dir}/submit.sh" || fail 'cannot stage submit script'
/usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror "$source_probe" \
	-o "${input_dir}/rlimit-probe" >"${run_dir}/clang.out" \
	2>"${run_dir}/clang.err" || fail 'cannot build rlimit probe'
/bin/chmod 0555 "${input_dir}/job.sh" "${input_dir}/submit.sh" \
	"${input_dir}/rlimit-probe" || fail 'cannot set input modes'
trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 ||
	fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" ||
	fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" ||
	fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] ||
	fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] ||
	fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail 'slurmd is not running'
slurmd_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")
log_size=$(/usr/bin/stat -f '%z' "$log_file") || fail 'cannot stat slurmd log'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_probe" "$source_job" \
	"$source_submit" "$source_driver" >"${run_dir}/inputs-before.sha256"
/usr/bin/printf 'run_dir=%s slurmd_pid=%s\n' "$run_dir" "$slurmd_pid"

submit_case default default
submit_case explicit explicit

# The slurmd hard-limit ceiling must be stable across both jobs. Soft limits
# were validated against the submit-side snapshots inside submit_case().
for name in CPU CORE STACK NOFILE; do
	default_hard=$(limit_value "$name" hard "${evidence_dir}/default-job.txt")
	explicit_hard=$(limit_value "$name" hard "${evidence_dir}/explicit-job.txt")
	[ "$default_hard" = "$explicit_hard" ] ||
		fail "job hard limit changed between cases name=$name"
done

"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" ||
	fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-final.txt")" = IDLE ] ||
	fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-final.txt")" = 0 ] ||
	fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-final.txt")" = 0 ] ||
	fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed'
[ "$(node_field SlurmdStartTime "${run_dir}/node-final.txt")" = "$slurmd_start" ] ||
	fail 'SlurmdStartTime changed'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-final.txt" 2>/dev/null; then
	fail 'slurmstepd remains after SMD-110'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-final.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-final.txt" \
	>"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'SMD-110 process remains'
/usr/bin/tail -c "+$((log_size + 1))" "$log_file" \
	>"${run_dir}/slurmd-log-delta.txt" || fail 'cannot save slurmd log delta'
/usr/bin/grep -E \
	'fatal:|pthread_mutex_lock.*Invalid argument|_prlimit.*Invalid argument|Can.t propagate|abort' \
	"${run_dir}/slurmd-log-delta.txt" >"${run_dir}/unexpected-errors.txt" || true
[ ! -s "${run_dir}/unexpected-errors.txt" ] || fail 'unexpected slurmd runtime error'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_probe" "$source_job" \
	"$source_submit" "$source_driver" >"${run_dir}/inputs-after.sha256"
/usr/bin/diff -u "${run_dir}/inputs-before.sha256" \
	"${run_dir}/inputs-after.sha256" >"${run_dir}/inputs.diff" ||
	fail 'production config or test inputs changed'

for case_name in default explicit; do
	/usr/bin/printf '[case=%s submit-limits]\n' "$case_name"
	/bin/cat "${evidence_dir}/${case_name}-submit.txt"
	/usr/bin/printf '[case=%s job-limits]\n' "$case_name"
	/bin/cat "${evidence_dir}/${case_name}-job.txt"
	/usr/bin/printf '[case=%s accounting]\n' "$case_name"
	/bin/cat "${evidence_dir}/${case_name}-accounting.txt"
done

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s\n' \
	"SMD110_ULIMIT_COMPLETE jobs=${completed_jobs} slurmd_pid=${slurmd_pid}" \
	' limits=CPU,CORE,STACK,NOFILE production_unchanged=PASS' \
	" run_dir=${run_dir}"
