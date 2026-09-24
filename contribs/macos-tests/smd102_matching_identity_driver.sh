#!/bin/sh

set -u

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
target_user=testuser
target_uid=3001
target_gid=3001
node_name=PC-210
partition=debug
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd102-matching-${run_stamp}
job_name=smd102-matching-${run_stamp}
job_id=

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

cleanup_job()
{
	case "$job_id" in
	''|*[!0-9]*) return ;;
	esac
	if [ -n "$("$squeue" -h -j "$job_id" -o '%T' 2>/dev/null)" ]; then
		printf 'cleanup job_id=%s\n' "$job_id" >&2
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
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
	return 1
}

if [ "${SMD102_MATCHING_TEST_CONFIRMED:-NO}" != YES ]; then
	printf 'error: set SMD102_MATCHING_TEST_CONFIRMED=YES after approving one matching-identity smoke job\n' >&2
	exit 64
fi
[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root on the Ubuntu controller'
[ "$(/usr/bin/uname -s)" = Linux ] || fail 'this driver must run on the Ubuntu controller'
cd /tmp || fail 'cannot change directory to /tmp'

for path in "$scontrol" "$squeue" "$srun" "$scancel" "$sacct"; do
	[ -x "$path" ] || fail "missing Slurm command: $path"
done
[ "$(/usr/bin/id -u "$target_user")" = "$target_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$target_user")" = "$target_gid" ] || fail 'testuser GID mismatch'

/bin/mkdir -m 0755 "$run_dir" || fail "cannot create run directory: $run_dir"
printf 'run_dir=%s\n' "$run_dir"
trap cleanup_job EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" 2>&1 || \
	fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'node queue is not empty'

payload='
printf "SMD102_MATCHING_PAYLOAD_EXECUTED=YES\n"
printf "job_id=%s\n" "${SLURM_JOB_ID:-missing}"
printf "hostname=%s\n" "$(/bin/hostname)"
printf "actual_user=%s\n" "$(/usr/bin/id -un)"
printf "actual_uid=%s\n" "$(/usr/bin/id -u)"
printf "actual_gid=%s\n" "$(/usr/bin/id -g)"
'

set +e
/usr/bin/sudo -n -u "$target_user" -H /usr/bin/env SLURM_CONF="$slurm_conf" \
	/usr/bin/timeout --signal=TERM --kill-after=10 90 \
	"$srun" --partition="$partition" --nodelist="$node_name" \
	--nodes=1 --ntasks=1 --cpus-per-task=1 --mem=64M --time=00:01:00 \
	--chdir=/tmp --job-name="$job_name" /bin/sh -c "$payload" \
	>"${run_dir}/srun.out" 2>"${run_dir}/srun.err"
srun_rc=$?
set -u
printf 'srun_rc=%s\n' "$srun_rc"

job_id=$(/usr/bin/awk -F '=' '/^job_id=[0-9]+$/ { print $2; exit }' \
	"${run_dir}/srun.out")
case "$job_id" in
''|*[!0-9]*) fail 'could not obtain job ID from matching payload' ;;
esac

attempt=0
while [ "$attempt" -lt 30 ]; do
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,JobName,User,State,ExitCode,NodeList \
		>"${run_dir}/accounting.txt" 2>"${run_dir}/accounting.err" || true
	if /usr/bin/awk -F '|' -v job="$job_id" -v user="$target_user" '
		$1 == job && $3 == user && $4 == "COMPLETED" && $5 == "0:0" { root_ok = 1 }
		$1 == job ".0" && $4 == "COMPLETED" && $5 == "0:0" { step_ok = 1 }
		END { exit !(root_ok && step_ok) }
	' "${run_dir}/accounting.txt"; then
		break
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done

printf '%s\n' '[srun-stdout]'
/bin/cat "${run_dir}/srun.out"
printf '%s\n' '[srun-stderr]'
/bin/cat "${run_dir}/srun.err"
printf '%s\n' '[accounting]'
/bin/cat "${run_dir}/accounting.txt"

[ "$srun_rc" -eq 0 ] || fail "srun failed rc=$srun_rc"
/bin/grep -Fqx 'SMD102_MATCHING_PAYLOAD_EXECUTED=YES' "${run_dir}/srun.out" || \
	fail 'matching payload marker is missing'
/bin/grep -Eq '^hostname=PC-210(\.local)?$' "${run_dir}/srun.out" || \
	fail 'matching payload hostname mismatch'
/bin/grep -Fqx 'actual_user=testuser' "${run_dir}/srun.out" || fail 'user mismatch'
/bin/grep -Fqx 'actual_uid=3001' "${run_dir}/srun.out" || fail 'UID mismatch'
/bin/grep -Fqx 'actual_gid=3001' "${run_dir}/srun.out" || fail 'GID mismatch'
/usr/bin/awk -F '|' -v job="$job_id" -v user="$target_user" '
	$1 == job && $3 == user && $4 == "COMPLETED" && $5 == "0:0" { root_ok = 1 }
	$1 == job ".0" && $4 == "COMPLETED" && $5 == "0:0" { step_ok = 1 }
	END { exit !(root_ok && step_ok) }
' "${run_dir}/accounting.txt" || fail 'matching job accounting mismatch'
wait_final_node || fail 'node or resources did not recover after matching smoke'

trap - EXIT HUP INT TERM
printf 'SMD102_MATCHING_SMOKE_PASS job_id=%s run_dir=%s\n' "$job_id" "$run_dir"
