#!/bin/sh

set -u

if [ "${SMD401_PMI2_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD401_PMI2_CONFIRMED=YES after accepting two allocations' >&2
	exit 64
fi

source_root=/Users/REDACTED_USER/dev/slurm.26-05
source_wrapper=${source_root}/contribs/macos-tests/smd401_pmi2_wrapper.sh
source_driver=${source_root}/contribs/macos-tests/smd401_pmi2_driver.sh
probe_source=${source_root}/contribs/pmi2/testpmi2_put.c
hold_source=${source_root}/contribs/macos-tests/smd401_pmi2_hold.c
pmi2_archive=${source_root}/contribs/pmi2/.libs/libpmi2.a
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
mpi_plugin=${prefix}/lib/slurm/mpi_pmi2.so
pid_file=/var/run/slurmd.pid
slurmd_log=/var/log/slurm/slurmd.log
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
task_count=4
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd401-${run_stamp}
record_dir=${run_dir}/records
client_conf=${run_dir}/slurm-client.conf
wrapper=${run_dir}/pmi2-wrapper.sh
probe=${run_dir}/testpmi2-put
hold_probe=${run_dir}/smd401-pmi2-hold
success_name=smd401-success-${run_stamp}
cancel_name=smd401-cancel-${run_stamp}
success_job=
cancel_job=
success_client_pid=
cancel_client_pid=
slurmd_pid=
slurmd_start=
log_start_line=1
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

discover_job()
{
	job_name=$1
	"$squeue" -h -n "$job_name" -u "$test_user" -o '%A' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }'
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		[ -z "$(queue_state "$job_id")" ] && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_process_gone()
{
	pid=$1
	attempt=0
	while [ "$attempt" -lt 100 ]; do
		/bin/ps -p "$pid" -o pid= >/dev/null 2>&1 || return 0
		/bin/sleep 0.1
		attempt=$((attempt + 1))
	done
	return 1
}

cancel_job_if_active()
{
	job_id=$1
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state" >&2
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ -z "$success_job" ]; then
		success_job=$(discover_job "$success_name")
	fi
	if [ -z "$cancel_job" ]; then
		cancel_job=$(discover_job "$cancel_name")
	fi
	cancel_job_if_active "$success_job"
	cancel_job_if_active "$cancel_job"
	for client_pid in "$success_client_pid" "$cancel_client_pid"; do
		[ -n "$client_pid" ] || continue
		/bin/kill "$client_pid" >/dev/null 2>&1 || true
	done
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf '%s\n' \
			"recovery: production was not changed; inspect run_dir=$run_dir" >&2
	fi
	exit "$rc"
}

accounting_success()
{
	file=$1
	"$sacct" -j "$success_job" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$success_job" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" {
			job_ok = 1
		}
		$1 == job ".0" && $3 == "COMPLETED" && $4 == "0:0" {
			step_ok = 1
		}
		END { exit !(job_ok && step_ok) }
	' "$file"
}

accounting_cancel()
{
	file=$1
	"$sacct" -j "$cancel_job" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$cancel_job" -v user="$test_user" '
		$1 == job && $2 == user && index($3, "CANCELLED") == 1 {
			job_ok = 1
		}
		$1 == job ".0" && (index($3, "CANCELLED") == 1 ||
		    $3 == "FAILED") { step_ok = 1 }
		END { exit !(job_ok && step_ok) }
	' "$file"
}

wait_accounting()
{
	mode=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if [ "$mode" = success ]; then
			accounting_success "$file" && return 0
		else
			accounting_cancel "$file" && return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for macOS'
for required in "$source_wrapper" "$source_driver" "$probe_source" \
	"$hold_source" \
	"$pmi2_archive" "$slurm_conf" "$scontrol" "$squeue" "$srun" \
	"$scancel" "$sacct" "$mpi_plugin" "$pid_file" "$slurmd_log"; do
	[ -e "$required" ] || fail "missing $required"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0700 "$record_dir" || fail 'cannot create record directory'
/usr/sbin/chown "$test_uid:$test_gid" "$record_dir" || \
	fail 'cannot set record ownership'
/bin/cp "$source_wrapper" "$wrapper" || fail 'cannot stage wrapper'
/bin/chmod 0555 "$wrapper" || fail 'cannot set wrapper mode'
/usr/sbin/chown 0:0 "$wrapper" || fail 'cannot set wrapper ownership'

/usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror \
	-Wno-unused-parameter -I"${source_root}/contribs/pmi2" \
	"$probe_source" "$pmi2_archive" -o "$probe" \
	>"${run_dir}/clang.out" 2>"${run_dir}/clang.err" || \
	fail 'cannot build bundled PMI2 probe'
/bin/chmod 0555 "$probe" || fail 'cannot set probe mode'
/usr/sbin/chown 0:0 "$probe" || fail 'cannot set probe ownership'
/usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror \
	-I"${source_root}/contribs/pmi2" "$hold_source" "$pmi2_archive" \
	-o "$hold_probe" >"${run_dir}/hold-clang.out" \
	2>"${run_dir}/hold-clang.err" || fail 'cannot build PMI2 hold probe'
/bin/chmod 0555 "$hold_probe" || fail 'cannot set hold probe mode'
/usr/sbin/chown 0:0 "$hold_probe" || fail 'cannot set hold probe ownership'
/usr/bin/file "$probe" >"${run_dir}/probe-file.txt"
/usr/bin/grep -Fq 'Mach-O 64-bit executable arm64' \
	"${run_dir}/probe-file.txt" || fail 'PMI2 probe is not arm64 Mach-O'
/usr/bin/otool -L "$probe" >"${run_dir}/probe-otool.txt"
[ "$(/usr/bin/wc -l <"${run_dir}/probe-otool.txt" | /usr/bin/tr -d ' ')" = 2 ] || \
	fail 'PMI2 probe has unexpected dynamic dependencies'
/usr/bin/file "$hold_probe" >"${run_dir}/hold-probe-file.txt"
/usr/bin/grep -Fq 'Mach-O 64-bit executable arm64' \
	"${run_dir}/hold-probe-file.txt" || fail 'PMI2 hold probe is not arm64 Mach-O'
/usr/bin/otool -L "$hold_probe" >"${run_dir}/hold-probe-otool.txt"
[ "$(/usr/bin/wc -l <"${run_dir}/hold-probe-otool.txt" | /usr/bin/tr -d ' ')" = 2 ] || \
	fail 'PMI2 hold probe has unexpected dynamic dependencies'
/usr/bin/printf 'run_dir=%s task_count=%s probe=Slurm_testpmi2_put\n' \
	"$run_dir" "$task_count"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || \
	fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || \
	fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || \
	fail 'cannot read node state'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || \
	fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || \
	fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || \
	fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'node has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/stepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail 'slurmd is not running'
slurmd_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")
log_start_line=$(( $(/usr/bin/wc -l <"$slurmd_log") + 1 ))

"$srun" --mpi=list >"${run_dir}/mpi-list.txt" 2>"${run_dir}/mpi-list.err" || \
	fail 'cannot list MPI plugins'
/usr/bin/grep -Eq '^[[:space:]]+pmi2$' "${run_dir}/mpi-list.txt" || \
	fail 'mpi/pmi2 is not available'
/usr/bin/file "$mpi_plugin" >"${run_dir}/plugin-file.txt"
/usr/bin/grep -Fq 'Mach-O 64-bit bundle arm64' "${run_dir}/plugin-file.txt" || \
	fail 'mpi/pmi2 plugin is not arm64 Mach-O'

node_ipv4=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || true)
case "$node_ipv4" in
''|*[!0-9.]*) fail "invalid en0 IPv4 address=$node_ipv4" ;;
esac
/usr/bin/awk -v node="$node_name" -v addr="$node_ipv4" '
	$1 == "NodeName=" node {
		found_addr = 0
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^NodeAddr=/) {
				$i = "NodeAddr=" addr
				found_addr = 1
			}
		}
		if (!found_addr) $0 = $0 " NodeAddr=" addr
		found_node = 1
	}
	{ print }
	END { if (!found_node) exit 1 }
' "$slurm_conf" >"$client_conf" || fail 'cannot create numeric client config'
/bin/chmod 0644 "$client_conf" || fail 'cannot set client config mode'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_wrapper" "$source_driver" \
	"$probe_source" "$hold_source" "$pmi2_archive" "$mpi_plugin" \
	>"${run_dir}/inputs-before.sha256"

/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
	SLURM_CONF="$client_conf" "$srun" --partition="$partition" \
	--nodes=1 --ntasks="$task_count" --cpus-per-task=1 --mem=256M \
	--time=00:01:00 --chdir=/tmp --mpi=pmi2 --kill-on-bad-exit=1 \
	--job-name="$success_name" "$wrapper" success "$probe" \
	>"${run_dir}/success.out" 2>"${run_dir}/success.err"
success_rc=$?
[ "$success_rc" -eq 0 ] || fail "PMI2 success run failed rc=$success_rc"
[ ! -s "${run_dir}/success.err" ] || fail 'PMI2 success stderr is not empty'
success_job=$(/usr/bin/awk -F '[ =]' '/^job_id=/ { print $2 }' \
	"${run_dir}/success.out" | /usr/bin/sort -u)
case "$success_job" in
''|*[!0-9]*) fail "invalid success job id=$success_job" ;;
esac
[ "$(/usr/bin/grep -Ec '^job_id=[0-9]+ rank=[0-3] task_count=4$' \
	"${run_dir}/success.out")" = "$task_count" ] || \
	fail 'success wrapper rank output mismatch'
[ "$(/usr/bin/grep -Ec '^spawned=0, size=4, rank=[0-3],' \
	"${run_dir}/success.out")" = "$task_count" ] || \
	fail 'PMI2 init rank/size output mismatch'
[ "$(/usr/bin/grep -Ec '^[0-3]> got 42$' "${run_dir}/success.out")" = \
	"$task_count" ] || fail 'PMI2 KVS broadcast output mismatch'
[ "$(/usr/bin/grep -Ec '^0> send 42$' "${run_dir}/success.out")" = 1 ] || \
	fail 'PMI2 rank-zero send output mismatch'
for rank in 0 1 2 3; do
	/usr/bin/grep -Eq "^job_id=${success_job} rank=${rank} task_count=4$" \
		"${run_dir}/success.out" || fail "missing wrapper rank=$rank"
	/usr/bin/grep -Eq "^spawned=0, size=4, rank=${rank}," \
		"${run_dir}/success.out" || fail "missing PMI2 rank=$rank"
	/usr/bin/grep -Eq "^${rank}> got 42$" "${run_dir}/success.out" || \
		fail "missing PMI2 KVS value rank=$rank"
done
wait_job_gone "$success_job" || fail 'success job remained in queue'
wait_accounting success "${run_dir}/success-sacct.txt" || \
	fail 'success accounting mismatch'
/usr/bin/printf 'pmi2_success=PASS job_id=%s ranks=0,1,2,3 kvs_value=42\n' \
	"$success_job"

/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
	SLURM_CONF="$client_conf" "$srun" --partition="$partition" \
	--nodes=1 --ntasks="$task_count" --cpus-per-task=1 --mem=256M \
	--time=00:02:00 --chdir=/tmp --mpi=pmi2 --kill-on-bad-exit=1 \
	--job-name="$cancel_name" "$hold_probe" "$record_dir" \
	>"${run_dir}/cancel.out" 2>"${run_dir}/cancel.err" &
cancel_client_pid=$!

attempt=0
while [ "$attempt" -lt 300 ]; do
	ready_count=$(/usr/bin/find "$record_dir" -type f -name 'ready.*' |
		/usr/bin/wc -l | /usr/bin/tr -d ' ')
	[ "$ready_count" = "$task_count" ] && break
	/bin/kill -0 "$cancel_client_pid" >/dev/null 2>&1 || \
		fail "cancel srun exited before ready count=$ready_count"
	/bin/sleep 0.1
	attempt=$((attempt + 1))
done
[ "$ready_count" = "$task_count" ] || fail 'cancel task readiness timeout'
cancel_job=$(/usr/bin/awk -F '=' '$1 == "job_id" { print $2 }' \
	"${record_dir}"/ready.* | /usr/bin/sort -u)
case "$cancel_job" in
''|*[!0-9]*) fail "invalid cancel job id=$cancel_job" ;;
esac
[ "$(queue_state "$cancel_job")" = RUNNING ] || fail 'cancel job is not RUNNING'
: >"${run_dir}/cancel-pids.txt"
for rank in 0 1 2 3; do
	record=${record_dir}/ready.${rank}
	/usr/bin/grep -Fqx "job_id=$cancel_job" "$record" || \
		fail "cancel job ID mismatch rank=$rank"
	/usr/bin/grep -Fqx "rank=$rank" "$record" || \
		fail "cancel rank mismatch rank=$rank"
	/usr/bin/grep -Fqx "size=$task_count" "$record" || \
		fail "cancel PMI2 size mismatch rank=$rank"
	/usr/bin/grep -Fqx 'spawned=0' "$record" || \
		fail "cancel PMI2 spawned mismatch rank=$rank"
	/usr/bin/grep -Fqx "uid=$test_uid" "$record" || \
		fail "cancel UID mismatch rank=$rank"
	/usr/bin/grep -Fqx "gid=$test_gid" "$record" || \
		fail "cancel GID mismatch rank=$rank"
	task_pid=$(/usr/bin/awk -F '=' '$1 == "pid" { print $2 }' "$record")
	case "$task_pid" in
	''|*[!0-9]*) fail "invalid cancel PID rank=$rank pid=$task_pid" ;;
	esac
	/bin/ps -p "$task_pid" -o pid= >/dev/null 2>&1 || \
		fail "cancel task missing rank=$rank pid=$task_pid"
	/usr/bin/printf '%s\n' "$task_pid" >>"${run_dir}/cancel-pids.txt"
done
/bin/ps -p "$(/usr/bin/paste -sd, "${run_dir}/cancel-pids.txt")" \
	-o pid=,uid=,ppid=,pgid=,state=,command= \
	>"${run_dir}/cancel-processes-before.txt" || \
	fail 'cannot capture cancel task processes'
"$scancel" "$cancel_job" || fail 'cannot cancel PMI2 allocation'
wait "$cancel_client_pid"
cancel_rc=$?
cancel_client_pid=
[ "$cancel_rc" -ne 0 ] || fail 'cancelled srun unexpectedly returned zero'
wait_job_gone "$cancel_job" || fail 'cancel job remained in queue'
while IFS= read -r task_pid; do
	wait_process_gone "$task_pid" || fail "cancel task remains pid=$task_pid"
done <"${run_dir}/cancel-pids.txt"
wait_accounting cancel "${run_dir}/cancel-sacct.txt" || \
	fail 'cancel accounting mismatch'
/usr/bin/printf 'pmi2_cancel=PASS job_id=%s tasks=%s client_rc=%s\n' \
	"$cancel_job" "$task_count" "$cancel_rc"

"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || \
	fail 'cannot read final node state'
[ "$(node_field State "${run_dir}/node-final.txt")" = IDLE ] || \
	fail 'final node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-final.txt")" = 0 ] || \
	fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-final.txt")" = 0 ] || \
	fail 'final AllocMem is not zero'
[ -z "$(node_field AllocTRES "${run_dir}/node-final.txt")" ] || \
	fail 'final AllocTRES is not empty'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed'
[ "$(node_field SlurmdStartTime "${run_dir}/node-final.txt")" = \
	"$slurmd_start" ] || fail 'SlurmdStartTime changed'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/stepd-final.txt" 2>/dev/null; then
	fail 'slurmstepd remains after test'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-final.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-final.txt" \
	>"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'test process remains'
/usr/bin/tail -n "+${log_start_line}" "$slurmd_log" \
	>"${run_dir}/slurmd-log-delta.txt"
/usr/bin/grep -Ei \
	'cannot create mpi context|plugin_load_from_file.*mpi|fatal|'\
'pthread_mutex.*Invalid argument|Protocol not available|symbol not found' \
	"${run_dir}/slurmd-log-delta.txt" >"${run_dir}/unexpected-errors.txt" || true
[ ! -s "${run_dir}/unexpected-errors.txt" ] || fail 'unexpected runtime error found'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_wrapper" "$source_driver" \
	"$probe_source" "$hold_source" "$pmi2_archive" "$mpi_plugin" \
	>"${run_dir}/inputs-after.sha256"
/usr/bin/cmp -s "${run_dir}/inputs-before.sha256" \
	"${run_dir}/inputs-after.sha256" || fail 'input changed during test'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s%s%s\n' \
	'SMD401_PMI2_PHASE_COMPLETE' \
	" success_job=$success_job cancel_job=$cancel_job tasks=$task_count" \
	' ranks=0,1,2,3 kvs=PASS cancel_cleanup=PASS' \
	" slurmd_pid=$slurmd_pid production_unchanged=PASS" \
	" run_dir=$run_dir"
