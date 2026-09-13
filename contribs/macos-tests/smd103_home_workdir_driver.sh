#!/bin/sh

set -u

if [ "${SMD103_HOME_WORKDIR_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD103_HOME_WORKDIR_CONFIRMED=YES after accepting four short HOME/workdir jobs' >&2
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
source_dir=/Users/REDACTED_USER/dev/slurm.26-05/contribs/macos-tests
source_payload=${source_dir}/smd103_home_workdir_payload.sh
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd103-${run_stamp}
input_dir=${run_dir}/input
output_dir=${run_dir}/output
unicode_dir=${run_dir}/work\ dir-日本語
denied_dir=${run_dir}/root-only-denied
jobs_file=${run_dir}/jobs.tsv
test_jobs=
slurmd_pid=
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

cancel_active_jobs()
{
	for active_job in $test_jobs; do
		state=$(queue_state "$active_job")
		if [ -n "$state" ]; then
			/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$active_job" "$state" >&2
			"$scancel" "$active_job" >/dev/null 2>&1 || true
		fi
	done
}

make_evidence_readable()
{
	[ -d "$run_dir" ] || return 0
	/bin/chmod 0755 "$run_dir" "$input_dir" "$output_dir" 2>/dev/null || true
	/usr/bin/find "$input_dir" "$output_dir" -type f -exec /bin/chmod 0644 {} \; || return 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_active_jobs
	make_evidence_readable || rc=1
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: no production configuration was changed; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

wait_job_gone()
{
	active_job=$1
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		if [ -z "$(queue_state "$active_job")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' \
				"$active_job" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

accounting_complete()
{
	active_job=$1
	file=$2
	"$sacct" -j "$active_job" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$active_job" -v user="$test_user" '
	$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { root_ok = 1 }
	$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" { batch_ok = 1 }
	END { exit !(root_ok && batch_ok) }
	' "$file"
}

wait_accounting()
{
	active_job=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if accounting_complete "$active_job" "$file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

physical_path()
{
	(
		cd "$1" || exit 1
		/bin/pwd -P
	)
}

submit_case()
{
	case_name=$1
	requested_dir=$2
	expected_cwd=$3
	expect_stderr=$4

	submit_result=$(
		cd /tmp || exit 1
		/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
			"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
			--cpus-per-task=1 --mem=128M --time=00:01:00 \
			--chdir="$requested_dir" --job-name="smd103-${case_name}" \
			--output="${output_dir}/${case_name}-%j.out" \
			--error="${output_dir}/${case_name}-%j.err" \
			"${input_dir}/payload.sh" \
			"$case_name" "$test_home" "$expected_cwd" "$denied_dir"
	) || return 1
	job_id=${submit_result%%;*}
	case "$job_id" in
	''|*[!0-9]*) return 1 ;;
	esac
	test_jobs="$test_jobs $job_id"
	/usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
		"$case_name" "$job_id" "$requested_dir" "$expected_cwd" "$expect_stderr" \
		>>"$jobs_file"
	/usr/bin/printf 'submitted case=%s job_id=%s requested_dir=%s\n' \
		"$case_name" "$job_id" "$requested_dir"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for path in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" "$scancel" \
	"$sacct" "$pid_file" "$source_payload"; do
	[ -e "$path" ] || fail "missing $path"
done
for command in /usr/bin/awk /usr/bin/diff /usr/bin/find \
	/usr/bin/grep /usr/bin/id /usr/bin/pgrep /usr/bin/shasum /usr/bin/stat \
	/usr/bin/sudo /usr/sbin/chown /bin/cat /bin/chmod /bin/cp /bin/date \
	/bin/kill /bin/mkdir /bin/ps /bin/pwd /bin/sleep /usr/bin/touch; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'
test_home=$(/usr/bin/id -P "$test_user" 2>/dev/null |
	/usr/bin/awk -F ':' -v user="$test_user" '$1 == user { print $9; exit }')
[ -n "$test_home" ] || fail 'cannot read testuser HOME'
[ -d "$test_home" ] || fail "testuser HOME does not exist: $test_home"
[ "$(/usr/bin/stat -f '%u:%g' "$test_home")" = "$test_uid:$test_gid" ] ||
	fail 'testuser HOME owner mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$input_dir" || fail 'cannot create run/input directory'
/bin/mkdir -m 0700 "$output_dir" "$unicode_dir" || fail 'cannot create testuser directories'
/bin/mkdir -m 0700 "$denied_dir" || fail 'cannot create denied directory'
/usr/bin/touch "${denied_dir}/root-only-marker" || fail 'cannot create denied marker'
/bin/chmod 0600 "${denied_dir}/root-only-marker" || fail 'cannot protect denied marker'
/usr/sbin/chown -R "$test_uid:$test_gid" "$output_dir" "$unicode_dir" ||
	fail 'cannot chown testuser directories'
/bin/cp "$source_payload" "${input_dir}/payload.sh" || fail 'cannot stage payload'
/bin/chmod 0555 "${input_dir}/payload.sh" || fail 'cannot set payload mode'

if /usr/bin/sudo -n -H -u "$test_user" /bin/test -x "$denied_dir"; then
	fail 'denied directory is searchable by testuser before test'
fi
if /usr/bin/sudo -n -H -u "$test_user" /bin/test -r "${denied_dir}/root-only-marker"; then
	fail 'denied marker is readable by testuser before test'
fi

test_home_physical=$(physical_path "$test_home") || fail 'cannot resolve testuser HOME'
tmp_physical=$(physical_path /tmp) || fail 'cannot resolve /tmp'
unicode_physical=$(physical_path "$unicode_dir") || fail 'cannot resolve unicode directory'
/usr/bin/printf 'run_dir=%s home=%s tmp_physical=%s unicode_dir=%s denied_dir=%s\n' \
	"$run_dir" "$test_home" "$tmp_physical" "$unicode_dir" "$denied_dir"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail 'slurmd is not running'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" >"${run_dir}/inputs-before.sha256"

submit_case home "$test_home" "$test_home_physical" empty || fail 'HOME case submission failed'
submit_case tmp /tmp "$tmp_physical" empty || fail '/tmp case submission failed'
submit_case unicode "$unicode_dir" "$unicode_physical" empty || fail 'unicode case submission failed'
submit_case denied "$denied_dir" "$tmp_physical" chdir_fallback || fail 'denied case submission failed'

while IFS="$(/usr/bin/printf '\t')" read -r case_name job_id requested_dir expected_cwd expect_stderr; do
	wait_job_gone "$job_id" || fail "job remained in queue case=$case_name job_id=$job_id"
	wait_accounting "$job_id" "${run_dir}/accounting-${case_name}.txt" ||
		fail "accounting mismatch case=$case_name job_id=$job_id"

	job_out=${output_dir}/${case_name}-${job_id}.out
	job_err=${output_dir}/${case_name}-${job_id}.err
	[ -f "$job_out" ] || fail "stdout missing case=$case_name"
	[ -f "$job_err" ] || fail "stderr missing case=$case_name"
	/usr/bin/grep -Fxq "case=${case_name}" "$job_out" || fail "case marker mismatch case=$case_name"
	/usr/bin/grep -Fxq "job_id=${job_id}" "$job_out" || fail "job ID mismatch case=$case_name"
	/usr/bin/grep -Fxq 'job_user=testuser' "$job_out" || fail "job user mismatch case=$case_name"
	/usr/bin/grep -Fxq 'actual_user=testuser' "$job_out" || fail "actual user mismatch case=$case_name"
	/usr/bin/grep -Fxq 'actual_uid=3001' "$job_out" || fail "actual UID mismatch case=$case_name"
	/usr/bin/grep -Fxq 'actual_gid=3001' "$job_out" || fail "actual GID mismatch case=$case_name"
	/usr/bin/grep -Fxq "home=${test_home}" "$job_out" || fail "HOME mismatch case=$case_name"
	/usr/bin/grep -Fxq "cwd=${expected_cwd}" "$job_out" || fail "cwd mismatch case=$case_name"
	/usr/bin/grep -Fxq "SMD103_PAYLOAD_PASS case=${case_name} home=${test_home} cwd=${expected_cwd}" \
		"$job_out" || fail "PASS marker mismatch case=$case_name"

	if [ "$expect_stderr" = empty ]; then
		[ ! -s "$job_err" ] || fail "unexpected stderr case=$case_name"
	else
		/usr/bin/grep -Fq "$denied_dir" "$job_err" || fail 'denied path missing from stderr'
		/usr/bin/grep -Fq 'Permission denied' "$job_err" || fail 'EACCES missing from stderr'
		/usr/bin/grep -Fq 'going to /tmp instead' "$job_err" || fail 'fallback missing from stderr'
		/usr/bin/grep -Fxq 'denied_directory_access=BLOCKED' "$job_out" ||
			fail 'payload did not verify denied directory isolation'
	fi

	for owned_file in "$job_out" "$job_err"; do
		[ "$(/usr/bin/stat -f '%u:%g' "$owned_file")" = "$test_uid:$test_gid" ] ||
			fail "output owner mismatch case=$case_name file=$owned_file"
	done
	/usr/bin/printf 'verified case=%s job_id=%s cwd=%s accounting=COMPLETED:0:0\n' \
		"$case_name" "$job_id" "$expected_cwd"
done <"$jobs_file"

"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-final.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-final.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-final.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed during SMD-103'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-final.txt" 2>/dev/null; then
	fail 'slurmstepd remains after SMD-103'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-final.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-final.txt" >"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'SMD-103 process remains'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" >"${run_dir}/inputs-after.sha256"
/usr/bin/diff -u "${run_dir}/inputs-before.sha256" "${run_dir}/inputs-after.sha256" \
	>"${run_dir}/inputs.diff" || fail 'production config or payload changed during SMD-103'

make_evidence_readable || fail 'cannot make evidence readable'
while IFS="$(/usr/bin/printf '\t')" read -r case_name job_id requested_dir expected_cwd expect_stderr; do
	/usr/bin/printf '[case=%s job_id=%s stdout]\n' "$case_name" "$job_id"
	/bin/cat "${output_dir}/${case_name}-${job_id}.out"
	/usr/bin/printf '[case=%s job_id=%s stderr]\n' "$case_name" "$job_id"
	/bin/cat "${output_dir}/${case_name}-${job_id}.err"
	/usr/bin/printf '[case=%s job_id=%s accounting]\n' "$case_name" "$job_id"
	/bin/cat "${run_dir}/accounting-${case_name}.txt"
done <"$jobs_file"

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD103_HOME_WORKDIR_COMPLETE jobs=4 slurmd_pid=%s production_unchanged=PASS run_dir=%s\n' \
	"$slurmd_pid" "$run_dir"
