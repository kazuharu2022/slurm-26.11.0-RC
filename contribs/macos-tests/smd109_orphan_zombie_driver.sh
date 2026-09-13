#!/bin/sh

set -u

if [ "${SMD109_ORPHAN_TEST_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD109_ORPHAN_TEST_CONFIRMED=YES after confirming PC-210 is idle' >&2
	exit 64
fi

source_root=/Users/REDACTED_USER/dev/slurm.26-05
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
slurmd_log=/var/log/slurm/slurmd.log
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
fixture_timeout=180
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd109-${run_stamp}
record_dir=${run_dir}/records
output_dir=${run_dir}/output
client_conf=${run_dir}/slurm-client.conf
fixture=${run_dir}/smd109-process-fixture
job_script=${run_dir}/smd109-orphan-job.sh
source_fixture=${source_root}/contribs/macos-tests/smd109_process_fixture.c
source_job=${source_root}/contribs/macos-tests/smd109_orphan_job.sh
source_driver=${source_root}/contribs/macos-tests/smd109_orphan_zombie_driver.sh
job_id=
escaped_pid=
escaped_pgid=
slurmd_pid=
slurmd_start=
log_start_line=0
manual_cleanup=NOT_NEEDED
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

record_field()
{
	field=$1
	file=$2
	/usr/bin/awk -F '=' -v key="$field" '$1 == key { print $2; exit }' "$file"
}

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }'
}

wait_job_running()
{
	target=$1
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		state=$(queue_state "$target")
		[ "$state" = RUNNING ] && return 0
		[ -n "$state" ] || return 1
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_job_gone()
{
	target=$1
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		if [ -z "$(queue_state "$target")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' \
				"$target" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

process_exists()
{
	/bin/ps -p "$1" -o pid= >/dev/null 2>&1
}

wait_process_gone()
{
	pid=$1
	attempt=0
	while [ "$attempt" -lt 50 ]; do
		process_exists "$pid" || return 0
		/bin/sleep 0.1
		attempt=$((attempt + 1))
	done
	return 1
}

verify_escaped_identity()
{
	evidence_file=$1
	[ -n "$escaped_pid" ] || return 1
	[ -n "$escaped_pgid" ] || return 1
	/bin/ps -p "$escaped_pid" -o uid=,ppid=,pgid=,state=,command= \
		>"$evidence_file" 2>/dev/null || return 1
	/usr/bin/awk -v uid="$test_uid" -v pgid="$escaped_pgid" '
		NR == 1 && $1 == uid && $2 == 1 && $3 == pgid && $4 !~ /^Z/ { ok = 1 }
		END { exit !ok }
	' "$evidence_file" || return 1
	/usr/bin/grep -F "$fixture" "$evidence_file" >/dev/null 2>&1 || return 1
	/usr/bin/grep -F "$record_dir" "$evidence_file" >/dev/null 2>&1 || return 1
	return 0
}

cleanup_escaped()
{
	[ -n "$escaped_pid" ] || return 0
	process_exists "$escaped_pid" || return 0
	if ! verify_escaped_identity "${run_dir}/escaped-cleanup-identity.txt"; then
		/usr/bin/printf '%s\n' \
			"warning: refusing PID cleanup; identity mismatch pid=$escaped_pid" >&2
		return 1
	fi
	/bin/kill -KILL "$escaped_pid" >/dev/null 2>&1 || return 1
	attempt=0
	while [ "$attempt" -lt 50 ]; do
		process_exists "$escaped_pid" || return 0
		/bin/sleep 0.1
		attempt=$((attempt + 1))
	done
	return 1
}

cancel_if_active()
{
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state" >&2
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
}

accounting_cancelled()
{
	file=$1
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
	$1 == job && $2 == user && $3 ~ /^CANCELLED/ { job_ok = 1 }
	$1 == job ".batch" && ($3 ~ /^CANCELLED/ || $3 == "FAILED") &&
		$4 ~ /^[0-9]+:(9|15)$/ { batch_ok = 1 }
	END { exit !(job_ok && batch_ok) }
	' "$file"
}

wait_accounting()
{
	file=$1
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		accounting_cancelled "$file" && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active
	cleanup_escaped || true
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf '%s\n' \
			"recovery: test orphan self-expires after ${fixture_timeout}s; inspect run_dir=$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" \
	"$scancel" "$sacct" "$pid_file" "$slurmd_log" "$source_fixture" \
	"$source_job" "$source_driver"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for command in /usr/bin/awk /usr/bin/clang /usr/bin/cmp /usr/bin/dscacheutil \
	/usr/bin/grep /usr/bin/id /usr/bin/pgrep /usr/bin/sed /usr/bin/shasum \
	/usr/bin/stat /usr/bin/sudo /usr/bin/tail /usr/bin/tr /usr/bin/wc \
	/usr/sbin/chown /usr/sbin/ipconfig /bin/cat /bin/chmod /bin/cp /bin/date \
	/bin/hostname /bin/kill /bin/mkdir /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0700 "$record_dir" || fail 'cannot create record directory'
/usr/sbin/chown "$test_uid:$test_gid" "$record_dir" || fail 'cannot chown record directory'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
/bin/cp "$source_job" "$job_script" || fail 'cannot stage job script'
/bin/chmod 0555 "$job_script" || fail 'cannot set job script mode'
/usr/sbin/chown 0:0 "$job_script" || fail 'cannot set job script owner'
/usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror "$source_fixture" \
	-o "$fixture" >"${run_dir}/clang.out" 2>"${run_dir}/clang.err" || \
	fail 'cannot compile process fixture'
/bin/chmod 0555 "$fixture" || fail 'cannot set fixture mode'
/usr/sbin/chown 0:0 "$fixture" || fail 'cannot set fixture owner'
/usr/bin/printf 'run_dir=%s fixture_timeout=%s\n' "$run_dir" "$fixture_timeout"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show config >"${run_dir}/config-before.txt" || fail 'config readback failed'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || \
	fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || \
	fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || \
	fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail "slurmd pid=$slurmd_pid is not running"
slurmd_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")
log_start_line=$(/usr/bin/wc -l <"$slurmd_log" | /usr/bin/tr -d ' ')

node_ipv4=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || true)
case "$node_ipv4" in
''|*[!0-9.]*) fail "invalid en0 IPv4 address=$node_ipv4" ;;
esac
/usr/bin/dscacheutil -q host -a name "${node_name}.local" \
	>"${run_dir}/node-address-readback.txt" 2>"${run_dir}/node-address-readback.err" || \
	fail "cannot resolve ${node_name}.local"
/usr/bin/grep -Fqx "ip_address: ${node_ipv4}" "${run_dir}/node-address-readback.txt" || \
	fail "${node_name}.local does not resolve to en0 address $node_ipv4"
/usr/bin/awk -v node="$node_name" -v addr="$node_ipv4" '
	$1 == "NodeName=" node {
		found_addr = 0
		for (i = 1; i <= NF; i++) if ($i ~ /^NodeAddr=/) found_addr = 1
		if (!found_addr) $0 = $0 " NodeAddr=" addr
		found_node = 1
	}
	{ print }
	END { if (!found_node) exit 1 }
' "$slurm_conf" >"$client_conf" || fail 'cannot create numeric NodeAddr client config'
/bin/chmod 0644 "$client_conf" || fail 'cannot set client config mode'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_fixture" "$source_job" \
	"$source_driver" >"${run_dir}/inputs-before.sha256"
/usr/bin/shasum -a 256 "$fixture" >"${run_dir}/fixture-binary.sha256"

submit_result=$(/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
	SLURM_CONF="$client_conf" \
	"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
	--cpus-per-task=1 --mem=128M --time=00:03:00 --chdir=/tmp \
	--job-name=smd109-orphan-${run_stamp} \
	--output="${output_dir}/job-%j.out" --error="${output_dir}/job-%j.err" \
	"$job_script" "$fixture" "$record_dir" "$fixture_timeout") || \
	fail 'cannot submit orphan/zombie job'
job_id=${submit_result%%;*}
case "$job_id" in
''|*[!0-9]*) fail "invalid job id=$job_id" ;;
esac
/usr/bin/printf 'submitted test_job=%s\n' "$job_id"
wait_job_running "$job_id" || fail 'test job did not reach RUNNING'

attempt=0
while [ "$attempt" -lt 100 ]; do
	[ -s "${record_dir}/ready" ] && [ -s "${record_dir}/coordinator.txt" ] && \
		[ -s "${record_dir}/ignorer.txt" ] && [ -s "${record_dir}/zombie.txt" ] && \
		[ -s "${record_dir}/escaped.txt" ] && break
	[ "$(queue_state "$job_id")" = RUNNING ] || fail 'job ended before fixture ready'
	/bin/sleep 0.1
	attempt=$((attempt + 1))
done
[ -s "${record_dir}/ready" ] || fail 'fixture ready marker not observed'

coordinator_pid=$(record_field pid "${record_dir}/coordinator.txt")
coordinator_pgid=$(record_field pgid "${record_dir}/coordinator.txt")
ignorer_pid=$(record_field pid "${record_dir}/ignorer.txt")
ignorer_pgid=$(record_field pgid "${record_dir}/ignorer.txt")
zombie_pid=$(record_field pid "${record_dir}/zombie.txt")
zombie_pgid=$(record_field pgid "${record_dir}/zombie.txt")
escaped_pid=$(record_field pid "${record_dir}/escaped.txt")
escaped_ppid=$(record_field ppid "${record_dir}/escaped.txt")
escaped_pgid=$(record_field pgid "${record_dir}/escaped.txt")
escaped_sid=$(record_field sid "${record_dir}/escaped.txt")
for value in "$coordinator_pid" "$coordinator_pgid" "$ignorer_pid" \
	"$ignorer_pgid" "$zombie_pid" "$zombie_pgid" "$escaped_pid" \
	"$escaped_ppid" "$escaped_pgid" "$escaped_sid"; do
	case "$value" in
	''|*[!0-9]*) fail "invalid process identity value=$value" ;;
	esac
done
[ "$ignorer_pgid" = "$coordinator_pgid" ] || fail 'ignorer left job process group'
[ "$zombie_pgid" = "$coordinator_pgid" ] || fail 'zombie left job process group'
[ "$escaped_pgid" != "$coordinator_pgid" ] || fail 'double-fork process did not leave PGID'
[ "$escaped_ppid" = 1 ] || fail "escaped process was not reparented ppid=$escaped_ppid"
[ "$escaped_sid" = "$escaped_pgid" ] || fail 'escaped process session and PGID mismatch'

attempt=0
while [ "$attempt" -lt 50 ]; do
	zombie_state=$(/bin/ps -p "$zombie_pid" -o state= 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }')
	case "$zombie_state" in
	Z*) break ;;
	esac
	/bin/sleep 0.1
	attempt=$((attempt + 1))
done
case "$zombie_state" in
Z*) ;;
*) fail "short-lived child did not become zombie state=$zombie_state" ;;
esac

/bin/ps -p "$coordinator_pid,$ignorer_pid,$zombie_pid,$escaped_pid" \
	-o pid=,uid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-before-cancel.txt" || \
	fail 'cannot capture all fixture processes before cancel'
[ "$(/usr/bin/wc -l <"${run_dir}/processes-before-cancel.txt" | /usr/bin/tr -d ' ')" = 4 ] || \
	fail 'not all fixture processes exist before cancel'
/usr/bin/awk -v uid="$test_uid" -v coordinator="$coordinator_pid" \
	-v ignorer="$ignorer_pid" -v zombie="$zombie_pid" \
	-v escaped="$escaped_pid" -v job_pgid="$coordinator_pgid" \
	-v escaped_pgid="$escaped_pgid" '
$1 == coordinator && $2 == uid && $4 == job_pgid && $5 !~ /^Z/ { coordinator_ok = 1 }
$1 == ignorer && $2 == uid && $4 == job_pgid && $5 !~ /^Z/ { ignorer_ok = 1 }
$1 == zombie && $2 == uid && $4 == job_pgid && $5 ~ /^Z/ { zombie_ok = 1 }
$1 == escaped && $2 == uid && $3 == 1 && $4 == escaped_pgid && $5 !~ /^Z/ {
	escaped_ok = 1
}
END { exit !(coordinator_ok && ignorer_ok && zombie_ok && escaped_ok) }
' "${run_dir}/processes-before-cancel.txt" || fail 'fixture process identity mismatch'
verify_escaped_identity "${run_dir}/escaped-before-cancel.txt" || \
	fail 'escaped process identity mismatch before cancel'
/usr/bin/printf '%s%s%s\n' \
	"fixture_ready job_id=$job_id coordinator=$coordinator_pid pgid=$coordinator_pgid" \
	" ignorer=$ignorer_pid zombie=$zombie_pid zombie_state=$zombie_state" \
	" escaped=$escaped_pid escaped_ppid=$escaped_ppid escaped_pgid=$escaped_pgid"

/usr/bin/printf 'cancel test_job=%s\n' "$job_id"
"$scancel" "$job_id" || fail 'cannot cancel test job'
wait_job_gone "$job_id" || fail 'test job remained in queue'

for role_pid in "coordinator:$coordinator_pid" "ignorer:$ignorer_pid" \
	"zombie:$zombie_pid"; do
	role=${role_pid%%:*}
	pid=${role_pid#*:}
	if ! wait_process_gone "$pid"; then
		/bin/ps -p "$pid" -o pid=,uid=,ppid=,pgid=,state=,command= \
			>>"${run_dir}/unexpected-in-group-residuals.txt" 2>/dev/null || true
		fail "in-group process remains role=$role pid=$pid"
	fi
	/usr/bin/printf 'post_cancel role=%s pid=%s residual=NO\n' "$role" "$pid"
done
verify_escaped_identity "${run_dir}/escaped-after-cancel.txt" || \
	fail 'expected out-of-PGID process did not survive with exact identity'
manual_cleanup=REQUIRED
/usr/bin/printf '%s\n' \
	"pgid_limit_observed escaped_pid=$escaped_pid residual=YES exact_identity=PASS"

cleanup_escaped || fail 'exact escaped-process cleanup failed'
manual_cleanup=PASS
/usr/bin/printf 'escaped_cleanup pid=%s signal=KILL residual=NO\n' "$escaped_pid"
wait_accounting "${run_dir}/sacct.txt" || fail 'cancel accounting mismatch'
job_out=${output_dir}/job-${job_id}.out
job_err=${output_dir}/job-${job_id}.err
[ -f "$job_out" ] || fail 'job stdout is missing'
[ -f "$job_err" ] || fail 'job stderr is missing'
[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$job_out")" = "${test_uid}:${test_gid}:644" ] || \
	fail 'job stdout owner or mode mismatch'
[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$job_err")" = "${test_uid}:${test_gid}:644" ] || \
	fail 'job stderr owner or mode mismatch'

"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || \
	fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-final.txt")" = IDLE ] || fail 'final node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-final.txt")" = 0 ] || \
	fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-final.txt")" = 0 ] || \
	fail 'final AllocMem is not zero'
[ -z "$(node_field AllocTRES "${run_dir}/node-final.txt")" ] || \
	fail 'final AllocTRES is not empty'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed during test'
[ "$(node_field SlurmdStartTime "${run_dir}/node-final.txt")" = "$slurmd_start" ] || \
	fail 'SlurmdStartTime changed during test'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-final.txt" 2>/dev/null; then
	fail 'slurmstepd remains after test'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-final.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-final.txt" \
	>"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'test fixture process remains'

next_log_line=$((log_start_line + 1))
/usr/bin/tail -n "+${next_log_line}" "$slurmd_log" >"${run_dir}/slurmd-log-delta.txt"
/usr/bin/grep -Ei \
	'fatal|pthread_mutex|Protocol not available|symbol not found|opendir\(/proc\)' \
	"${run_dir}/slurmd-log-delta.txt" >"${run_dir}/unexpected-errors.txt" || true
[ ! -s "${run_dir}/unexpected-errors.txt" ] || fail 'unexpected slurmd runtime error found'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_fixture" "$source_job" \
	"$source_driver" >"${run_dir}/inputs-after.sha256"
/usr/bin/cmp -s "${run_dir}/inputs-before.sha256" "${run_dir}/inputs-after.sha256" || \
	fail 'production config or test source changed during test'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s%s%s\n' \
	"SMD109_ORPHAN_ZOMBIE_COMPLETE job_id=$job_id" \
	" in_group_cleanup=PASS zombie_cleanup=PASS" \
	" escaped_pgid_limit=OBSERVED escaped_pid_cleanup=$manual_cleanup" \
	" slurmd_pid=$slurmd_pid production_unchanged=PASS" \
	" run_dir=$run_dir"
