#!/bin/sh

set -u

if [ "${SMD107_MULTI_STEP_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD107_MULTI_STEP_CONFIRMED=YES after confirming PC-210 is idle' >&2
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
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd107-${run_stamp}
record_dir=${run_dir}/records
evidence_dir=${run_dir}/evidence
client_conf=${run_dir}/slurm-client.conf
payload=${run_dir}/step-payload.sh
orchestrator=${run_dir}/step-orchestrator.sh
test_job=
slurmd_pid=
slurmd_start=
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

record_value()
{
	key=$1
	file=$2
	/usr/bin/awk -F '=' -v wanted="$key" '$1 == wanted { print $2; exit }' "$file"
}

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }'
}

cancel_if_active()
{
	job_id=$1
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state" >&2
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 240 ]; do
		if [ -z "$(queue_state "$job_id")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' \
				"$job_id" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

accounting_complete()
{
	file=$1
	job=$2
	seq_a=$3
	seq_fail=$4
	seq_c=$5
	cancel_step=$6
	survivor_step=$7
	post_step=$8
	"$sacct" -j "$job" -n -P \
		--format=JobIDRaw,JobName,User,State,ExitCode,NodeList,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job" -v user="$test_user" \
		-v a="$seq_a" -v bad="$seq_fail" -v c="$seq_c" \
		-v cancel="$cancel_step" -v survivor="$survivor_step" -v post="$post_step" '
		$1 == job && $3 == user && $4 == "COMPLETED" && $5 == "0:0" { job_ok = 1 }
		$1 == job ".batch" && $4 == "COMPLETED" && $5 == "0:0" { batch_ok = 1 }
		$1 == job "." a && $4 == "COMPLETED" && $5 == "0:0" { a_ok = 1 }
		$1 == job "." bad && $4 == "FAILED" && $5 == "7:0" { bad_ok = 1 }
		$1 == job "." c && $4 == "COMPLETED" && $5 == "0:0" { c_ok = 1 }
		$1 == job "." cancel && index($4, "CANCELLED") == 1 { cancel_ok = 1 }
		$1 == job "." survivor && $4 == "COMPLETED" && $5 == "0:0" { survivor_ok = 1 }
		$1 == job "." post && $4 == "COMPLETED" && $5 == "0:0" { post_ok = 1 }
		END {
			exit !(job_ok && batch_ok && a_ok && bad_ok && c_ok &&
				cancel_ok && survivor_ok && post_ok)
		}
	' "$file"
}

wait_accounting()
{
	file=$1
	shift
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		accounting_complete "$file" "$@" && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$test_job"
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf '%s\n' \
			"recovery: no production configuration was changed; inspect run_dir=$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" \
	"$scancel" "$sacct" "$pid_file" \
	"${source_root}/contribs/macos-tests/smd107_step_payload.sh" \
	"${source_root}/contribs/macos-tests/smd107_step_orchestrator.sh"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for command in /usr/bin/awk /usr/bin/cmp /usr/bin/dscacheutil /usr/bin/find \
	/usr/bin/grep /usr/bin/id /usr/bin/pgrep /usr/bin/shasum /usr/bin/sort \
	/usr/bin/stat /usr/bin/sudo /usr/bin/tr /usr/bin/uniq /usr/bin/wc \
	/usr/sbin/chown /usr/sbin/ipconfig /bin/cat /bin/chmod /bin/cp \
	/bin/date /bin/kill /bin/mkdir /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0755 "$evidence_dir" || fail 'cannot create evidence directory'
/bin/mkdir -m 0700 "$record_dir" || fail 'cannot create record directory'
/usr/sbin/chown "$test_uid:$test_gid" "$record_dir" || fail 'cannot chown record directory'
/bin/cp "${source_root}/contribs/macos-tests/smd107_step_payload.sh" "$payload" || \
	fail 'cannot stage payload'
/bin/cp "${source_root}/contribs/macos-tests/smd107_step_orchestrator.sh" \
	"$orchestrator" || fail 'cannot stage orchestrator'
/bin/chmod 0555 "$payload" "$orchestrator" || fail 'cannot set script modes'
/usr/sbin/chown 0:0 "$payload" "$orchestrator" || fail 'cannot set script owners'
/usr/bin/printf 'run_dir=%s\n' "$run_dir"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
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
/usr/bin/shasum -a 256 "$slurm_conf" "$payload" "$orchestrator" \
	>"${run_dir}/inputs-before.sha256"

test_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=4 \
		--cpus-per-task=1 --mem=512M --time=00:02:00 --chdir=/tmp \
		--job-name=smd107-multi-step \
		--output="${record_dir}/batch-%j.out" \
		--error="${record_dir}/batch-%j.err" \
		"$orchestrator" "$prefix" "$client_conf" "$record_dir" "$payload"
) || fail 'multi-step batch submission failed'
test_job=${test_job%%;*}
case "$test_job" in
''|*[!0-9]*) fail "invalid test job id=$test_job" ;;
esac
/usr/bin/printf 'submitted test_job=%s\n' "$test_job"

wait_job_gone "$test_job" || fail 'multi-step batch job remained in queue'
batch_out=${record_dir}/batch-${test_job}.out
batch_err=${record_dir}/batch-${test_job}.err
[ -f "$batch_out" ] || fail 'missing batch stdout'
[ -f "$batch_err" ] || fail 'missing batch stderr'
/usr/bin/grep -Fq "SMD107_ORCHESTRATOR_COMPLETE job_id=$test_job" "$batch_out" || \
	fail 'orchestrator completion marker missing'
bad_pattern='fatal:|pthread_mutex|symbol not found|Protocol not available|Socket no longer there'
if /usr/bin/grep -Ein "$bad_pattern" "$batch_err" >"${run_dir}/unexpected-errors.txt"; then
	fail 'unexpected fatal/runtime error in batch stderr'
fi

for label in seq_a seq_fail seq_c hold_cancel hold_survivor post_cancel; do
	ready=${record_dir}/${label}.ready
	[ -f "$ready" ] || fail "missing ready record label=$label"
	[ "$(record_value job_id "$ready")" = "$test_job" ] || \
		fail "job ID mismatch label=$label"
	[ "$(record_value proc_id "$ready")" = 0 ] || fail "proc ID mismatch label=$label"
	[ "$(record_value local_id "$ready")" = 0 ] || fail "local ID mismatch label=$label"
	[ "$(record_value uid "$ready")" = "$test_uid" ] || fail "UID mismatch label=$label"
	[ "$(record_value gid "$ready")" = "$test_gid" ] || fail "GID mismatch label=$label"
	step_id=$(record_value step_id "$ready")
	case "$step_id" in
	''|*[!0-9]*) fail "invalid step ID label=$label id=$step_id" ;;
	esac
	/usr/bin/printf '%s %s\n' "$label" "$step_id" >>"${run_dir}/step-ids.txt"
done

unique_steps=$(/usr/bin/awk '{ print $2 }' "${run_dir}/step-ids.txt" |
	/usr/bin/sort -n | /usr/bin/uniq | /usr/bin/wc -l | /usr/bin/tr -d ' ')
[ "$unique_steps" = 6 ] || fail "step IDs are not unique count=$unique_steps"
seq_a_step=$(record_value step_id "${record_dir}/seq_a.ready")
seq_fail_step=$(record_value step_id "${record_dir}/seq_fail.ready")
seq_c_step=$(record_value step_id "${record_dir}/seq_c.ready")
cancel_step=$(record_value step_id "${record_dir}/hold_cancel.ready")
survivor_step=$(record_value step_id "${record_dir}/hold_survivor.ready")
post_step=$(record_value step_id "${record_dir}/post_cancel.ready")
[ "$seq_a_step" -lt "$seq_fail_step" ] || fail 'sequential step order A/fail mismatch'
[ "$seq_fail_step" -lt "$seq_c_step" ] || fail 'sequential step order fail/C mismatch'
[ "$post_step" -gt "$cancel_step" ] || fail 'post step did not follow cancelled step'
[ "$post_step" -gt "$survivor_step" ] || fail 'post step did not follow survivor step'

[ "$(/bin/cat "${record_dir}/seq_a.srun-rc")" = 0 ] || fail 'seq_a rc mismatch'
[ "$(/bin/cat "${record_dir}/seq_fail.srun-rc")" = 7 ] || fail 'seq_fail rc mismatch'
[ "$(/bin/cat "${record_dir}/seq_c.srun-rc")" = 0 ] || fail 'seq_c rc mismatch'
[ "$(/bin/cat "${record_dir}/hold_cancel.scancel-rc")" = 0 ] || \
	fail 'step scancel rc mismatch'
cancel_rc=$(/bin/cat "${record_dir}/hold_cancel.srun-rc")
case "$cancel_rc" in
''|*[!0-9]*) fail "invalid cancelled srun rc=$cancel_rc" ;;
0) fail 'cancelled srun rc unexpectedly zero' ;;
esac
[ "$(/bin/cat "${record_dir}/hold_survivor.srun-rc")" = 0 ] || \
	fail 'survivor srun rc mismatch'
[ "$(/bin/cat "${record_dir}/post_cancel.srun-rc")" = 0 ] || \
	fail 'post-cancel srun rc mismatch'
/usr/bin/grep -Fqx 'concurrent_alive=YES' "${record_dir}/concurrent.txt" || \
	fail 'concurrent liveness evidence missing'
[ ! -e "${record_dir}/hold_cancel.done" ] || fail 'cancelled step unexpectedly completed'
[ -f "${record_dir}/hold_survivor.done" ] || fail 'survivor step did not complete'
[ -f "${record_dir}/post_cancel.done" ] || fail 'post-cancel step did not complete'

wait_accounting "${run_dir}/sacct.txt" "$test_job" "$seq_a_step" \
	"$seq_fail_step" "$seq_c_step" "$cancel_step" "$survivor_step" "$post_step" || \
	fail 'multi-step accounting did not reach expected states'

for name in batch-${test_job}.out batch-${test_job}.err \
	seq_a.out seq_a.err seq_a.ready seq_a.done seq_a.srun-rc \
	seq_fail.out seq_fail.err seq_fail.ready seq_fail.srun-rc \
	seq_c.out seq_c.err seq_c.ready seq_c.done seq_c.srun-rc \
	hold_cancel.out hold_cancel.err hold_cancel.ready hold_cancel.srun-rc \
	hold_cancel.scancel-rc hold_survivor.out hold_survivor.err \
	hold_survivor.ready hold_survivor.done hold_survivor.srun-rc \
	post_cancel.out post_cancel.err post_cancel.ready post_cancel.done \
	post_cancel.srun-rc concurrent.txt; do
	[ -f "${record_dir}/${name}" ] || fail "missing evidence file=$name"
	/bin/cp "${record_dir}/${name}" "${evidence_dir}/${name}" || \
		fail "cannot stage evidence file=$name"
done
/bin/cp "${run_dir}/sacct.txt" "${evidence_dir}/sacct.txt" || \
	fail 'cannot stage accounting evidence'
/bin/cp "${run_dir}/sacct.err" "${evidence_dir}/sacct.err" || \
	fail 'cannot stage accounting stderr'
/bin/chmod 0644 "${evidence_dir}"/* || fail 'cannot set evidence modes'

/usr/bin/printf '[step-ids]\n'
/bin/cat "${run_dir}/step-ids.txt"
/usr/bin/printf '[return-codes]\n'
for label in seq_a seq_fail seq_c hold_cancel hold_survivor post_cancel; do
	/usr/bin/printf '%s=%s\n' "$label" \
		"$(/bin/cat "${record_dir}/${label}.srun-rc")"
done
/usr/bin/printf 'hold_cancel_scancel=%s\n' \
	"$(/bin/cat "${record_dir}/hold_cancel.scancel-rc")"
/usr/bin/printf '[concurrent]\n'
/bin/cat "${record_dir}/concurrent.txt"
/usr/bin/printf '[accounting]\n'
/bin/cat "${run_dir}/sacct.txt"

/usr/bin/stat -f '%u:%g:%Lp %N' "$batch_out" "$batch_err" \
	>"${run_dir}/batch-output-metadata.txt"
expected_metadata=${test_uid}:${test_gid}:644
/usr/bin/awk -v expected="$expected_metadata" '
	$1 != expected { exit 1 }
' "${run_dir}/batch-output-metadata.txt" || fail 'batch output owner/mode mismatch'

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
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'test process remains'
/usr/bin/shasum -a 256 "$slurm_conf" "$payload" "$orchestrator" \
	>"${run_dir}/inputs-after.sha256"
/usr/bin/cmp -s "${run_dir}/inputs-before.sha256" "${run_dir}/inputs-after.sha256" || \
	fail 'production config or staged scripts changed during test'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s%s\n' \
	"SMD107_MULTI_STEP_COMPLETE job_id=$test_job steps=6" \
	" sequential=${seq_a_step},${seq_fail_step},${seq_c_step}" \
	" concurrent=${cancel_step},${survivor_step} post=${post_step}" \
	" cancel_isolation=PASS accounting=PASS slurmd_pid=$slurmd_pid run_dir=$run_dir"
