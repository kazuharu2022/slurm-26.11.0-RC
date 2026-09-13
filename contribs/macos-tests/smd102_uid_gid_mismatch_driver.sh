#!/bin/sh

set -u

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
target_user=smdmismatch
controller_uid=3201
controller_gid=3201
worker_uid=3202
worker_gid=3202
node_name=PC-210
partition=debug
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd102-${run_stamp}
job_name=smd102-mismatch-${run_stamp}
test_job_ids=

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
	for job_id in $test_job_ids; do
		state=$(queue_state "$job_id")
		if [ -n "$state" ]; then
			printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state"
			"$scancel" "$job_id" >/dev/null 2>&1 || true
		fi
	done

	"$squeue" -h -u "$target_user" -n "$job_name" -o '%A' 2>/dev/null | \
	while IFS= read -r job_id; do
		case "$job_id" in
		''|*[!0-9]*) continue ;;
		esac
		printf 'cleanup discovered_job_id=%s name=%s\n' "$job_id" "$job_name"
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	done
}

wait_final_node()
{
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" \
			2>"${run_dir}/node-after.err" || true
		state=$(node_field State "${run_dir}/node-after.txt")
		cpu=$(node_field CPUAlloc "${run_dir}/node-after.txt")
		mem=$(node_field AllocMem "${run_dir}/node-after.txt")
		if [ "$state" = IDLE ] && [ "$cpu" = 0 ] && [ "$mem" = 0 ] && \
			[ -z "$("$squeue" -h -w "$node_name")" ]; then
			printf 'node_recovered state=%s CPUAlloc=%s AllocMem=%s wait_seconds=%s\n' \
				"$state" "$cpu" "$mem" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	printf 'error: final node state did not recover; state=%s CPUAlloc=%s AllocMem=%s\n' \
		"$state" "$cpu" "$mem" >&2
	return 1
}

if [ "${SMD102_MISMATCH_TEST_CONFIRMED:-NO}" != YES ]; then
	printf 'error: set SMD102_MISMATCH_TEST_CONFIRMED=YES after approving the isolated mismatch test\n' >&2
	exit 64
fi

[ "$(/usr/bin/id -u)" -eq 0 ] || {
	printf 'error: run as root on ubuntu2504\n' >&2
	exit 77
}
[ "$(/usr/bin/uname -s)" = Linux ] || fail 'this driver must run on the Ubuntu controller'
cd /tmp || fail 'cannot change directory to /tmp'

for command_path in /usr/bin/awk /usr/bin/getent /usr/bin/id /usr/bin/sudo \
	/usr/bin/timeout /bin/date /bin/grep /bin/mkdir /bin/sed /bin/sleep; do
	[ -x "$command_path" ] || fail "missing command: $command_path"
done
for command_path in "$scontrol" "$squeue" "$srun" "$scancel" "$sacct"; do
	[ -x "$command_path" ] || fail "missing Slurm command: $command_path"
done

/bin/mkdir -m 0755 "$run_dir" || fail "cannot create run directory: $run_dir"
printf 'run_dir=%s\n' "$run_dir"
printf 'test_identity controller=%s:%s worker_local=%s:%s user=%s\n' \
	"$controller_uid" "$controller_gid" "$worker_uid" "$worker_gid" "$target_user"

trap cleanup_jobs EXIT HUP INT TERM

[ "$(/usr/bin/id -u "$target_user")" = "$controller_uid" ] || \
	fail "$target_user controller UID mismatch"
[ "$(/usr/bin/id -g "$target_user")" = "$controller_gid" ] || \
	fail "$target_user controller GID mismatch"
[ -z "$(/usr/bin/getent passwd "$worker_uid")" ] || \
	fail "worker UID $worker_uid must remain unused on the controller"
[ -z "$(/usr/bin/getent group "$worker_gid")" ] || \
	fail "worker GID $worker_gid must remain unused on the controller"

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || \
	fail 'controller ping failed'
/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || \
	fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" 2>&1 || \
	fail 'node readback failed'
before_state=$(node_field State "${run_dir}/node-before.txt")
before_cpu=$(node_field CPUAlloc "${run_dir}/node-before.txt")
before_mem=$(node_field AllocMem "${run_dir}/node-before.txt")
[ "$before_state" = IDLE ] || fail "node state is $before_state, expected IDLE"
[ "$before_cpu" = 0 ] || fail "node CPUAlloc is $before_cpu, expected 0"
[ "$before_mem" = 0 ] || fail "node AllocMem is $before_mem, expected 0"
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'node queue is not empty'

payload='
printf "SMD102_PAYLOAD_EXECUTED=YES\n"
printf "job_id=%s\n" "${SLURM_JOB_ID:-missing}"
printf "job_user=%s\n" "${SLURM_JOB_USER:-missing}"
printf "actual_uid=%s\n" "$(/usr/bin/id -u)"
printf "actual_gid=%s\n" "$(/usr/bin/id -g)"
actual_user=$(/usr/bin/id -un 2>&1)
actual_user_rc=$?
actual_group=$(/usr/bin/id -gn 2>&1)
actual_group_rc=$?
printf "actual_user=%s rc=%s\n" "$actual_user" "$actual_user_rc"
printf "actual_group=%s rc=%s\n" "$actual_group" "$actual_group_rc"
printf "home=%s\n" "${HOME:-unset}"
printf "cwd=%s\n" "$(/bin/pwd -P)"
exit 86
'

start_time=$(/bin/date '+%Y-%m-%dT%H:%M:%S')
set +e
/usr/bin/sudo -n -u "$target_user" -H /usr/bin/env \
	SLURM_CONF="$slurm_conf" \
	/usr/bin/timeout --signal=TERM --kill-after=10 90 \
	"$srun" --partition="$partition" --nodes=1 --ntasks=1 \
	--cpus-per-task=1 --mem=128M --time=00:01:00 --chdir=/tmp \
	--job-name="$job_name" /bin/sh -c "$payload" \
	>"${run_dir}/srun.out" 2>"${run_dir}/srun.err"
srun_rc=$?
set -u
printf 'srun_rc=%s\n' "$srun_rc"

job_id=$(/usr/bin/awk -F '=' '/^job_id=[0-9]+$/ { print $2; exit }' \
	"${run_dir}/srun.out")
if [ -z "$job_id" ]; then
	job_id=$(/bin/sed -n -E \
		's/.*[Jj]ob([Ii]d)?[ =]([0-9][0-9]*).*/\2/p' \
		"${run_dir}/srun.err" | /usr/bin/awk 'NR == 1 { print; exit }')
fi
case "$job_id" in
''|*[!0-9]*) ;;
*) test_job_ids="$job_id" ;;
esac

accounting_file=${run_dir}/accounting.txt
attempt=0
while [ "$attempt" -lt 30 ]; do
	if [ -n "$job_id" ]; then
		"$sacct" -j "$job_id" -n -P \
			--format=JobIDRaw,JobName,User,State,ExitCode,NodeList \
			>"$accounting_file" 2>"${run_dir}/accounting.err" || true
	else
		"$sacct" -S "$start_time" -u "$target_user" -n -P \
			--name="$job_name" \
			--format=JobIDRaw,JobName,User,State,ExitCode,NodeList \
			>"$accounting_file" 2>"${run_dir}/accounting.err" || true
	fi
	[ -s "$accounting_file" ] && break
	/bin/sleep 1
	attempt=$((attempt + 1))
done

printf '%s\n' '[srun-stdout]'
/bin/cat "${run_dir}/srun.out"
printf '%s\n' '[srun-stderr]'
/bin/cat "${run_dir}/srun.err"
printf '%s\n' '[accounting]'
/bin/cat "$accounting_file"

wait_final_node || fail 'node or resources did not recover after mismatch test'

if /bin/grep -Fqx 'SMD102_PAYLOAD_EXECUTED=YES' "${run_dir}/srun.out"; then
	classification=FAIL_OPEN_PAYLOAD_EXECUTED
else
	classification=PAYLOAD_NOT_EXECUTED_PENDING_ERROR_REVIEW
fi

trap - EXIT HUP INT TERM
printf 'SMD102_OBSERVATION classification=%s srun_rc=%s job_id=%s run_dir=%s\n' \
	"$classification" "$srun_rc" "${job_id:-unknown}" "$run_dir"
