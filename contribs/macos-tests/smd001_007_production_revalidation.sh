#!/bin/sh

set -u

source_root=${SMD_SOURCE_ROOT:-/Users/tera/dev/slurm.26-05}
slurm_prefix=/opt/slurm/26.11.0
slurm_bin=${slurm_prefix}/bin
slurm_conf=${slurm_prefix}/etc/slurm.conf
srun=${slurm_bin}/srun
scontrol=${slurm_bin}/scontrol
squeue=${slurm_bin}/squeue
sacct=${slurm_bin}/sacct
pid_file=/var/run/slurmd.pid
node_name=PC-210
test_user=testuser
expected_srun_hash=0d5ff8c6ea7d793fe4f33588bf6c890d8e4bc7abe742296f6cbf5e061c0103d9
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd001-007-production-${run_stamp}
assets=${run_dir}/assets
success=0
active_jobs=
before_pid=

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null || true
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ]; then
		for job_id in $active_jobs; do
			state=$(queue_state "$job_id")
			if [ -n "$state" ]; then
				printf 'recovery: cancel job=%s state=%s\n' "$job_id" "$state" >&2
				"${slurm_bin}/scancel" "$job_id" >/dev/null 2>&1 || true
			fi
		done
		printf 'recovery: no config or daemon mutation was performed; inspect %s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

extract_run_dir()
{
	/usr/bin/sed -n 's/.*run_dir=\([^ ]*\).*/\1/p' "$1" | /usr/bin/tail -n 1
}

record_jobs()
{
	jobs_file=$1
	while read case_name job_id; do
		[ -n "${job_id:-}" ] || continue
		active_jobs="$active_jobs $job_id"
	done <"$jobs_file"
}

wait_accounting()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 30 ]; do
		if "$sacct" -n -X -j "$job_id" --format=State,ExitCode -P 2>/dev/null |
			/usr/bin/grep -Eq '^[A-Z]'; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

assert_top()
{
	job_id=$1
	expected_state=$2
	expected_exit=$3
	wait_accounting "$job_id" || fail "accounting not visible for job $job_id"
	line=$("$sacct" -n -X -j "$job_id" --format=State,ExitCode -P |
		/usr/bin/sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}')
	printf 'accounting_top job=%s observed=%s expected_state=%s expected_exit=%s\n' \
		"$job_id" "$line" "$expected_state" "$expected_exit"
	observed_state=${line%%|*}
	observed_exit=${line#*|}
	observed_exit=$(printf '%s' "$observed_exit" | /usr/bin/tr -d ' ')
	case "$observed_state" in
	"$expected_state"|"$expected_state "*) ;;
	*) fail "unexpected top state for job $job_id: $observed_state" ;;
	esac
	[ "$observed_exit" = "$expected_exit" ] ||
		fail "unexpected top exit for job $job_id: $observed_exit"
}

assert_record()
{
	job_id=$1
	record_suffix=$2
	expected_state=$3
	expected_exit=$4
	"$sacct" -n -j "$job_id" --format=JobIDRaw,State,ExitCode -P |
		/usr/bin/tr -d ' ' >"${run_dir}/sacct-${job_id}-records.txt"
	if ! /usr/bin/grep -Eq "^${job_id}\\.${record_suffix}\\|${expected_state}[^|]*\\|${expected_exit}$" \
		"${run_dir}/sacct-${job_id}-records.txt"; then
		fail "missing ${job_id}.${record_suffix} ${expected_state} ${expected_exit}"
	fi
}

run_as_test_user()
{
	(
		cd /tmp || exit 1
		/usr/bin/sudo -H -u "$test_user" "$@"
	)
}

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	fail 'run as root'
fi
if [ "${SMD001_007_PRODUCTION_CONFIRMED:-}" != YES ]; then
	printf 'error: rerun with SMD001_007_PRODUCTION_CONFIRMED=YES\n' >&2
	exit 75
fi

for required in "$slurm_conf" "$srun" "$scontrol" "$squeue" "$sacct" \
	"$pid_file" /usr/bin/expect; do
	[ -e "$required" ] || fail "missing $required"
done
/usr/bin/id "$test_user" >/dev/null 2>&1 || fail "missing test user $test_user"

/bin/mkdir -m 0755 "$run_dir" "$assets" || exit 1
trap cleanup EXIT HUP INT TERM

for asset_name in \
	smd002_production_pty_wrapper.sh smd002_production_pty.exp \
	smd003_stdio_exit.sh \
	smd004_signal_delivery.sh smd004_term_trap.sh \
	smd004_normal_cancel.sh smd004_force_kill.sh \
	smd005_process_tree_driver.sh smd005_process_tree.sh \
	smd005_child_tree.sh smd005_control.sh \
	smd006_time_limit_driver.sh smd006_time_limit_workload.sh \
	smd007_launch_failure_driver.sh smd007_case_runner.sh; do
	/usr/bin/install -m 0755 \
		"${source_root}/contribs/macos-tests/${asset_name}" \
		"${assets}/${asset_name}" || exit 1
done

"$scontrol" ping >"${run_dir}/controller-before.txt" || exit 1
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-before.txt" ||
	! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-before.txt"; then
	fail 'PC-210 is not idle before revalidation'
fi
queue_before=$("$squeue" -h -o '%i|%T|%u|%j|%N') || exit 1
[ -z "$queue_before" ] || fail "queue is not empty: $queue_before"

before_pid=$(/bin/cat "$pid_file")
/bin/ps -p "$before_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/slurmd-before.txt" || exit 1
if ! /usr/bin/grep -Eq "^root[[:space:]]+${before_pid}[[:space:]]+1[[:space:]].*/opt/slurm/26.11.0/sbin/slurmd" \
	"${run_dir}/slurmd-before.txt"; then
	fail 'current slurmd is not the production launchd process'
fi

actual_srun_hash=$(/usr/bin/shasum -a 256 "$srun" | /usr/bin/awk '{print $1}')
[ "$actual_srun_hash" = "$expected_srun_hash" ] ||
	fail "production srun hash mismatch: $actual_srun_hash"
/usr/bin/shasum -a 256 \
	"$srun" "${slurm_prefix}/sbin/slurmd" \
	"${slurm_prefix}/sbin/slurmstepd" \
	"${slurm_prefix}/lib/slurm/libslurmfull.dylib" "$slurm_conf" \
	>"${run_dir}/artifacts-before.sha256" || exit 1

printf 'phase=SMD-001 production noninteractive srun\n'
run_as_test_user /usr/bin/env SLURM_CONF="$slurm_conf" \
	"$srun" --partition=debug --nodes=1 --ntasks=1 --cpus-per-task=1 \
	--mem=1G --time=00:01:00 --chdir=/tmp --job-name=smd001-production \
	/bin/sh -c 'printf "job_id=%s\n" "$SLURM_JOB_ID"; /bin/hostname' \
	>"${run_dir}/smd001.out" 2>"${run_dir}/smd001.err" ||
	fail 'SMD-001 srun failed'
smd001_job=$(/usr/bin/sed -n 's/^job_id=//p' "${run_dir}/smd001.out")
[ -n "$smd001_job" ] || fail 'SMD-001 job id missing'
active_jobs="$active_jobs $smd001_job"
/usr/bin/grep -Eq '^PC-210(\.local)?$' "${run_dir}/smd001.out" ||
	fail 'SMD-001 hostname missing'
[ ! -s "${run_dir}/smd001.err" ] || fail 'SMD-001 stderr is not empty'
assert_top "$smd001_job" COMPLETED 0:0
assert_record "$smd001_job" 0 COMPLETED 0:0

printf 'phase=SMD-002 production PTY\n'
/usr/bin/expect "${assets}/smd002_production_pty.exp" \
	"${assets}/smd002_production_pty_wrapper.sh" \
	"${run_dir}/smd002-session.txt" >"${run_dir}/smd002-expect.out" \
	2>"${run_dir}/smd002-expect.err" || fail 'SMD-002 expect session failed'
smd002_job=$(/usr/bin/sed -n 's/.*SMD002_JOB_ID=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/smd002-session.txt" | /usr/bin/tail -n 1)
[ -n "$smd002_job" ] || fail 'SMD-002 job id missing'
active_jobs="$active_jobs $smd002_job"
/usr/bin/grep -q 'SMD002_STDIN_STDOUT=PASS' "${run_dir}/smd002-session.txt" ||
	fail 'SMD-002 stdin/stdout marker missing'
/usr/bin/grep -Eq '/dev/tty' "${run_dir}/smd002-session.txt" ||
	fail 'SMD-002 PTY device missing'
/usr/bin/grep -q '41 89' "${run_dir}/smd002-session.txt" ||
	fail 'SMD-002 initial window size missing'
/usr/bin/grep -q '34 100' "${run_dir}/smd002-session.txt" ||
	fail 'SMD-002 resized window size missing'
/usr/bin/grep -q 'SMD002_CTRL_C_RC=130' "${run_dir}/smd002-session.txt" ||
	fail 'SMD-002 Ctrl-C result missing'
/usr/bin/grep -q 'SMD002_TTY_RESTORE=PASS' "${run_dir}/smd002-session.txt" ||
	fail 'SMD-002 tty restore missing'
assert_top "$smd002_job" COMPLETED 0:0
assert_record "$smd002_job" 0 COMPLETED 0:0

printf 'phase=SMD-003 production stdio and exit codes\n'
run_as_test_user /usr/bin/env \
	SMD_SLURM_BIN="$slurm_bin" SMD_SLURM_CONF="$slurm_conf" \
	SMD_SLURM_LIB= SMD_STAGE_DIR="$assets" SMD_SRUN_BIN="$srun" \
	"${assets}/smd003_stdio_exit.sh" >"${run_dir}/smd003-driver.out" \
	2>"${run_dir}/smd003-driver.err" || fail 'SMD-003 driver failed'
smd003_dir=$(extract_run_dir "${run_dir}/smd003-driver.out")
[ -d "$smd003_dir" ] || fail 'SMD-003 run directory missing'
for expected_rc in 0 1 255; do
	observed_rc=$(/bin/cat "${smd003_dir}/exit-${expected_rc}.client-rc")
	[ "$observed_rc" = "$expected_rc" ] ||
		fail "SMD-003 client rc mismatch expected=$expected_rc observed=$observed_rc"
	/usr/bin/grep -q "stdout_marker=exit_${expected_rc}" \
		"${smd003_dir}/exit-${expected_rc}.out" || fail 'SMD-003 stdout mismatch'
	/usr/bin/grep -q "stderr_marker=exit_${expected_rc}" \
		"${smd003_dir}/exit-${expected_rc}.err" || fail 'SMD-003 stderr mismatch'
	job_id=$(/usr/bin/sed -n 's/^job_id=//p' \
		"${smd003_dir}/exit-${expected_rc}.out")
	[ -n "$job_id" ] || fail 'SMD-003 job id missing'
	active_jobs="$active_jobs $job_id"
	if [ "$expected_rc" -eq 0 ]; then
		assert_top "$job_id" COMPLETED 0:0
		assert_record "$job_id" 0 COMPLETED 0:0
	else
		assert_top "$job_id" FAILED "${expected_rc}:0"
		assert_record "$job_id" 0 FAILED "${expected_rc}:0"
	fi
done

printf 'phase=SMD-004 production signal delivery\n'
run_as_test_user /usr/bin/env \
	SMD_SLURM_BIN="$slurm_bin" SMD_SLURM_CONF="$slurm_conf" \
	SMD_SLURM_LIB= SMD_STAGE_DIR="$assets" SMD_SRUN_BIN="$srun" \
	"${assets}/smd004_signal_delivery.sh" >"${run_dir}/smd004-driver.out" \
	2>"${run_dir}/smd004-driver.err" || fail 'SMD-004 driver failed'
smd004_dir=$(extract_run_dir "${run_dir}/smd004-driver.out")
[ -f "${smd004_dir}/jobs.tsv" ] || fail 'SMD-004 jobs.tsv missing'
record_jobs "${smd004_dir}/jobs.tsv"
smd004_term=$(/usr/bin/awk '$1=="term" {print $2}' "${smd004_dir}/jobs.tsv")
smd004_cancel=$(/usr/bin/awk '$1=="normal_cancel" {print $2}' "${smd004_dir}/jobs.tsv")
smd004_kill=$(/usr/bin/awk '$1=="force_kill" {print $2}' "${smd004_dir}/jobs.tsv")
assert_top "$smd004_term" FAILED 42:0
assert_record "$smd004_term" batch FAILED 42:0
assert_top "$smd004_cancel" CANCELLED 0:0
assert_record "$smd004_cancel" batch CANCELLED 0:15
assert_top "$smd004_kill" CANCELLED 0:0
assert_record "$smd004_kill" batch CANCELLED 0:9
/usr/bin/grep -q 'term_received' "${smd004_dir}/term.out" ||
	fail 'SMD-004 TERM trap marker missing'

printf 'phase=SMD-005 production process tree cleanup\n'
run_as_test_user /usr/bin/env \
	SMD_SLURM_BIN="$slurm_bin" SMD_SLURM_CONF="$slurm_conf" \
	SMD_SLURM_LIB= SMD_STAGE_DIR="$assets" SMD_SRUN_BIN="$srun" \
	"${assets}/smd005_process_tree_driver.sh" \
	>"${run_dir}/smd005-driver.out" 2>"${run_dir}/smd005-driver.err" ||
	fail 'SMD-005 driver failed'
smd005_dir=$(extract_run_dir "${run_dir}/smd005-driver.out")
[ -f "${smd005_dir}/jobs.tsv" ] || fail 'SMD-005 jobs.tsv missing'
record_jobs "${smd005_dir}/jobs.tsv"
smd005_control=$(/usr/bin/awk '$1=="control" {print $2}' "${smd005_dir}/jobs.tsv")
smd005_target=$(/usr/bin/awk '$1=="target" {print $2}' "${smd005_dir}/jobs.tsv")
assert_top "$smd005_control" CANCELLED 0:0
assert_record "$smd005_control" batch CANCELLED 0:15
assert_top "$smd005_target" CANCELLED 0:0
assert_record "$smd005_target" batch CANCELLED 0:15
if /usr/bin/grep -q 'residual=YES' "${run_dir}/smd005-driver.out"; then
	fail 'SMD-005 residual process detected'
fi
/usr/bin/grep -q 'control_after_target_cancel.*state=RUNNING' \
	"${run_dir}/smd005-driver.out" || fail 'SMD-005 control isolation missing'

printf 'phase=SMD-006 production time limit\n'
run_as_test_user /usr/bin/env \
	SMD_SLURM_BIN="$slurm_bin" SMD_SLURM_CONF="$slurm_conf" \
	SMD_SLURM_LIB= SMD_STAGE_DIR="$assets" SMD_SRUN_BIN="$srun" \
	"${assets}/smd006_time_limit_driver.sh" \
	>"${run_dir}/smd006-driver.out" 2>"${run_dir}/smd006-driver.err" ||
	fail 'SMD-006 driver failed'
smd006_dir=$(extract_run_dir "${run_dir}/smd006-driver.out")
smd006_job=$(/bin/cat "${smd006_dir}/job-id.txt")
active_jobs="$active_jobs $smd006_job"
assert_top "$smd006_job" TIMEOUT 0:0
assert_record "$smd006_job" batch FAILED 124:0
/usr/bin/grep -q 'term_received' "${smd006_dir}/time-limit.out" ||
	fail 'SMD-006 TERM marker missing'
if /usr/bin/grep -q 'residual=YES' "${run_dir}/smd006-driver.out"; then
	fail 'SMD-006 residual process detected'
fi

printf 'phase=SMD-007 production launch failures\n'
run_as_test_user /usr/bin/env \
	SMD_SLURM_BIN="$slurm_bin" SMD_SLURM_CONF="$slurm_conf" \
	SMD_SLURM_LIB= SMD_STAGE_DIR="$assets" SMD_SRUN_BIN="$srun" \
	"${assets}/smd007_launch_failure_driver.sh" \
	>"${run_dir}/smd007-driver.out" 2>"${run_dir}/smd007-driver.err" ||
	fail 'SMD-007 driver failed'
smd007_dir=$(extract_run_dir "${run_dir}/smd007-driver.out")
[ -f "${smd007_dir}/jobs.tsv" ] || fail 'SMD-007 jobs.tsv missing'
record_jobs "${smd007_dir}/jobs.tsv"
smd007_enoent=$(/usr/bin/awk '$1=="nonexistent_command" {print $2}' "${smd007_dir}/jobs.tsv")
smd007_eacces=$(/usr/bin/awk '$1=="not_executable" {print $2}' "${smd007_dir}/jobs.tsv")
smd007_chdir=$(/usr/bin/awk '$1=="missing_chdir" {print $2}' "${smd007_dir}/jobs.tsv")
assert_top "$smd007_enoent" FAILED 2:0
assert_top "$smd007_eacces" FAILED 13:0
assert_top "$smd007_chdir" COMPLETED 0:0
/usr/bin/grep -q 'going to /tmp instead' "${smd007_dir}/missing_chdir.err" ||
	fail 'SMD-007 fallback diagnostic missing'

job_list=$(printf '%s' "$active_jobs" | /usr/bin/sed 's/^ *//;s/  */,/g')
"$sacct" -j "$job_list" \
	--format=JobIDRaw,JobName,User,State,ExitCode,NodeList -P \
	>"${run_dir}/all-accounting.txt" || exit 1
"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || exit 1
"$squeue" -h -o '%i|%T|%u|%j|%N' >"${run_dir}/queue-after.txt" || exit 1
if [ -s "${run_dir}/queue-after.txt" ]; then
	fail 'queue is not empty after revalidation'
fi
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-after.txt" ||
	! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-after.txt" ||
	! /usr/bin/grep -q 'AllocTRES=$' "${run_dir}/node-after.txt"; then
	fail 'node resources were not released after revalidation'
fi
after_pid=$(/bin/cat "$pid_file")
[ "$after_pid" = "$before_pid" ] || fail 'slurmd PID changed during SMD-001..007'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-after.txt" 2>&1; then
	fail 'slurmstepd remained after revalidation'
fi
/usr/bin/shasum -a 256 \
	"$srun" "${slurm_prefix}/sbin/slurmd" \
	"${slurm_prefix}/sbin/slurmstepd" \
	"${slurm_prefix}/lib/slurm/libslurmfull.dylib" "$slurm_conf" \
	>"${run_dir}/artifacts-after.sha256" || exit 1
/usr/bin/cmp -s "${run_dir}/artifacts-before.sha256" \
	"${run_dir}/artifacts-after.sha256" || fail 'production artifact hashes changed'

success=1
trap - EXIT HUP INT TERM
printf 'SMD001_007_PRODUCTION_REVALIDATION_COMPLETE jobs=%s slurmd_pid=%s node=IDLE queue=EMPTY artifacts=UNCHANGED run_dir=%s\n' \
	"$job_list" \
	"$before_pid" "$run_dir"
