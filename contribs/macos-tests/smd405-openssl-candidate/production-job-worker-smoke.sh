#!/bin/sh

# Post-failback production smoke for SMD-405. Submit one short CPU job to each
# worker as the existing unprivileged testuser, then verify execution,
# accounting, resource release, and controller/worker health.

set -u
umask 077

if [ "${SMD405_OPENSSL_JOB_SMOKE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_OPENSSL_JOB_SMOKE_CONFIRMED=YES after approving two production smoke jobs' >&2
	exit 64
fi

PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib/slurm:/usr/local/slurm/26.11.0/lib
SLURM_CONF=/usr/local/slurm/26.11.0/etc/slurm.conf
export PATH LD_LIBRARY_PATH SLURM_CONF

run_stamp=${RUN_STAMP:-}
case "$run_stamp" in
''|*[!0-9T]*) printf 'error: invalid RUN_STAMP=%s\n' "$run_stamp" >&2; exit 64 ;;
esac

[ "$(hostname -s)" = ubuntu2504 ] || {
	printf 'error: unexpected hostname=%s\n' "$(hostname -s)" >&2
	exit 64
}
[ "$(id -u)" -eq 0 ] || {
	printf '%s\n' 'error: must run as root' >&2
	exit 64
}

prefix=/usr/local/slurm/26.11.0
run_dir=/var/tmp/smd405-openssl-job-worker-smoke-${run_stamp}
partition=smd402
expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
new_libslurmfull=791fa00eff4b949cfbb667fc250fc9b40e2e096f7494ad0d763138d62fea9391
new_auth_slurm=536b07689bedad94cc8e663682b85db0d4e42391a86cc499e4f5895247ff3ee9
new_auth_jwt=686057ecdca7c6476ddf44fefdb3b90014bf208fde39e759f2cf0c55e15f7167
active_jobs=
success=0

fail()
{
	printf 'SMD405_OPENSSL_JOB_WORKER_SMOKE_FAILED error=%s run_dir=%s\n' \
		"$1" "$run_dir" >&2
	exit 1
}

file_hash()
{
	sha256sum "$1" | awk '{print $1}'
}

testuser_command()
{
	/usr/sbin/runuser -u testuser -- env \
		HOME=/tmp \
		PATH=$PATH \
		LD_LIBRARY_PATH=$LD_LIBRARY_PATH \
		SLURM_CONF=$SLURM_CONF \
		"$@"
}

cleanup_on_exit()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ]; then
		for job_id in $active_jobs; do
			testuser_command "${prefix}/bin/scancel" "$job_id" >/dev/null 2>&1 || true
		done
	fi
	exit "$rc"
}

wait_job()
{
	job_id=$1
	label=$2
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		attempt=$((attempt + 1))
		"${prefix}/bin/sacct" -X -n -P -j "$job_id" \
			-o JobIDRaw,JobName,State,ExitCode,NodeList \
			>"${run_dir}/${label}.sacct" 2>&1 || true
		state=$(awk -F'|' -v id="$job_id" '$1 == id { print $3; exit }' \
			"${run_dir}/${label}.sacct")
		case "$state" in
		COMPLETED) return 0 ;;
		FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|BOOT_FAIL|DEADLINE|PREEMPTED|REVOKED)
			return 1
			;;
	esac
		sleep 1
	done
	return 1
}

run_job()
{
	node=$1
	label=$2
	job_name=smd405-${label}-${run_stamp}
	run_rc=0
	/usr/bin/timeout --signal=TERM --kill-after=10 150 \
		/usr/sbin/runuser -u testuser -- env \
		HOME=/tmp \
		PATH=$PATH \
		LD_LIBRARY_PATH=$LD_LIBRARY_PATH \
		SLURM_CONF=$SLURM_CONF \
		"${prefix}/bin/srun" \
		--immediate=30 \
		--partition="$partition" \
		--nodelist="$node" \
		--nodes=1 \
		--ntasks=1 \
		--cpus-per-task=1 \
		--time=00:02:00 \
		--job-name="$job_name" \
		/bin/sh -c '/bin/hostname; /usr/bin/uname -m' \
		>"${run_dir}/${label}.out" 2>"${run_dir}/${label}.err" || run_rc=$?
	job_id=
	discovery_attempt=0
	while [ "$discovery_attempt" -lt 30 ]; do
		discovery_attempt=$((discovery_attempt + 1))
		"${prefix}/bin/sacct" -X -n -P -S now-1hour --name="$job_name" \
			-o JobIDRaw,JobName,State,ExitCode,NodeList \
			>"${run_dir}/${label}.sacct" 2>&1 || true
		job_id=$(awk -F'|' -v name="$job_name" '
			$1 ~ /^[0-9]+$/ && $2 == name { id = $1 }
			END { print id }
		' "${run_dir}/${label}.sacct")
		[ -n "$job_id" ] && break
		sleep 1
	done
	case "$job_id" in
	''|*[!0-9]*) fail "cannot resolve job id node=${node} srun_rc=${run_rc}" ;;
	esac
	active_jobs="$active_jobs $job_id"
	[ "$run_rc" -eq 0 ] || fail "srun failed node=${node} job=${job_id} rc=${run_rc}"
	wait_job "$job_id" "$label" || fail "job did not complete node=${node} job=${job_id}"
	executed_job_id=$job_id
}

[ ! -e "$run_dir" ] || fail 'run directory already exists'
getent passwd testuser >/dev/null 2>&1 || \
	fail 'testuser account is absent'
[ -x /usr/bin/timeout ] || fail 'timeout command is absent'
install -d -o root -g root -m 0700 "$run_dir" || fail 'cannot create evidence directory'

[ "$(file_hash "${prefix}/etc/slurm.conf")" = "$expected_config" ] || \
	fail 'production config hash mismatch'
[ "$(file_hash "${prefix}/sbin/slurmctld")" = "$expected_binary" ] || \
	fail 'production slurmctld hash mismatch'
[ "$(file_hash "${prefix}/lib/slurm/libslurmfull.so")" = "$new_libslurmfull" ] || \
	fail 'primary libslurmfull is not fixed candidate'
[ "$(file_hash "${prefix}/lib/slurm/auth_slurm.so")" = "$new_auth_slurm" ] || \
	fail 'primary auth_slurm is not fixed candidate'
[ "$(file_hash "${prefix}/lib/slurm/auth_jwt.so")" = "$new_auth_jwt" ] || \
	fail 'primary auth_jwt is not fixed candidate'
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service" 2>/dev/null || true)" = active ] || \
		fail "service is not active service=${service}"
done

"${prefix}/bin/scontrol" ping >"${run_dir}/before-ping.txt" 2>&1 || \
	fail 'controller ping failed before jobs'
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' "${run_dir}/before-ping.txt" || \
	fail 'primary is not UP before jobs'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' "${run_dir}/before-ping.txt" || \
	fail 'backup is not UP before jobs'
[ -z "$("${prefix}/bin/squeue" -h)" ] || fail 'queue is not empty before jobs'
partition_output=$("${prefix}/bin/scontrol" show partition "$partition" -o) || \
	fail "cannot inspect partition=${partition}"
printf '%s\n' "$partition_output" >"${run_dir}/partition.txt"
printf '%s\n' "$partition_output" | grep -Fq 'State=UP' || \
	fail "partition is not UP partition=${partition}"
printf '%s\n' "$partition_output" | grep -Eq \
	'Nodes=(PC-210,ubuntu|ubuntu,PC-210)([[:space:]]|$)' || \
	fail "partition does not contain both workers partition=${partition}"
for node in ubuntu PC-210; do
	node_output=$("${prefix}/bin/scontrol" show node "$node") || fail "cannot inspect node=${node}"
	printf '%s\n' "$node_output" >"${run_dir}/before-node-${node}.txt"
	printf '%s\n' "$node_output" | grep -Eq \
		'(^|[[:space:]])State=IDLE([[:space:]]|$)' || fail "node is not IDLE node=${node}"
	printf '%s\n' "$node_output" | grep -Eq \
		'(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' || fail "node is allocated node=${node}"
done

trap cleanup_on_exit EXIT HUP INT TERM

run_job ubuntu ubuntu
ubuntu_job=$executed_job_id
run_job PC-210 mac
mac_job=$executed_job_id

grep -Fq 'x86_64' "${run_dir}/ubuntu.out" || \
	fail "Ubuntu job architecture output mismatch job=${ubuntu_job}"
grep -Eq 'ubuntu|ubuntu2504' "${run_dir}/ubuntu.out" || \
	fail "Ubuntu job hostname output mismatch job=${ubuntu_job}"
grep -Fq 'arm64' "${run_dir}/mac.out" || \
	fail "Mac job architecture output mismatch job=${mac_job}"
grep -Fq 'PC-210' "${run_dir}/mac.out" || \
	fail "Mac job hostname output mismatch job=${mac_job}"

"${prefix}/bin/scontrol" ping >"${run_dir}/after-ping.txt" 2>&1 || \
	fail 'controller ping failed after jobs'
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' "${run_dir}/after-ping.txt" || \
	fail 'primary is not UP after jobs'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' "${run_dir}/after-ping.txt" || \
	fail 'backup is not UP after jobs'
[ -z "$("${prefix}/bin/squeue" -h)" ] || fail 'queue is not empty after jobs'
for node in ubuntu PC-210; do
	node_output=$("${prefix}/bin/scontrol" show node "$node") || fail "cannot reinspect node=${node}"
	printf '%s\n' "$node_output" >"${run_dir}/after-node-${node}.txt"
	printf '%s\n' "$node_output" | grep -Eq \
		'(^|[[:space:]])State=IDLE([[:space:]]|$)' || fail "node did not return IDLE node=${node}"
	printf '%s\n' "$node_output" | grep -Eq \
		'(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' || fail "node allocation remains node=${node}"
done
"${prefix}/bin/sacctmgr" ping >"${run_dir}/slurmdbd-ping.txt" 2>&1 || fail 'slurmdbd ping failed'
grep -Fq ' is UP' "${run_dir}/slurmdbd-ping.txt" || fail 'slurmdbd is not UP'

success=1
trap - EXIT HUP INT TERM
printf 'SMD405_OPENSSL_JOB_WORKER_SMOKE_PASS partition=%s ubuntu_job=%s ubuntu_arch=x86_64 mac_job=%s mac_arch=arm64 user=testuser accounting=COMPLETED queue=EMPTY nodes=IDLE controllers=BOTH_UP slurmdbd=UP run_dir=%s\n' \
	"$partition" "$ubuntu_job" "$mac_job" "$run_dir"
