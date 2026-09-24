#!/bin/sh

set -u

if [ "${SMD401_PMIX6_MULTINODE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD401_PMIX6_MULTINODE_CONFIRMED=YES after approval' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
ubuntu_plugin=${prefix}/lib/slurm/mpi_pmix_v6.so
probe=/tmp/smd401-pmix6/artifacts/smd401-pmix-probe
partition=smd402
test_user=testuser
test_uid=3001
test_gid=3001
expected_ubuntu_plugin=1c4b8d44eaf8279d24611c52c70e858410e449385a7627bc97b8be6a552668bb
expected_ubuntu_probe=ff8a9d7506d168a1dba4f1f6de4586c395dcadff2ad621eaac2fe15e4c915de1
expected_mac_probe=26be32d73a3f9ced59b1cf3926cfa9efb967a8f4d5e86f3e8f43a8d142f9b6e5
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd401-pmix6-multinode-${run_stamp}
preflight_name=smd401-pmix6-preflight-${run_stamp}
single_name=smd401-pmix6-single-ubuntu-${run_stamp}
success_name=smd401-pmix6-success-${run_stamp}
cancel_name=smd401-pmix6-cancel-${run_stamp}
cleanup_name=smd401-pmix6-cleanup-${run_stamp}
success_job=
single_job=
cancel_job=
cleanup_job=
cancel_client_pid=
success=0

fail()
{
	printf 'SMD401_PMIX6_MULTINODE_FAILED error=%s run_dir=%s\n' \
		"$1" "$run_dir" >&2
	exit 1
}

node_field()
{
	field=$1
	file=$2
	awk -v key="${field}=" '
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
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null | awk 'NR == 1 { print; exit }'
}

discover_job()
{
	"$squeue" -h -n "$1" -u "$test_user" -o '%A' 2>/dev/null | \
		awk 'NR == 1 { print; exit }'
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		[ -z "$(queue_state "$job_id")" ] && return 0
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

cancel_if_active()
{
	job_id=$1
	[ -n "$job_id" ] || return 0
	if [ -n "$(queue_state "$job_id")" ]; then
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	[ -n "$success_job" ] || success_job=$(discover_job "$success_name")
	[ -n "$single_job" ] || single_job=$(discover_job "$single_name")
	[ -n "$cancel_job" ] || cancel_job=$(discover_job "$cancel_name")
	[ -n "$cleanup_job" ] || cleanup_job=$(discover_job "$cleanup_name")
	cancel_if_active "$success_job"
	cancel_if_active "$single_job"
	cancel_if_active "$cancel_job"
	cancel_if_active "$cleanup_job"
	if [ -n "$cancel_client_pid" ]; then
		kill "$cancel_client_pid" >/dev/null 2>&1 || true
	fi
	chmod -R a+rX "$run_dir" >/dev/null 2>&1 || true
	if [ "$success" -ne 1 ]; then
		printf 'recovery: target jobs cancelled; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

wait_accounting()
{
	mode=$1
	job_id=$2
	file=$3
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		"$sacct" -j "$job_id" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES,AllocTRES \
			>"$file" 2>"${file%.txt}.err" || true
		if [ "$mode" = success ]; then
			awk -F '|' -v job="$job_id" -v user="$test_user" '
				$1 == job && $2 == user && $3 == "COMPLETED" &&
				$4 == "0:0" && index($5, "PC-210") &&
				index($5, "ubuntu") { ok = 1 }
				index($1, job ".") == 1 && $3 == "COMPLETED" &&
				$4 == "0:0" { step = 1 }
				END { exit !(ok && step) }
			' "$file" && return 0
		else
			awk -F '|' -v job="$job_id" -v user="$test_user" '
				$1 == job && $2 == user && index($3, "CANCELLED") == 1 &&
				index($5, "PC-210") && index($5, "ubuntu") { ok = 1 }
				index($1, job ".") == 1 && index($3, "CANCELLED") == 1 {
					step = 1
				}
				END { exit !(ok && step) }
			' "$file" && return 0
		fi
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_accounting_single()
{
	job_id=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		"$sacct" -j "$job_id" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES,AllocTRES \
			>"$file" 2>"${file%.txt}.err" || true
		awk -F '|' -v job="$job_id" -v user="$test_user" '
			$1 == job && $2 == user && $3 == "COMPLETED" &&
			$4 == "0:0" && $5 == "ubuntu" { ok = 1 }
			index($1, job ".") == 1 && $3 == "COMPLETED" &&
			$4 == "0:0" { step = 1 }
			END { exit !(ok && step) }
		' "$file" && return 0
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(uname -s)" = Linux ] || fail 'run on Ubuntu controller'
for path in "$slurm_conf" "$scontrol" "$squeue" "$srun" "$scancel" \
	"$sacct" "$ubuntu_plugin" "$probe"; do
	[ -e "$path" ] || fail "missing prerequisite: $path"
done
[ "$(sha256sum "$ubuntu_plugin" | awk '{print $1}')" = \
	"$expected_ubuntu_plugin" ] || fail 'Ubuntu plugin hash mismatch'
[ "$(sha256sum "$probe" | awk '{print $1}')" = \
	"$expected_ubuntu_probe" ] || fail 'Ubuntu probe hash mismatch'
[ "$(id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
trap cleanup EXIT HUP INT TERM
sha256sum "$slurm_conf" "${prefix}/sbin/slurmd" \
	"${prefix}/sbin/slurmctld" "$ubuntu_plugin" "$probe" \
	>"${run_dir}/inputs-before.sha256"
ctld_pid_before=$(systemctl show slurmctld -p MainPID --value)
linux_slurmd_pid_before=$(systemctl show slurmd -p MainPID --value)
mac_slurmd_pid_before=$(
	"$scontrol" show node PC-210 -o | sed -n \
		's/.*SlurmdStartTime=\([^ ]*\).*/\1/p'
)
[ "$(systemctl is-active slurmctld slurmdbd slurmd | grep -c '^active$')" \
	-eq 3 ] || fail 'Slurm service is not active'
"$srun" --mpi=list >"${run_dir}/mpi-list.txt" \
	2>"${run_dir}/mpi-list.err"
grep -F 'specific pmix plugin versions available: pmix_v6' \
	"${run_dir}/mpi-list.txt" >/dev/null || fail 'pmix_v6 is not listed'
[ ! -s "${run_dir}/mpi-list.err" ] || fail 'mpi list emitted stderr'

for node in ubuntu PC-210; do
	"$scontrol" show node "$node" >"${run_dir}/node-${node}-before.txt" || \
		fail "cannot read node=$node"
	[ "$(node_field State "${run_dir}/node-${node}-before.txt")" = IDLE ] || \
		fail "node=$node is not IDLE"
	[ "$(node_field CPUAlloc "${run_dir}/node-${node}-before.txt")" = 0 ] || \
		fail "node=$node is allocated"
done
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'target queue is not empty'

sudo -n -H -u "$test_user" env SLURM_CONF="$slurm_conf" \
	"$srun" --partition="$partition" --nodes=2 --ntasks=2 \
	--ntasks-per-node=1 --mpi=none --label --time=00:01:00 \
	--chdir=/tmp --job-name="$preflight_name" /bin/sh -c '
		probe=/tmp/smd401-pmix6/artifacts/smd401-pmix-probe
		printf "probe_preflight=PASS node=%s machine=%s sha256=" \
			"$(hostname)" "$(uname -m)"
		if command -v sha256sum >/dev/null 2>&1; then
			sha256sum "$probe" | awk "{print \$1}"
		else
			shasum -a 256 "$probe" | awk "{print \$1}"
		fi
	' >"${run_dir}/probe-preflight.out" \
	2>"${run_dir}/probe-preflight.err" || fail 'dual-node probe preflight failed'
[ "$(grep -c 'probe_preflight=PASS' "${run_dir}/probe-preflight.out")" -eq 2 ] || \
	fail 'probe preflight output count mismatch'
grep -Eq "node=ubuntu2504 machine=x86_64 sha256=${expected_ubuntu_probe}" \
	"${run_dir}/probe-preflight.out" || fail 'Ubuntu probe preflight mismatch'
grep -Eq "node=PC-210\\.local machine=arm64 sha256=${expected_mac_probe}" \
	"${run_dir}/probe-preflight.out" || fail 'Mac probe preflight mismatch'
[ ! -s "${run_dir}/probe-preflight.err" ] || fail 'probe preflight stderr is not empty'

# Gate the corrected Ubuntu plugin locally before another multi-node attempt.
sudo -n -H -u "$test_user" env SLURM_CONF="$slurm_conf" \
	"$srun" --partition="$partition" --nodelist=ubuntu --nodes=1 --ntasks=1 \
	--mpi=pmix_v6 --label --time=00:01:00 --chdir=/tmp \
	--job-name="$single_name" \
	"$probe" success >"${run_dir}/single-ubuntu.out" \
	2>"${run_dir}/single-ubuntu.err"
single_rc=$?
[ "$single_rc" -eq 0 ] || fail "Ubuntu single-node PMIx gate failed rc=$single_rc"
single_job=$(sed -n 's/.*pmix_runtime=PASS job_id=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/single-ubuntu.out" | sort -u)
case "$single_job" in
''|*[!0-9]*) fail "invalid Ubuntu single-node job id=$single_job" ;;
esac
grep -Eq "pmix_runtime=PASS job_id=${single_job} nspace=[^ ]+ rank=0 size=1 value=42 fence=PASS" \
	"${run_dir}/single-ubuntu.out" || fail 'Ubuntu single-node PMIx result mismatch'
[ ! -s "${run_dir}/single-ubuntu.err" ] || \
	fail 'Ubuntu single-node PMIx stderr is not empty'
wait_job_gone "$single_job" || fail 'Ubuntu single-node PMIx job remained queued'
wait_accounting_single "$single_job" "${run_dir}/single-ubuntu-sacct.txt" || \
	fail 'Ubuntu single-node PMIx accounting mismatch'

sudo -n -H -u "$test_user" env SLURM_CONF="$slurm_conf" \
	"$srun" --partition="$partition" --nodes=2 --ntasks=2 \
	--ntasks-per-node=1 --mpi=pmix_v6 --label --time=00:02:00 \
	--chdir=/tmp --job-name="$success_name" /bin/sh -c '
		printf "placement=PASS node=%s machine=%s task=%s pid=%s\n" \
			"$(hostname)" "$(uname -m)" "$SLURM_PROCID" "$$"
		exec /tmp/smd401-pmix6/artifacts/smd401-pmix-probe success
	' >"${run_dir}/success.out" 2>"${run_dir}/success.err"
success_rc=$?
[ "$success_rc" -eq 0 ] || fail "success job failed rc=$success_rc"
success_job=$(sed -n 's/.*pmix_runtime=PASS job_id=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/success.out" | sort -u)
case "$success_job" in
''|*[!0-9]*) fail "invalid success job id=$success_job" ;;
esac
[ "$(grep -c 'pmix_runtime=PASS' "${run_dir}/success.out")" -eq 2 ] || \
	fail 'success PMIx output count mismatch'
grep -Eq 'placement=PASS node=ubuntu2504 machine=x86_64 task=[01] ' \
	"${run_dir}/success.out" || fail 'Ubuntu success placement missing'
grep -Eq 'placement=PASS node=PC-210\.local machine=arm64 task=[01] ' \
	"${run_dir}/success.out" || fail 'Mac success placement missing'
for rank in 0 1; do
	grep -Eq "pmix_runtime=PASS job_id=${success_job} nspace=[^ ]+ rank=${rank} size=2 value=42 fence=PASS" \
		"${run_dir}/success.out" || fail "success rank=$rank mismatch"
done
nspace_count=$(sed -n 's/.* nspace=\([^ ]*\) rank=.*/\1/p' \
	"${run_dir}/success.out" | sort -u | wc -l | tr -d ' ')
[ "$nspace_count" -eq 1 ] || fail 'success namespace mismatch'
[ ! -s "${run_dir}/success.err" ] || fail 'success stderr is not empty'
wait_job_gone "$success_job" || fail 'success job remained queued'
wait_accounting success "$success_job" "${run_dir}/success-sacct.txt" || \
	fail 'success accounting mismatch'

sudo -n -H -u "$test_user" env SLURM_CONF="$slurm_conf" \
	"$srun" --partition="$partition" --nodes=2 --ntasks=2 \
	--ntasks-per-node=1 --mpi=pmix_v6 --label --time=00:03:00 \
	--chdir=/tmp --job-name="$cancel_name" /bin/sh -c '
		base=/tmp/smd401-pmix6-ready-${SLURM_JOB_ID}-${SLURM_PROCID}
		mkdir -m 0700 "$base" || exit 92
		/tmp/smd401-pmix6/artifacts/smd401-pmix-probe hold "$base" &
		probe_pid=$!
		attempt=0
		ready=$base/ready.${SLURM_PROCID}
		while [ "$attempt" -lt 600 ] && [ ! -f "$ready" ]; do
			kill -0 "$probe_pid" 2>/dev/null || exit 93
			sleep 0.1
			attempt=$((attempt + 1))
		done
		[ -f "$ready" ] || exit 94
		. "$ready"
		printf "pmix_ready=PASS node=%s machine=%s job_id=%s nspace=%s rank=%s size=%s fence=%s pid=%s uid=%s gid=%s ready_dir=%s\n" \
			"$(hostname)" "$(uname -m)" "$job_id" "$nspace" "$rank" \
			"$size" "$fence" "$pid" "$uid" "$gid" "$base"
		wait "$probe_pid"
	' >"${run_dir}/cancel.out" 2>"${run_dir}/cancel.err" &
cancel_client_pid=$!

attempt=0
ready_count=0
while [ "$attempt" -lt 600 ]; do
	ready_count=$(grep -c 'pmix_ready=PASS' "${run_dir}/cancel.out" \
		2>/dev/null || true)
	[ "$ready_count" -eq 2 ] && break
	kill -0 "$cancel_client_pid" >/dev/null 2>&1 || \
		fail "cancel client exited before ready count=$ready_count"
	sleep 0.1
	attempt=$((attempt + 1))
done
[ "$ready_count" -eq 2 ] || fail 'cancel readiness timeout'
cancel_job=$(sed -n 's/.*pmix_ready=PASS .* job_id=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/cancel.out" | sort -u)
case "$cancel_job" in
''|*[!0-9]*) fail "invalid cancel job id=$cancel_job" ;;
esac
[ "$(queue_state "$cancel_job")" = RUNNING ] || fail 'cancel job is not RUNNING'
grep -Eq "pmix_ready=PASS node=ubuntu2504 machine=x86_64 job_id=${cancel_job} .* rank=[01] size=2 fence=PASS .* uid=${test_uid} gid=${test_gid} " \
	"${run_dir}/cancel.out" || fail 'Ubuntu cancel readiness mismatch'
grep -Eq "pmix_ready=PASS node=PC-210\\.local machine=arm64 job_id=${cancel_job} .* rank=[01] size=2 fence=PASS .* uid=${test_uid} gid=${test_gid} " \
	"${run_dir}/cancel.out" || fail 'Mac cancel readiness mismatch'
cancel_nspace_count=$(sed -n 's/.* nspace=\([^ ]*\) rank=.*/\1/p' \
	"${run_dir}/cancel.out" | sort -u | wc -l | tr -d ' ')
[ "$cancel_nspace_count" -eq 1 ] || fail 'cancel namespace mismatch'
linux_pid=$(sed -n 's/.*node=ubuntu2504 .* pid=\([0-9][0-9]*\) .*/\1/p' \
	"${run_dir}/cancel.out")
mac_pid=$(sed -n 's/.*node=PC-210\.local .* pid=\([0-9][0-9]*\) .*/\1/p' \
	"${run_dir}/cancel.out")
linux_ready=$(sed -n 's/.*node=ubuntu2504 .* ready_dir=\([^ ]*\).*/\1/p' \
	"${run_dir}/cancel.out")
mac_ready=$(sed -n 's/.*node=PC-210\.local .* ready_dir=\([^ ]*\).*/\1/p' \
	"${run_dir}/cancel.out")
for value in "$linux_pid" "$mac_pid"; do
	case "$value" in ''|*[!0-9]*) fail "invalid cancel pid=$value" ;; esac
done
"$scancel" "$cancel_job" >"${run_dir}/scancel.out" \
	2>"${run_dir}/scancel.err" || fail 'cannot cancel PMIx job'
set +e
wait "$cancel_client_pid"
cancel_rc=$?
set -e
cancel_client_pid=
case "$cancel_rc" in 0|1|130|137|143) ;; *) fail "unexpected cancel rc=$cancel_rc" ;; esac
wait_job_gone "$cancel_job" || fail 'cancel job remained queued'
wait_accounting cancel "$cancel_job" "${run_dir}/cancel-sacct.txt" || \
	fail 'cancel accounting mismatch'

sudo -n -H -u "$test_user" env SLURM_CONF="$slurm_conf" \
	SMD401_LINUX_PID="$linux_pid" SMD401_MAC_PID="$mac_pid" \
	SMD401_LINUX_READY="$linux_ready" SMD401_MAC_READY="$mac_ready" \
	"$srun" --partition="$partition" --nodes=2 --ntasks=2 \
	--ntasks-per-node=1 --mpi=none --label --time=00:01:00 \
	--chdir=/tmp --job-name="$cleanup_name" /bin/sh -c '
		case "$SLURMD_NODENAME" in
		ubuntu) pid=$SMD401_LINUX_PID; ready=$SMD401_LINUX_READY ;;
		PC-210) pid=$SMD401_MAC_PID; ready=$SMD401_MAC_READY ;;
		*) exit 95 ;;
		esac
		case "$ready" in /tmp/smd401-pmix6-ready-*) ;; *) exit 96 ;; esac
		if kill -0 "$pid" 2>/dev/null; then
			printf "residual=YES node=%s pid=%s\n" "$SLURMD_NODENAME" "$pid"
			exit 97
		fi
		find "$ready" -type f -delete 2>/dev/null || true
		rmdir "$ready" 2>/dev/null || true
		printf "residual=NO job_id=%s node=%s pid=%s ready_removed=%s\n" \
			"$SLURM_JOB_ID" "$SLURMD_NODENAME" "$pid" "$ready"
	' >"${run_dir}/cleanup.out" 2>"${run_dir}/cleanup.err" || \
	fail 'node-local cleanup probe failed'
[ "$(grep -c 'residual=NO' "${run_dir}/cleanup.out")" -eq 2 ] || \
	fail 'cleanup result count mismatch'
cleanup_job=$(sed -n 's/.*residual=NO job_id=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/cleanup.out" | sort -u)
case "$cleanup_job" in
''|*[!0-9]*) fail "invalid cleanup job id=$cleanup_job" ;;
esac

for node in ubuntu PC-210; do
	"$scontrol" show node "$node" >"${run_dir}/node-${node}-final.txt" || \
		fail "cannot read final node=$node"
	[ "$(node_field State "${run_dir}/node-${node}-final.txt")" = IDLE ] || \
		fail "final node=$node is not IDLE"
	[ "$(node_field CPUAlloc "${run_dir}/node-${node}-final.txt")" = 0 ] || \
		fail "final node=$node is allocated"
done
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'final target queue is not empty'
[ "$(systemctl show slurmctld -p MainPID --value)" = "$ctld_pid_before" ] || \
	fail 'slurmctld PID changed'
[ "$(systemctl show slurmd -p MainPID --value)" = "$linux_slurmd_pid_before" ] || \
	fail 'Ubuntu slurmd PID changed during runtime'
mac_slurmd_pid_after=$(
	"$scontrol" show node PC-210 -o | sed -n \
		's/.*SlurmdStartTime=\([^ ]*\).*/\1/p'
)
[ "$mac_slurmd_pid_after" = "$mac_slurmd_pid_before" ] || \
	fail 'Mac SlurmdStartTime changed during runtime'
sha256sum "$slurm_conf" "${prefix}/sbin/slurmd" \
	"${prefix}/sbin/slurmctld" "$ubuntu_plugin" "$probe" \
	>"${run_dir}/inputs-after.sha256"
cmp -s "${run_dir}/inputs-before.sha256" \
	"${run_dir}/inputs-after.sha256" || fail 'runtime input changed'

success=1
chmod -R a+rX "$run_dir"
trap - EXIT HUP INT TERM
printf '%s%s%s%s%s\n' \
	'SMD401_PMIX6_MULTINODE_COMPLETE' \
	" single_job=$single_job success_job=$success_job cancel_job=$cancel_job cleanup_job=$cleanup_job" \
	' nodes=ubuntu:x86_64,PC-210:arm64 ranks=2' \
	" cancel_rc=$cancel_rc communication=PMIX_PUT_GET_FENCE_PASS pmix_direct_conn=enabled" \
	" cancel_cleanup=PASS production_unchanged=PASS run_dir=$run_dir"
