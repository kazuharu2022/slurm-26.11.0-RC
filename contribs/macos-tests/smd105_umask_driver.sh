#!/bin/sh

set -u

if [ "${SMD105_UMASK_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s %s\n' \
		'error: set SMD105_UMASK_CONFIRMED=YES after accepting' \
		'three short batch jobs with umask 022, 027, and 077' >&2
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
source_payload=${source_dir}/smd105_umask_payload.sh
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd105-${run_stamp}
input_dir=${run_dir}/input
cases_dir=${run_dir}/cases
evidence_dir=${run_dir}/evidence
active_job=
completed_jobs=
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

assert_identity_mode()
{
	path=$1
	expected_mode=$2
	actual=$(/usr/bin/stat -f '%u:%g:%Lp' "$path") || return 1
	[ "$actual" = "${test_uid}:${test_gid}:${expected_mode}" ]
}

validate_payload_output()
{
	case_name=$1
	job=$2
	expected_umask=$3
	case_dir=$4
	file=$5
	/usr/bin/grep -Fxq "case=${case_name}" "$file" || return 1
	/usr/bin/grep -Fxq "job_id=${job}" "$file" || return 1
	/usr/bin/grep -Fxq 'actual_user=testuser' "$file" || return 1
	/usr/bin/grep -Fxq 'actual_uid=3001' "$file" || return 1
	/usr/bin/grep -Fxq 'actual_gid=3001' "$file" || return 1
	/usr/bin/grep -Fxq "normalized_umask=${expected_umask}" "$file" || return 1
	/usr/bin/grep -Fxq "created_file=${case_dir}/created-file.txt" \
		"$file" || return 1
	/usr/bin/grep -Fxq "created_dir=${case_dir}/created-dir" \
		"$file" || return 1
	/usr/bin/grep -Fxq "nested_file=${case_dir}/created-dir/nested-file.txt" \
		"$file" || return 1
	/usr/bin/grep -Fxq \
		"SMD105_PAYLOAD_PASS case=${case_name} umask=${expected_umask}" \
		"$file" || return 1
}

submit_case()
{
	case_name=$1
	mode=$2
	expected_umask=$3
	expected_file_mode=$4
	expected_dir_mode=$5
	case_dir=${cases_dir}/${case_name}
	/bin/mkdir -m 0700 "$case_dir" || fail "cannot create case=$case_name"
	/usr/sbin/chown "$test_uid:$test_gid" "$case_dir" ||
		fail "cannot chown case=$case_name"

	case "$mode" in
	inherited)
		active_job=$(
			cd /tmp || exit 1
			/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
				"SLURM_CONF=${slurm_conf}" /bin/sh -c '
				umask "$1"
				unset SLURM_UMASK
				shift
				exec "$@"
				' sh "0${expected_umask}" "$sbatch" --parsable \
				--export=ALL --partition="$partition" --nodes=1 \
				--ntasks=1 --cpus-per-task=1 --mem=128M --time=00:01:00 \
				--chdir=/tmp --job-name="smd105-${case_name}" \
				--output="${case_dir}/slurm-%j.out" \
				--error="${case_dir}/slurm-%j.err" \
				"${input_dir}/payload.sh" "$case_name" \
				"$expected_umask" "$case_dir"
		) || fail "submission failed case=$case_name"
		;;
	explicit)
		active_job=$(
			cd /tmp || exit 1
			/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
				"SLURM_CONF=${slurm_conf}" /bin/sh -c '
				umask 0022
				SLURM_UMASK=$1
				export SLURM_UMASK
				shift
				exec "$@"
				' sh "0${expected_umask}" "$sbatch" --parsable \
				--export=ALL --partition="$partition" --nodes=1 \
				--ntasks=1 --cpus-per-task=1 --mem=128M --time=00:01:00 \
				--chdir=/tmp --job-name="smd105-${case_name}" \
				--output="${case_dir}/slurm-%j.out" \
				--error="${case_dir}/slurm-%j.err" \
				"${input_dir}/payload.sh" "$case_name" \
				"$expected_umask" "$case_dir"
		) || fail "submission failed case=$case_name"
		;;
	*) fail "unknown submission mode=$mode" ;;
	esac

	active_job=${active_job%%;*}
	case "$active_job" in
	''|*[!0-9]*) fail "invalid job id case=$case_name id=$active_job" ;;
	esac
	job=$active_job
	/usr/bin/printf 'submitted case=%s mode=%s umask=%s job_id=%s\n' \
		"$case_name" "$mode" "$expected_umask" "$job"
	wait_job_gone "$job" || fail "job remained in queue case=$case_name"
	active_job=

	accounting_file=${evidence_dir}/${case_name}-accounting.txt
	wait_accounting "$job" "$accounting_file" ||
		fail "accounting mismatch case=$case_name job=$job"
	stdout_file=${case_dir}/slurm-${job}.out
	stderr_file=${case_dir}/slurm-${job}.err
	created_file=${case_dir}/created-file.txt
	created_dir=${case_dir}/created-dir
	nested_file=${created_dir}/nested-file.txt
	for path in "$stdout_file" "$stderr_file" "$created_file" \
		"$created_dir" "$nested_file"; do
		[ -e "$path" ] || fail "missing path case=$case_name path=$path"
	done
	[ ! -s "$stderr_file" ] || fail "stderr is not empty case=$case_name"
	validate_payload_output "$case_name" "$job" "$expected_umask" \
		"$case_dir" "$stdout_file" || fail "payload mismatch case=$case_name"
	assert_identity_mode "$stdout_file" "$expected_file_mode" ||
		fail "stdout identity/mode mismatch case=$case_name"
	assert_identity_mode "$stderr_file" "$expected_file_mode" ||
		fail "stderr identity/mode mismatch case=$case_name"
	assert_identity_mode "$created_file" "$expected_file_mode" ||
		fail "created file identity/mode mismatch case=$case_name"
	assert_identity_mode "$nested_file" "$expected_file_mode" ||
		fail "nested file identity/mode mismatch case=$case_name"
	assert_identity_mode "$created_dir" "$expected_dir_mode" ||
		fail "created directory identity/mode mismatch case=$case_name"

	/usr/bin/stat -f '%N owner=%u:%g mode=%Lp size=%z' \
		"$stdout_file" "$stderr_file" "$created_file" \
		"$created_dir" "$nested_file" \
		>"${evidence_dir}/${case_name}-metadata.txt" ||
		fail "cannot save metadata case=$case_name"
	/bin/cp "$stdout_file" "${evidence_dir}/${case_name}-stdout.txt" ||
		fail "cannot snapshot stdout case=$case_name"
	/bin/cp "$stderr_file" "${evidence_dir}/${case_name}-stderr.txt" ||
		fail "cannot snapshot stderr case=$case_name"
	/bin/cp "$created_file" "${evidence_dir}/${case_name}-created-file.txt" ||
		fail "cannot snapshot created file case=$case_name"
	/bin/cp "$nested_file" "${evidence_dir}/${case_name}-nested-file.txt" ||
		fail "cannot snapshot nested file case=$case_name"
	/bin/chmod 0644 "${evidence_dir}/${case_name}-"*.txt ||
		fail "cannot set evidence mode case=$case_name"
	completed_jobs="${completed_jobs}${completed_jobs:+,}${job}"
	/usr/bin/printf '%s\n' \
		"verified case=${case_name} job_id=${job} umask=${expected_umask}" \
		"file_mode=${expected_file_mode} dir_mode=${expected_dir_mode}"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for macOS'

for path in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" "$scancel" \
	"$sacct" "$pid_file" "$source_payload"; do
	[ -e "$path" ] || fail "missing $path"
done
for command in /usr/bin/awk /usr/bin/diff /usr/bin/find /usr/bin/grep \
	/usr/bin/id /usr/bin/pgrep /usr/bin/shasum /usr/bin/stat /usr/bin/sudo \
	/usr/sbin/chown /bin/cat /bin/chmod /bin/cp /bin/date /bin/kill \
	/bin/mkdir /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$input_dir" "$cases_dir" \
	"$evidence_dir" || fail 'cannot create run directories'
/bin/cp "$source_payload" "${input_dir}/payload.sh" || fail 'cannot stage payload'
/bin/chmod 0555 "${input_dir}/payload.sh" || fail 'cannot set payload mode'
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
/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" \
	>"${run_dir}/inputs-before.sha256"
/usr/bin/printf 'run_dir=%s slurmd_pid=%s\n' "$run_dir" "$slurmd_pid"

submit_case inherited022 inherited 022 644 755
submit_case explicit027 explicit 027 640 750
submit_case explicit077 explicit 077 600 700

"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" ||
	fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-final.txt")" = IDLE ] ||
	fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-final.txt")" = 0 ] ||
	fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-final.txt")" = 0 ] ||
	fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] ||
	fail 'slurmd PID changed during SMD-105'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-final.txt" 2>/dev/null; then
	fail 'slurmstepd remains after SMD-105'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-final.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-final.txt" \
	>"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'SMD-105 process remains'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" \
	>"${run_dir}/inputs-after.sha256"
/usr/bin/diff -u "${run_dir}/inputs-before.sha256" \
	"${run_dir}/inputs-after.sha256" >"${run_dir}/inputs.diff" ||
	fail 'production config or payload changed during SMD-105'

for case_name in inherited022 explicit027 explicit077; do
	/usr/bin/printf '[case=%s stdout]\n' "$case_name"
	/bin/cat "${evidence_dir}/${case_name}-stdout.txt"
	/usr/bin/printf '[case=%s metadata]\n' "$case_name"
	/bin/cat "${evidence_dir}/${case_name}-metadata.txt"
	/usr/bin/printf '[case=%s accounting]\n' "$case_name"
	/bin/cat "${evidence_dir}/${case_name}-accounting.txt"
done

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s\n' \
	"SMD105_UMASK_COMPLETE jobs=${completed_jobs} slurmd_pid=${slurmd_pid}" \
	' cases=3 production_unchanged=PASS' \
	" run_dir=${run_dir}"
