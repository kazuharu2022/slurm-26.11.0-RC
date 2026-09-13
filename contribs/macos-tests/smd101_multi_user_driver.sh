#!/bin/sh

set -u

source_root=/Users/REDACTED_USER/dev/slurm.26-05
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
payload_source=${source_root}/contribs/macos-tests/smd101_identity_payload.sh
node_name=PC-210
partition=debug
shared_gid=3100
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd101-${run_stamp}
test_jobs=

export SLURM_CONF="$slurm_conf"

fail()
{
	printf 'error: %s\n' "$*" >&2
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

cleanup_jobs()
{
	for job_id in $test_jobs; do
		state=$(queue_state "$job_id")
		if [ -n "$state" ]; then
			printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state"
			"$scancel" "$job_id" >/dev/null 2>&1 || true
		fi
	done
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		if [ -z "$(queue_state "$job_id")" ]; then
			printf 'job_gone job_id=%s wait_seconds=%s\n' "$job_id" "$attempt"
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
	user_name=$2
	output_file=$3
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		"$sacct" -j "$job_id" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList \
			>"$output_file" 2>/dev/null || true
		if /usr/bin/awk -F '|' -v job="$job_id" -v user="$user_name" '
			$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" {
				root_ok = 1
			}
			$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" {
				batch_ok = 1
			}
			END { exit !(root_ok && batch_ok) }
		' "$output_file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

require_group()
{
	user_name=$1
	group_id=$2
	case " $(/usr/bin/id -G "$user_name") " in
	*" $group_id "*) ;;
	*) fail "$user_name is not in GID $group_id" ;;
	esac
}

submit_user_job()
{
	user_name=$1
	user_uid=$2
	user_gid=$3
	user_dir=${run_dir}/${user_name}
	marker=${user_dir}/created-by-job.txt

	/bin/mkdir -m 0700 "$user_dir" || return 1
	/usr/sbin/chown "$user_uid:$user_gid" "$user_dir" || return 1

	submit_result=$(/usr/bin/sudo -n -u "$user_name" -H /usr/bin/env \
		SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable \
		--partition="$partition" \
		--nodes=1 --ntasks=1 --cpus-per-task=1 --mem=256M \
		--time=00:01:00 --chdir=/tmp \
		--job-name="smd101-${user_name}" \
		--output="${user_dir}/slurm-%j.out" \
		--error="${user_dir}/slurm-%j.err" \
		"${run_dir}/payload.sh" \
		"$user_name" "$user_uid" "$user_gid" "$shared_gid" "$marker") || return 1
	job_id=${submit_result%%;*}
	test_jobs="$test_jobs $job_id"
	printf '%s\t%s\t%s\t%s\n' \
		"$user_name" "$user_uid" "$user_gid" "$job_id" >>"${run_dir}/jobs.tsv"
	printf 'submitted user=%s uid=%s gid=%s job_id=%s\n' \
		"$user_name" "$user_uid" "$user_gid" "$job_id"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'
[ -r "$payload_source" ] || fail "missing payload: $payload_source"

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail "cannot create run directory: $run_dir"
/bin/cp "$payload_source" "${run_dir}/payload.sh" || fail 'cannot stage payload'
/bin/chmod 0555 "${run_dir}/payload.sh"
printf 'run_dir=%s\n' "$run_dir"

trap cleanup_jobs EXIT HUP INT TERM

if ! "$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1; then
	/bin/cat "${run_dir}/controller-before.txt" >&2
	if /usr/bin/grep -q ' is DOWN$' "${run_dir}/controller-before.txt"; then
		fail 'controller reports DOWN; no jobs were submitted'
	fi
	fail 'controller ping command failed; no jobs were submitted'
fi
if ! /usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt"; then
	/bin/cat "${run_dir}/controller-before.txt" >&2
	fail 'controller is not UP; no jobs were submitted'
fi
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" 2>&1 || \
	fail 'node readback failed'
before_state=$(node_field State "${run_dir}/node-before.txt")
before_cpu=$(node_field CPUAlloc "${run_dir}/node-before.txt")
before_mem=$(node_field AllocMem "${run_dir}/node-before.txt")
[ "$before_state" = IDLE ] || fail "node state is $before_state, expected IDLE"
[ "$before_cpu" = 0 ] || fail "node CPUAlloc is $before_cpu, expected 0"
[ "$before_mem" = 0 ] || fail "node AllocMem is $before_mem, expected 0"
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'node queue is not empty'

[ "$(/usr/bin/id -u testuser)" = 3001 ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g testuser)" = 3001 ] || fail 'testuser GID mismatch'
[ "$(/usr/bin/id -u testuser2)" = 3002 ] || fail 'testuser2 UID mismatch'
[ "$(/usr/bin/id -g testuser2)" = 3002 ] || fail 'testuser2 GID mismatch'
require_group testuser "$shared_gid"
require_group testuser2 "$shared_gid"

submit_user_job testuser 3001 3001 || fail 'testuser submission failed'
submit_user_job testuser2 3002 3002 || fail 'testuser2 submission failed'

[ "$(/usr/bin/stat -f '%u:%g:%Lp' "${run_dir}/testuser")" = 3001:3001:700 ] ||
	fail 'testuser run directory identity or mode mismatch'
[ "$(/usr/bin/stat -f '%u:%g:%Lp' "${run_dir}/testuser2")" = 3002:3002:700 ] ||
	fail 'testuser2 run directory identity or mode mismatch'
if /usr/bin/sudo -n -u testuser -H /bin/test -w "${run_dir}/testuser2"; then
	fail 'testuser can write testuser2 run directory'
fi
if /usr/bin/sudo -n -u testuser2 -H /bin/test -w "${run_dir}/testuser"; then
	fail 'testuser2 can write testuser run directory'
fi
printf 'directory_isolation=PASS\n'

while IFS="$(printf '\t')" read -r user_name user_uid user_gid job_id; do
	wait_job_gone "$job_id" || fail "job $job_id did not leave queue"
	wait_accounting "$job_id" "$user_name" \
		"${run_dir}/${user_name}/accounting.txt" || \
		fail "job $job_id accounting did not reach COMPLETED 0:0"

	stdout_file=${run_dir}/${user_name}/slurm-${job_id}.out
	stderr_file=${run_dir}/${user_name}/slurm-${job_id}.err
	marker_file=${run_dir}/${user_name}/created-by-job.txt
	[ -f "$stdout_file" ] || fail "missing stdout for job $job_id"
	[ -f "$stderr_file" ] || fail "missing stderr for job $job_id"
	[ ! -s "$stderr_file" ] || fail "non-empty stderr for job $job_id"
	[ -f "$marker_file" ] || fail "missing marker for job $job_id"
	/usr/bin/grep -Fqx \
		"SMD101_PAYLOAD_PASS user=$user_name uid=$user_uid gid=$user_gid shared_gid=$shared_gid" \
		"$stdout_file" || fail "identity marker mismatch for job $job_id"

	for owned_file in "$stdout_file" "$stderr_file" "$marker_file"; do
		owner=$(/usr/bin/stat -f '%u:%g' "$owned_file")
		[ "$owner" = "$user_uid:$user_gid" ] || \
			fail "owner mismatch file=$owned_file actual=$owner expected=$user_uid:$user_gid"
	done
	marker_mode=$(/usr/bin/stat -f '%Lp' "$marker_file")
	[ "$marker_mode" = 600 ] || \
		fail "marker mode mismatch user=$user_name actual=$marker_mode expected=600"
	printf 'verified user=%s job_id=%s owner=%s marker_mode=%s accounting=COMPLETED:0:0\n' \
		"$user_name" "$job_id" "$user_uid:$user_gid" "$marker_mode"
done <"${run_dir}/jobs.tsv"

if /usr/bin/sudo -n -u testuser -H /bin/test -r \
	"${run_dir}/testuser2/created-by-job.txt"; then
	fail 'testuser can read testuser2 private marker'
fi
if /usr/bin/sudo -n -u testuser2 -H /bin/test -r \
	"${run_dir}/testuser/created-by-job.txt"; then
	fail 'testuser2 can read testuser private marker'
fi
printf 'marker_isolation=PASS\n'

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" 2>&1 || \
	fail 'final node readback failed'
after_state=$(node_field State "${run_dir}/node-after.txt")
after_cpu=$(node_field CPUAlloc "${run_dir}/node-after.txt")
after_mem=$(node_field AllocMem "${run_dir}/node-after.txt")
[ "$after_state" = IDLE ] || fail "final node state is $after_state"
[ "$after_cpu" = 0 ] || fail "final CPUAlloc is $after_cpu"
[ "$after_mem" = 0 ] || fail "final AllocMem is $after_mem"
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final node queue is not empty'

while IFS="$(printf '\t')" read -r user_name user_uid user_gid job_id; do
	printf '[user=%s job_id=%s stdout]\n' "$user_name" "$job_id"
	/bin/cat "${run_dir}/${user_name}/slurm-${job_id}.out"
	printf '[user=%s job_id=%s accounting]\n' "$user_name" "$job_id"
	/bin/cat "${run_dir}/${user_name}/accounting.txt"
done <"${run_dir}/jobs.tsv"

trap - EXIT HUP INT TERM
printf 'SMD101_MULTI_USER_COMPLETE jobs=%s final_state=%s CPUAlloc=%s AllocMem=%s run_dir=%s\n' \
	"$(/usr/bin/awk 'END { print NR + 0 }' "${run_dir}/jobs.tsv")" \
	"$after_state" "$after_cpu" "$after_mem" "$run_dir"
