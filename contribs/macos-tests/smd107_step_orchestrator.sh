#!/bin/sh

set -u

prefix=${1:-}
client_conf=${2:-}
record_dir=${3:-}
payload=${4:-}

srun=${prefix}/bin/srun
scancel=${prefix}/bin/scancel
job_id=${SLURM_JOB_ID:-}
cancel_srun_pid=
survivor_srun_pid=
cancel_step=
survivor_step=
finished=0

fail()
{
	/usr/bin/printf 'orchestrator_error=%s\n' "$*" >&2
	exit 1
}

record_value()
{
	key=$1
	file=$2
	/usr/bin/awk -F '=' -v wanted="$key" '$1 == wanted { print $2; exit }' "$file"
}

cancel_step_if_active()
{
	step_id=$1
	case "$step_id" in
	''|*[!0-9]*) return 0 ;;
	esac
	"$scancel" "${job_id}.${step_id}" >/dev/null 2>&1 || true
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$finished" -ne 1 ]; then
		cancel_step_if_active "$cancel_step"
		cancel_step_if_active "$survivor_step"
		for pid in "$cancel_srun_pid" "$survivor_srun_pid"; do
			case "$pid" in
			''|*[!0-9]*) continue ;;
			esac
			/bin/kill "$pid" >/dev/null 2>&1 || true
		done
	fi
	exit "$rc"
}

run_step()
{
	label=$1
	mode=$2
	release_file=${record_dir}/${label}.release
	"$srun" --nodes=1 --ntasks=1 --cpus-per-task=1 --mem=64M \
		--exact --mpi=none --job-name="smd107-${label}" \
		--output="${record_dir}/${label}.out" \
		--error="${record_dir}/${label}.err" \
		"$payload" "$label" "$mode" "$record_dir" "$release_file"
	rc=$?
	/usr/bin/printf '%s\n' "$rc" >"${record_dir}/${label}.srun-rc"
	return 0
}

[ -n "$prefix" ] || fail 'missing prefix'
[ -f "$client_conf" ] || fail 'missing client config'
[ -d "$record_dir" ] || fail 'missing record directory'
[ -x "$payload" ] || fail 'payload is not executable'
[ -x "$srun" ] || fail 'srun is not executable'
[ -x "$scancel" ] || fail 'scancel is not executable'
case "$job_id" in
''|*[!0-9]*) fail "invalid job ID=$job_id" ;;
esac

export SLURM_CONF="$client_conf"
trap cleanup EXIT HUP INT TERM

run_step seq_a success
run_step seq_fail fail7
run_step seq_c success

"$srun" --nodes=1 --ntasks=1 --cpus-per-task=1 --mem=64M \
	--exact --mpi=none --job-name=smd107-hold-cancel \
	--output="${record_dir}/hold_cancel.out" \
	--error="${record_dir}/hold_cancel.err" \
	"$payload" hold_cancel hold "$record_dir" \
	"${record_dir}/hold_cancel.release" &
cancel_srun_pid=$!

"$srun" --nodes=1 --ntasks=1 --cpus-per-task=1 --mem=64M \
	--exact --mpi=none --job-name=smd107-hold-survivor \
	--output="${record_dir}/hold_survivor.out" \
	--error="${record_dir}/hold_survivor.err" \
	"$payload" hold_survivor hold "$record_dir" \
	"${record_dir}/hold_survivor.release" &
survivor_srun_pid=$!

attempt=0
while [ "$attempt" -lt 300 ]; do
	if [ -f "${record_dir}/hold_cancel.ready" ] && \
		[ -f "${record_dir}/hold_survivor.ready" ]; then
		break
	fi
	/bin/kill -0 "$cancel_srun_pid" >/dev/null 2>&1 || \
		fail 'cancel target srun exited before ready'
	/bin/kill -0 "$survivor_srun_pid" >/dev/null 2>&1 || \
		fail 'survivor srun exited before ready'
	/bin/sleep 0.1
	attempt=$((attempt + 1))
done
[ -f "${record_dir}/hold_cancel.ready" ] || fail 'cancel target barrier timeout'
[ -f "${record_dir}/hold_survivor.ready" ] || fail 'survivor barrier timeout'

cancel_step=$(record_value step_id "${record_dir}/hold_cancel.ready")
survivor_step=$(record_value step_id "${record_dir}/hold_survivor.ready")
cancel_task_pid=$(record_value pid "${record_dir}/hold_cancel.ready")
survivor_task_pid=$(record_value pid "${record_dir}/hold_survivor.ready")
for value in "$cancel_step" "$survivor_step" "$cancel_task_pid" "$survivor_task_pid"; do
	case "$value" in
	''|*[!0-9]*) fail "invalid concurrent value=$value" ;;
	esac
done
[ "$cancel_step" != "$survivor_step" ] || fail 'concurrent step IDs are not unique'
/bin/kill -0 "$cancel_task_pid" >/dev/null 2>&1 || fail 'cancel target task is not alive'
/bin/kill -0 "$survivor_task_pid" >/dev/null 2>&1 || fail 'survivor task is not alive'
{
	/usr/bin/printf 'cancel_step=%s\n' "$cancel_step"
	/usr/bin/printf 'survivor_step=%s\n' "$survivor_step"
	/usr/bin/printf 'cancel_task_pid=%s\n' "$cancel_task_pid"
	/usr/bin/printf 'survivor_task_pid=%s\n' "$survivor_task_pid"
	/usr/bin/printf 'concurrent_alive=YES\n'
} >"${record_dir}/concurrent.txt"

"$scancel" "${job_id}.${cancel_step}"
scancel_rc=$?
/usr/bin/printf '%s\n' "$scancel_rc" >"${record_dir}/hold_cancel.scancel-rc"
[ "$scancel_rc" -eq 0 ] || fail "step cancellation failed rc=$scancel_rc"

wait "$cancel_srun_pid"
cancel_srun_rc=$?
cancel_srun_pid=
/usr/bin/printf '%s\n' "$cancel_srun_rc" >"${record_dir}/hold_cancel.srun-rc"
[ "$cancel_srun_rc" -ne 0 ] || fail 'cancelled srun unexpectedly returned zero'

/bin/kill -0 "$survivor_task_pid" >/dev/null 2>&1 || \
	fail 'survivor task ended when peer step was cancelled'
/usr/bin/printf 'release=YES\n' >"${record_dir}/hold_survivor.release"
wait "$survivor_srun_pid"
survivor_srun_rc=$?
survivor_srun_pid=
/usr/bin/printf '%s\n' "$survivor_srun_rc" >"${record_dir}/hold_survivor.srun-rc"
[ "$survivor_srun_rc" -eq 0 ] || fail "survivor srun failed rc=$survivor_srun_rc"

run_step post_cancel success

finished=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s\n' \
	"SMD107_ORCHESTRATOR_COMPLETE job_id=$job_id" \
	" cancel_step=$cancel_step survivor_step=$survivor_step" \
	' sequential=PASS concurrent=PASS cancel_isolation=PASS post_cancel=PASS'
exit 0
