#!/bin/sh

set -u

if [ "${SMD402_OPENMPI_RUNTIME_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD402_OPENMPI_RUNTIME_CONFIRMED=YES after approval' >&2
	exit 64
fi

slurm_prefix=/usr/local/slurm/26.11.0
slurm_conf=${slurm_prefix}/etc/slurm.conf
salloc=${slurm_prefix}/bin/salloc
scontrol=${slurm_prefix}/bin/scontrol
squeue=${slurm_prefix}/bin/squeue
srun=${slurm_prefix}/bin/srun
scancel=${slurm_prefix}/bin/scancel
sacct=${slurm_prefix}/bin/sacct
openmpi_prefix=/tmp/smd402-openmpi-5.0.11/install
mpirun=${openmpi_prefix}/bin/mpirun
prted=${openmpi_prefix}/bin/prted
probe=${openmpi_prefix}/bin/smd402-openmpi-probe
libprrte=${openmpi_prefix}/lib/libprrte.so.3
libmpi=${openmpi_prefix}/lib/libmpi.so.40
libpmix=${openmpi_prefix}/lib/libpmix.so.2
driver_source=/tmp/smd402_openmpi_multinode_runtime_driver.sh
probe_source=/tmp/smd402_openmpi_probe.c
partition=smd402
linux_node=ubuntu
mac_node=PC-210
test_user=testuser
test_uid=3001
test_gid=3001
task_count=2
runtime_path=${openmpi_prefix}/bin:${slurm_prefix}/bin:/usr/bin:/bin
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd402-openmpi-multinode-${run_stamp}
success_name=smd402-ompi-success-${run_stamp}
cancel_name=smd402-ompi-cancel-${run_stamp}
cleanup_name=smd402-ompi-cleanup-${run_stamp}
success_job=
cancel_job=
cleanup_job=
cancel_client_pid=
linux_start_before=
mac_start_before=
ctld_pid_before=
linux_slurmd_pid_before=
success=0

fail()
{
	printf 'error: %s\n' "$*" >&2
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
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		awk 'NR == 1 { print; exit }'
}

discover_job()
{
	job_name=$1
	"$squeue" -h -n "$job_name" -u "$test_user" -o '%A' 2>/dev/null |
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
	state=$(queue_state "$job_id")
	if [ -n "$state" ]; then
		printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state" >&2
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
}

make_evidence_readable()
{
	if [ -d "$run_dir" ]; then
		chmod -R a+rX "$run_dir" >/dev/null 2>&1 || true
	fi
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	[ -n "$success_job" ] || success_job=$(discover_job "$success_name")
	[ -n "$cancel_job" ] || cancel_job=$(discover_job "$cancel_name")
	[ -n "$cleanup_job" ] || cleanup_job=$(discover_job "$cleanup_name")
	cancel_if_active "$success_job"
	cancel_if_active "$cancel_job"
	cancel_if_active "$cleanup_job"
	if [ -n "$cancel_client_pid" ]; then
		kill "$cancel_client_pid" >/dev/null 2>&1 || true
	fi
	make_evidence_readable
	if [ "$success" -ne 1 ]; then
		printf 'recovery: production unchanged; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

root_accounting_success()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" &&
		index($5, "PC-210") && index($5, "ubuntu") { ok = 1 }
		END { exit !ok }
	' "$file"
}

root_accounting_cancel()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && index($3, "CANCELLED") == 1 &&
		index($5, "PC-210") && index($5, "ubuntu") { ok = 1 }
		END { exit !ok }
	' "$file"
}

wait_accounting()
{
	mode=$1
	job_id=$2
	file=$3
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if [ "$mode" = success ]; then
			root_accounting_success "$job_id" "$file" && return 0
		else
			root_accounting_cancel "$job_id" "$file" && return 0
		fi
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

validate_common_output()
{
	prefix=$1
	file=$2
	job_id=$3

	[ "$(grep -Ec "^mpi_${prefix}=PASS " "$file")" -eq "$task_count" ] || \
		fail "$prefix output count mismatch"
	grep -Eq \
		"^mpi_${prefix}=PASS launcher=slurm job_id=${job_id} rank=0 size=2 "\
"bcast=42 allreduce=1 ring_from=1 ring_value=2001 " "$file" || \
		fail "$prefix rank 0 communication mismatch"
	grep -Eq \
		"^mpi_${prefix}=PASS launcher=slurm job_id=${job_id} rank=1 size=2 "\
"bcast=42 allreduce=1 ring_from=0 ring_value=2000 " "$file" || \
		fail "$prefix rank 1 communication mismatch"
	grep -Eq \
		"^mpi_${prefix}=PASS .* processor=[^ ]+ host=ubuntu2504 machine=x86_64 "\
"endian=little pointer=8 long=8 int=4 double=8 pid=[0-9]+ "\
"uid=3001 gid=3001 ompi=5.0.11$" "$file" || \
		fail "$prefix Ubuntu record mismatch"
	grep -Eq \
		"^mpi_${prefix}=PASS .* processor=[^ ]+ host=PC-210\\.local machine=arm64 "\
"endian=little pointer=8 long=8 int=4 double=8 pid=[0-9]+ "\
"uid=3001 gid=3001 ompi=5.0.11$" "$file" || \
		fail "$prefix macOS record mismatch"
}

step_count()
{
	job_id=$1
	file=$2
	awk -F '|' -v job="$job_id" '
		index($1, job ".") == 1 { count++ }
		END { print count + 0 }
	' "$file"
}

related_processes()
{
	ps -eo pid=,ppid=,pgid=,state=,comm=,args= |
		awk -v prefix="$openmpi_prefix" '
			index($0, prefix) &&
			($5 ~ /(^|\/)(mpirun|prted|prterun|smd402-openmpi-probe)$/ ||
			 $6 == prefix "/bin/smd402-openmpi-probe") { print }
		'
}

[ "$(id -u)" -eq 0 ] || fail 'run as root with passwordless sudo'
[ "$(uname -s)" = Linux ] || fail 'run this driver on the Ubuntu controller'
for required in "$driver_source" "$probe_source" "$slurm_conf" "$salloc" \
	"$scontrol" "$squeue" "$srun" "$scancel" "$sacct" "$mpirun" \
	"$prted" "$probe" "$libprrte" "$libmpi" "$libpmix"; do
	[ -e "$required" ] || fail "missing required path=$required"
done
for command in awk chmod cmp date grep id mkdir ps sed sha256sum sleep sort \
	sudo systemctl tr uname wc; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command=$command"
done
[ "$(id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
trap cleanup EXIT HUP INT TERM
printf 'run_dir=%s partition=%s nodes=%s,%s\n' \
	"$run_dir" "$partition" "$linux_node" "$mac_node"

sha256sum "$driver_source" "$probe_source" "$mpirun" "$prted" \
	"$libprrte" "$libmpi" "$libpmix" "$probe" \
	>"${run_dir}/runtime-inputs-before.sha256"
grep -Fqx \
	'3107df430fbed933f555510a4d972497c0a4bb6bb57134d59e0d356bff038c6d  /tmp/smd402-openmpi-5.0.11/install/bin/mpirun' \
	"${run_dir}/runtime-inputs-before.sha256" || fail 'Ubuntu mpirun hash mismatch'
grep -Fqx \
	'cdeb8660f605606ac439856c3b0d60a7dbd503bce8b449ed71e0539928440e0e  /tmp/smd402-openmpi-5.0.11/install/bin/prted' \
	"${run_dir}/runtime-inputs-before.sha256" || fail 'Ubuntu prted hash mismatch'
grep -Fqx \
	'25e388519ecc22a383752cba33afc8a7142e0875e2cd37fe0c8ce9179f09b552  /tmp/smd402-openmpi-5.0.11/install/lib/libprrte.so.3' \
	"${run_dir}/runtime-inputs-before.sha256" || fail 'Ubuntu libprrte hash mismatch'
grep -Fqx \
	'cca982eb7b4cd7f82b6da66d45853fd3c35a8680a0bf96aee9685b312607697f  /tmp/smd402-openmpi-5.0.11/install/lib/libmpi.so.40' \
	"${run_dir}/runtime-inputs-before.sha256" || fail 'Ubuntu libmpi hash mismatch'
grep -Fqx \
	'23c9680c5e7a589eb7f4291acd8509c485b43351a651f5d4d57a36241a9ad0d6  /tmp/smd402-openmpi-5.0.11/install/lib/libpmix.so.2' \
	"${run_dir}/runtime-inputs-before.sha256" || fail 'Ubuntu libpmix hash mismatch'
grep -Fqx \
	'1bcee4f3c229138ad53b9fa3ce17e0e6bfbcbb1382157349b83ed732d3284efd  /tmp/smd402-openmpi-5.0.11/install/bin/smd402-openmpi-probe' \
	"${run_dir}/runtime-inputs-before.sha256" || fail 'Ubuntu probe hash mismatch'

sha256sum "$slurm_conf" "${slurm_prefix}/sbin/slurmd" \
	"${slurm_prefix}/sbin/slurmctld" >"${run_dir}/production-before.sha256"
ctld_pid_before=$(systemctl show slurmctld -p MainPID --value)
linux_slurmd_pid_before=$(systemctl show slurmd -p MainPID --value)
case "$ctld_pid_before:$linux_slurmd_pid_before" in
*[!0-9:]*) fail 'invalid daemon PID before runtime' ;;
esac
[ "$ctld_pid_before" -gt 1 ] || fail 'slurmctld PID is invalid'
[ "$linux_slurmd_pid_before" -gt 1 ] || fail 'Ubuntu slurmd PID is invalid'
[ "$(systemctl is-active slurmctld slurmdbd slurmd munge mariadb | \
	grep -c '^active$')" -eq 5 ] || fail 'Ubuntu service is not active'

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || \
	fail 'controller ping failed'
grep -q ' is UP$' "${run_dir}/controller-before.txt" || \
	fail 'controller is not UP'
"$scontrol" show partition "$partition" \
	>"${run_dir}/partition-before.txt" || fail 'partition readback failed'
grep -Eq 'Nodes=(PC-210,ubuntu|ubuntu,PC-210)' \
	"${run_dir}/partition-before.txt" || fail 'partition node set mismatch'

for node in "$linux_node" "$mac_node"; do
	"$scontrol" show node "$node" >"${run_dir}/node-${node}-before.txt" || \
		fail "cannot read node=$node"
	[ "$(node_field State "${run_dir}/node-${node}-before.txt")" = IDLE ] || \
		fail "node=$node is not IDLE"
	[ "$(node_field CPUAlloc "${run_dir}/node-${node}-before.txt")" = 0 ] || \
		fail "node=$node CPUAlloc is not zero"
	[ "$(node_field AllocMem "${run_dir}/node-${node}-before.txt")" = 0 ] || \
		fail "node=$node AllocMem is not zero"
	[ -z "$(node_field AllocTRES "${run_dir}/node-${node}-before.txt")" ] || \
		fail "node=$node AllocTRES is not empty"
done
[ -z "$("$squeue" -h -w "$linux_node,$mac_node")" ] || \
	fail 'target nodes have active jobs'
linux_start_before=$(node_field SlurmdStartTime \
	"${run_dir}/node-${linux_node}-before.txt")
mac_start_before=$(node_field SlurmdStartTime \
	"${run_dir}/node-${mac_node}-before.txt")
[ -n "$linux_start_before" ] || fail 'missing Ubuntu SlurmdStartTime'
[ -n "$mac_start_before" ] || fail 'missing macOS SlurmdStartTime'
related_processes >"${run_dir}/mpi-processes-before.txt"
[ ! -s "${run_dir}/mpi-processes-before.txt" ] || \
	fail 'MPI-related process exists before runtime'

printf '%s\n' \
	'rank_argument=omitted' \
	'nodes=2' \
	'ntasks=2' \
	'ntasks_per_node=1' \
	'hetero_nodes=true' \
	'pml=ob1' \
	'btl=self,sm,tcp' >"${run_dir}/launch-contract.txt"

sudo -n -H -u "$test_user" env PATH="$runtime_path" SLURM_CONF="$slurm_conf" \
	"$salloc" --partition="$partition" --nodes=2 --ntasks=2 \
	--ntasks-per-node=1 --cpus-per-task=1 --mem=256M --time=00:02:00 \
	--chdir=/tmp --job-name="$success_name" \
	"$mpirun" --hetero-nodes --bind-to none \
	--mca pml ob1 --mca btl self,sm,tcp \
	"$probe" success >"${run_dir}/success.out" 2>"${run_dir}/success.err"
success_rc=$?
[ "$success_rc" -eq 0 ] || fail "success allocation failed rc=$success_rc"
success_job=$(sed -n \
	's/^mpi_runtime=PASS launcher=slurm job_id=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/success.out" | sort -u)
case "$success_job" in
''|*[!0-9]*) fail "invalid success job id=$success_job" ;;
esac
validate_common_output runtime "${run_dir}/success.out" "$success_job"
grep -Fq "Granted job allocation $success_job" "${run_dir}/success.err" || \
	fail 'success allocation grant message missing'
grep -Fq "Relinquishing job allocation $success_job" \
	"${run_dir}/success.err" || fail 'success allocation release message missing'
wait_job_gone "$success_job" || fail 'success job remained queued'
wait_accounting success "$success_job" "${run_dir}/success-sacct.txt" || \
	fail 'success accounting mismatch'
success_step_count=$(step_count "$success_job" "${run_dir}/success-sacct.txt")
related_processes >"${run_dir}/mpi-processes-after-success.txt"
[ ! -s "${run_dir}/mpi-processes-after-success.txt" ] || \
	fail 'MPI-related process remains after success'
printf 'openmpi_multinode_success=PASS job_id=%s ranks=2 nodes=2 steps=%s\n' \
	"$success_job" "$success_step_count"

sudo -n -H -u "$test_user" env PATH="$runtime_path" SLURM_CONF="$slurm_conf" \
	"$salloc" --partition="$partition" --nodes=2 --ntasks=2 \
	--ntasks-per-node=1 --cpus-per-task=1 --mem=256M --time=00:03:00 \
	--chdir=/tmp --job-name="$cancel_name" \
	"$mpirun" --hetero-nodes --bind-to none \
	--mca pml ob1 --mca btl self,sm,tcp \
	"$probe" hold >"${run_dir}/cancel.out" 2>"${run_dir}/cancel.err" &
cancel_client_pid=$!

attempt=0
ready_count=0
while [ "$attempt" -lt 600 ]; do
	ready_count=$(grep -c '^mpi_ready=PASS ' "${run_dir}/cancel.out" \
		2>/dev/null || true)
	[ "$ready_count" -eq "$task_count" ] && break
	kill -0 "$cancel_client_pid" >/dev/null 2>&1 || \
		fail "cancel allocation exited before ready count=$ready_count"
	sleep 0.1
	attempt=$((attempt + 1))
done
[ "$ready_count" -eq "$task_count" ] || fail 'cancel readiness timeout'
cancel_job=$(sed -n \
	's/^mpi_ready=PASS launcher=slurm job_id=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/cancel.out" | sort -u)
case "$cancel_job" in
''|*[!0-9]*) fail "invalid cancel job id=$cancel_job" ;;
esac
[ "$(queue_state "$cancel_job")" = RUNNING ] || \
	fail 'cancel allocation is not RUNNING'
validate_common_output ready "${run_dir}/cancel.out" "$cancel_job"
linux_pid=$(sed -n \
	's/^mpi_ready=PASS .* host=ubuntu2504 .* pid=\([0-9][0-9]*\) .*/\1/p' \
	"${run_dir}/cancel.out")
mac_pid=$(sed -n \
	's/^mpi_ready=PASS .* host=PC-210\.local .* pid=\([0-9][0-9]*\) .*/\1/p' \
	"${run_dir}/cancel.out")
for pid in "$linux_pid" "$mac_pid"; do
	case "$pid" in
	''|*[!0-9]*) fail "invalid cancel pid=$pid" ;;
	esac
done
ps -p "$linux_pid" -o pid=,uid=,ppid=,pgid=,state=,args= \
	>"${run_dir}/ubuntu-rank-before-cancel.txt" || \
	fail 'Ubuntu rank is not alive before cancel'
"$scontrol" show job "$cancel_job" >"${run_dir}/cancel-job-before.txt" || \
	fail 'cannot read cancel job before scancel'
"$scancel" "$cancel_job" >"${run_dir}/scancel.out" \
	2>"${run_dir}/scancel.err" || fail 'cannot cancel allocation'
wait "$cancel_client_pid"
cancel_rc=$?
cancel_client_pid=
case "$cancel_rc" in
0|1|130|137|143) ;;
*) fail "unexpected cancel client rc=$cancel_rc" ;;
esac
grep -Eq "Job allocation ${cancel_job} .*revoked|Relinquishing job allocation ${cancel_job}" \
	"${run_dir}/cancel.err" || fail 'cancel revoke/release message missing'
wait_job_gone "$cancel_job" || fail 'cancel job remained queued'
wait_accounting cancel "$cancel_job" "${run_dir}/cancel-sacct.txt" || \
	fail 'cancel accounting mismatch'
cancel_step_count=$(step_count "$cancel_job" "${run_dir}/cancel-sacct.txt")

sudo -n -H -u "$test_user" env SLURM_CONF="$slurm_conf" \
	SMD402_LINUX_PID="$linux_pid" SMD402_MAC_PID="$mac_pid" \
	"$srun" --partition="$partition" --nodes=2 --ntasks=2 \
	--ntasks-per-node=1 --time=00:01:00 --chdir=/tmp \
	--job-name="$cleanup_name" /bin/sh -c '
		case "$SLURMD_NODENAME" in
		ubuntu) pid=$SMD402_LINUX_PID ;;
		PC-210) pid=$SMD402_MAC_PID ;;
		*) printf "residual=UNKNOWN node=%s\n" "$SLURMD_NODENAME"; exit 98 ;;
		esac
		if /bin/kill -0 "$pid" 2>/dev/null; then
			printf "residual=YES job_id=%s node=%s pid=%s\n" \
				"$SLURM_JOB_ID" "$SLURMD_NODENAME" "$pid"
			exit 99
		fi
		printf "residual=NO job_id=%s node=%s pid=%s\n" \
			"$SLURM_JOB_ID" "$SLURMD_NODENAME" "$pid"
	' >"${run_dir}/pid-probe.out" 2>"${run_dir}/pid-probe.err" || \
	fail 'node-local PID cleanup probe failed'
[ "$(grep -c '^residual=NO ' "${run_dir}/pid-probe.out")" -eq 2 ] || \
	fail 'PID cleanup probe result count mismatch'
grep -Eq "^residual=NO job_id=[0-9]+ node=ubuntu pid=${linux_pid}$" \
	"${run_dir}/pid-probe.out" || fail 'Ubuntu rank PID remains'
grep -Eq "^residual=NO job_id=[0-9]+ node=PC-210 pid=${mac_pid}$" \
	"${run_dir}/pid-probe.out" || fail 'macOS rank PID remains'
cleanup_job=$(sed -n 's/^residual=NO job_id=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/pid-probe.out" | sort -u)
case "$cleanup_job" in
''|*[!0-9]*) fail "invalid cleanup job id=$cleanup_job" ;;
esac
wait_job_gone "$cleanup_job" || fail 'cleanup probe job remained queued'
printf 'openmpi_multinode_cancel=PASS job_id=%s client_rc=%s pids=%s,%s steps=%s cleanup=PASS\n' \
	"$cancel_job" "$cancel_rc" "$linux_pid" "$mac_pid" \
	"$cancel_step_count"

for node in "$linux_node" "$mac_node"; do
	"$scontrol" show node "$node" >"${run_dir}/node-${node}-final.txt" || \
		fail "cannot read final node=$node"
	[ "$(node_field State "${run_dir}/node-${node}-final.txt")" = IDLE ] || \
		fail "final node=$node is not IDLE"
	[ "$(node_field CPUAlloc "${run_dir}/node-${node}-final.txt")" = 0 ] || \
		fail "final node=$node CPUAlloc is not zero"
	[ "$(node_field AllocMem "${run_dir}/node-${node}-final.txt")" = 0 ] || \
		fail "final node=$node AllocMem is not zero"
	[ -z "$(node_field AllocTRES "${run_dir}/node-${node}-final.txt")" ] || \
		fail "final node=$node AllocTRES is not empty"
done
[ "$(node_field SlurmdStartTime \
	"${run_dir}/node-${linux_node}-final.txt")" = "$linux_start_before" ] || \
	fail 'Ubuntu SlurmdStartTime changed'
[ "$(node_field SlurmdStartTime \
	"${run_dir}/node-${mac_node}-final.txt")" = "$mac_start_before" ] || \
	fail 'macOS SlurmdStartTime changed'
[ -z "$("$squeue" -h -w "$linux_node,$mac_node")" ] || \
	fail 'target nodes have jobs after runtime'
[ "$(systemctl show slurmctld -p MainPID --value)" = "$ctld_pid_before" ] || \
	fail 'slurmctld PID changed'
[ "$(systemctl show slurmd -p MainPID --value)" = \
	"$linux_slurmd_pid_before" ] || fail 'Ubuntu slurmd PID changed'
[ "$(systemctl is-active slurmctld slurmdbd slurmd munge mariadb | \
	grep -c '^active$')" -eq 5 ] || fail 'Ubuntu service failed'
related_processes >"${run_dir}/mpi-processes-final.txt"
[ ! -s "${run_dir}/mpi-processes-final.txt" ] || \
	fail 'MPI-related process remains after runtime'

sha256sum "$slurm_conf" "${slurm_prefix}/sbin/slurmd" \
	"${slurm_prefix}/sbin/slurmctld" >"${run_dir}/production-after.sha256"
cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed'
sha256sum "$driver_source" "$probe_source" "$mpirun" "$prted" \
	"$libprrte" "$libmpi" "$libpmix" "$probe" \
	>"${run_dir}/runtime-inputs-after.sha256"
cmp -s "${run_dir}/runtime-inputs-before.sha256" \
	"${run_dir}/runtime-inputs-after.sha256" || fail 'runtime input changed'

printf 'success_step_count=%s\ncancel_step_count=%s\ncleanup_job=%s\n' \
	"$success_step_count" "$cancel_step_count" "$cleanup_job" \
	>"${run_dir}/accounting-shape.txt"
success=1
make_evidence_readable
trap - EXIT HUP INT TERM
printf '%s%s%s%s%s\n' \
	'SMD402_OPENMPI_MULTINODE_COMPLETE' \
	" success_job=$success_job cancel_job=$cancel_job cleanup_job=$cleanup_job" \
	" ranks=2 nodes=$linux_node:x86_64,$mac_node:arm64" \
	" success_steps=$success_step_count cancel_steps=$cancel_step_count" \
	' rank_argument=omitted communication=PASS cancel_cleanup=PASS' \
	" production_unchanged=PASS run_dir=$run_dir"
