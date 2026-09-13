#!/bin/sh

set -u

source_root=/Users/REDACTED_USER/dev/slurm.26-05
candidate_slurmd_src=${source_root}/src/slurmd/slurmd/.libs/slurmd
candidate_lib_src=${source_root}/src/api/.libs/libslurmfull.dylib
slurm_prefix=/opt/slurm/26.11.0
production_conf=${slurm_prefix}/etc/slurm.conf
production_key=${slurm_prefix}/etc/slurm.key
production_gres_conf=${slurm_prefix}/etc/gres.conf
scontrol=${slurm_prefix}/bin/scontrol
squeue=${slurm_prefix}/bin/squeue
sbatch=${slurm_prefix}/bin/sbatch
scancel=${slurm_prefix}/bin/scancel
sacct=${slurm_prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
sack_socket=/var/run/slurm/sack.socket
node_name=PC-210
test_user=testuser
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd013-${run_stamp}
candidate_dir=${run_dir}/candidate
isolated_spool=${run_dir}/spool
isolated_conf=${run_dir}/slurm.conf.isolated-spool
smoke_dir=${run_dir}/smoke
old_pid=
current_pid=
phase_a_pid=
phase_b_pid=
restored_pid=
smoke_a=
smoke_b=
smoke_final=
active_smoke=
daemon_was_stopped=0
success=0

export SLURM_CONF="$production_conf"

is_running()
{
	check_pid=$1
	[ -n "$check_pid" ] && /bin/kill -0 "$check_pid" >/dev/null 2>&1
}

queue_state()
{
	"$squeue" -h -j "$1" -o '%T'
}

cancel_if_active()
{
	job_id=$1
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id" 2>/dev/null || true)
	if [ -n "$state" ]; then
		printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state" >&2
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
}

wait_for_stop()
{
	stopping_pid=$1
	attempt=0
	while is_running "$stopping_pid" && [ "$attempt" -lt 30 ]; do
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	! is_running "$stopping_pid"
}

stop_daemon()
{
	stopping_pid=$1
	label=$2
	printf 'stop phase=%s pid=%s signal=TERM\n' "$label" "$stopping_pid"
	/bin/kill -TERM "$stopping_pid" || return 1
	if ! wait_for_stop "$stopping_pid"; then
		printf 'error: phase=%s pid=%s did not stop\n' \
			"$label" "$stopping_pid" >&2
		return 1
	fi
	current_pid=
	printf 'stopped phase=%s pid=%s\n' "$label" "$stopping_pid"
}

start_candidate()
{
	config_file=$1
	output_file=$2
	clean_flag=$3
	if [ "$clean_flag" = yes ]; then
		/usr/bin/nohup /usr/bin/env DYLD_LIBRARY_PATH="$candidate_dir" \
			SLURM_SACK_KEY="$production_key" \
			"${candidate_dir}/slurmd" -c -Dvvv -f "$config_file" \
			>"$output_file" 2>&1 </dev/null &
	else
		/usr/bin/nohup /usr/bin/env DYLD_LIBRARY_PATH="$candidate_dir" \
			SLURM_SACK_KEY="$production_key" \
			"${candidate_dir}/slurmd" -Dvvv -f "$config_file" \
			>"$output_file" 2>&1 </dev/null &
	fi
	current_pid=$!
}

extract_start_time()
{
	/usr/bin/awk '
	{
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^SlurmdStartTime=/) {
				sub(/^SlurmdStartTime=/, "", $i)
				print $i
				exit
			}
		}
	}' "$1"
}

wait_for_daemon()
{
	expected_pid=$1
	old_start=$2
	node_file=$3
	attempt=0
	stable=0
	while [ "$attempt" -lt 60 ]; do
		if [ "$attempt" -ge 2 ] && ! is_running "$expected_pid"; then
			return 1
		fi
		observed_pid=
		[ -f "$pid_file" ] && observed_pid=$(/bin/cat "$pid_file" 2>/dev/null)
		if is_running "$expected_pid" && [ "$observed_pid" = "$expected_pid" ] && \
			[ -S "$sack_socket" ] && \
			"$scontrol" show node "$node_name" >"$node_file" 2>"${node_file}.err"; then
			new_start=$(extract_start_time "$node_file" 2>/dev/null || true)
			if [ -n "$new_start" ] && [ "$new_start" != None ] && \
				[ "$new_start" != "$old_start" ] && \
				/usr/bin/grep -q 'State=IDLE ' "$node_file"; then
				stable=$((stable + 1))
			else
				stable=0
			fi
		else
			stable=0
		fi
		[ "$stable" -ge 3 ] && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		state=$(queue_state "$job_id") || return 1
		if [ -z "$state" ]; then
			printf 'job_gone job_id=%s wait_seconds=%s\n' "$job_id" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	printf 'error: job=%s remained state=%s\n' "$job_id" "$state" >&2
	return 1
}

run_smoke()
{
	case_name=$1
	case_dir=${smoke_dir}/${case_name}
	/bin/mkdir -m 0755 "$case_dir" || return 1
	/usr/sbin/chown "$test_user" "$case_dir" || return 1
	submit_result=$(
		cd /tmp || exit 1
		/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
			SLURM_CONF="$production_conf" \
			"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
			--cpus-per-task=1 --mem=1G --gres=gpu:apple:1 --time=00:01:00 \
			--chdir=/tmp --job-name="smd013-${case_name}" \
			--output="${case_dir}/hostname.out" \
			--error="${case_dir}/hostname.err" --wrap=/bin/hostname
	) || return 1
	job_id=${submit_result%%;*}
	active_smoke=$job_id
	printf 'submitted phase=%s job_id=%s\n' "$case_name" "$job_id" >&2
	wait_job_gone "$job_id" >&2 || return 1
	"$sacct" -j "$job_id" \
		--format=JobID,JobName,User,State,ReqTRES,AllocTRES,ExitCode,NodeList \
		-P >"${case_dir}/sacct.txt" || return 1
	if ! "$sacct" -n -X -j "$job_id" --format=State,ExitCode -P | \
		/usr/bin/grep -Eq '^[[:space:]]*COMPLETED[[:space:]]*\|0:0'; then
		printf 'error: phase=%s job=%s is not COMPLETED 0:0\n' \
			"$case_name" "$job_id" >&2
		return 1
	fi
	if ! /usr/bin/grep -Eq '^PC-210(\.local)?$' "${case_dir}/hostname.out"; then
		printf 'error: phase=%s hostname mismatch\n' "$case_name" >&2
		return 1
	fi
}

make_stale_sack()
{
	if [ -e "$sack_socket" ] || [ -L "$sack_socket" ]; then
		/usr/bin/stat -f 'stale_sack_existing path=%N mode=%Sp owner=%Su group=%Sg device=%d inode=%i' \
			"$sack_socket"
		return 0
	fi
	/usr/bin/touch "$sack_socket" || return 1
	/bin/chmod 0600 "$sack_socket" || return 1
	/usr/bin/stat -f 'stale_sack path=%N mode=%Sp owner=%Su group=%Sg device=%d inode=%i' \
		"$sack_socket"
}

start_production_recovery()
{
	recovery_log=${run_dir}/slurmd-recovery.log
	if [ -e "$sack_socket" ] && [ ! -S "$sack_socket" ]; then
		/bin/rm -f -- "$sack_socket"
	fi
	start_candidate "$production_conf" "$recovery_log" no
	recovery_pid=$current_pid
	if wait_for_daemon "$recovery_pid" unknown "${run_dir}/node-recovery.txt"; then
		printf 'recovery: production config candidate started pid=%s\n' \
			"$recovery_pid" >&2
	else
		printf 'fatal recovery: candidate failed; inspect %s\n' \
			"$recovery_log" >&2
	fi
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$smoke_a"
	cancel_if_active "$smoke_b"
	cancel_if_active "$smoke_final"
	cancel_if_active "$active_smoke"

	if [ "$success" -ne 1 ] && [ "$daemon_was_stopped" -eq 1 ]; then
		need_recovery=1
		observed_pid=
		[ -f "$pid_file" ] && observed_pid=$(/bin/cat "$pid_file" 2>/dev/null)
		if is_running "$observed_pid"; then
			observed_command=$(/bin/ps -p "$observed_pid" -o command=)
			case "$observed_command" in
			"${candidate_dir}/slurmd"*)
				/bin/kill -TERM "$observed_pid" >/dev/null 2>&1 || true
				wait_for_stop "$observed_pid" || true
				;;
			*)
				printf 'recovery: another daemon is current pid=%s command=%s; no duplicate start\n' \
					"$observed_pid" "$observed_command" >&2
				need_recovery=0
				;;
			esac
		fi
		if [ "$need_recovery" -eq 1 ]; then
			start_production_recovery
		fi
		printf 'recovery: inspect evidence=%s\n' "$run_dir" >&2
	fi
	exit "$rc"
}

trap cleanup EXIT HUP INT TERM

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	printf 'error: run as root with sudo\n' >&2
	exit 77
fi

if [ "${SMD013_CONTROLLER_IDLE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: first confirm that PC-210 has no jobs and is IDLE,' \
		'then rerun with SMD013_CONTROLLER_IDLE_CONFIRMED=YES' >&2
	exit 75
fi

if ! ulimit -n unlimited; then
	printf 'error: unable to set RLIMIT_NOFILE soft limit to unlimited\n' >&2
	exit 1
fi
printf 'nofile_soft_limit=%s\n' "$(ulimit -n)"

for required_file in "$candidate_slurmd_src" "$candidate_lib_src" \
	"$production_conf" "$production_key" "$production_gres_conf" \
	"$scontrol" "$squeue" "$sbatch" "$scancel" \
	"$sacct" "$pid_file"; do
	if [ ! -e "$required_file" ]; then
		printf 'error: missing %s\n' "$required_file" >&2
		exit 66
	fi
done
if ! /usr/bin/id "$test_user" >/dev/null 2>&1; then
	printf 'error: test user %s does not exist\n' "$test_user" >&2
	exit 67
fi

/bin/mkdir -m 0755 "$run_dir" "$candidate_dir" "$isolated_spool" \
	"$smoke_dir" || exit 1
/usr/bin/install -m 0755 "$candidate_slurmd_src" \
	"${candidate_dir}/slurmd" || exit 1
/usr/bin/install -m 0755 "$candidate_lib_src" \
	"${candidate_dir}/libslurmfull.dylib" || exit 1
/bin/ln -s "$production_gres_conf" "${run_dir}/gres.conf" || exit 1
/usr/bin/shasum -a 256 "${candidate_dir}/slurmd" \
	"${candidate_dir}/libslurmfull.dylib" >"${run_dir}/candidate-sha256.txt" || exit 1
printf 'run_dir=%s\n' "$run_dir"

version=$(/usr/bin/env DYLD_LIBRARY_PATH="$candidate_dir" \
	"${candidate_dir}/slurmd" -V) || exit 1
printf 'candidate_version=%s\n' "$version"
if [ "$version" != 'slurm 26.11.0-0rc1' ]; then
	printf 'error: unexpected candidate version=%s\n' "$version" >&2
	exit 1
fi

active_jobs=$("$squeue" -h -w "$node_name" -o '%i %T %u %j') || exit 1
if [ -n "$active_jobs" ]; then
	printf 'error: PC-210 has active jobs; test not started\n%s\n' \
		"$active_jobs" >&2
	exit 75
fi
"$scontrol" ping >"${run_dir}/controller-before.txt" || exit 1
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-before.txt"; then
	printf 'error: node is not IDLE before test\n' >&2
	exit 75
fi
old_start=$(extract_start_time "${run_dir}/node-before.txt")

old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*)
	printf 'error: invalid slurmd pid=%s\n' "$old_pid" >&2
	exit 69
	;;
esac
old_command=$(/bin/ps -p "$old_pid" -o command=)
case "$old_command" in
*slurmd*) ;;
*)
	printf 'error: pid=%s is not slurmd: %s\n' "$old_pid" "$old_command" >&2
	exit 69
	;;
esac
/bin/ps -p "$old_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/slurmd-before.txt" || exit 1

if [ "$(/usr/bin/grep -c '^SlurmdSpoolDir=' "$production_conf")" -ne 1 ]; then
	printf 'error: expected exactly one SlurmdSpoolDir\n' >&2
	exit 65
fi
/usr/bin/sed \
	"s#^SlurmdSpoolDir=.*\$#SlurmdSpoolDir=${isolated_spool}#" \
	"$production_conf" >"$isolated_conf" || exit 1
if ! /usr/bin/grep -qx "SlurmdSpoolDir=${isolated_spool}" "$isolated_conf"; then
	printf 'error: failed to generate isolated configuration\n' >&2
	exit 1
fi
/usr/bin/env DYLD_LIBRARY_PATH="$candidate_dir" \
	SLURM_SACK_KEY="$production_key" \
	"${candidate_dir}/slurmd" -C -f "$isolated_conf" \
	>"${run_dir}/isolated-config-parse.txt" 2>&1 || exit 1

printf 'invalid-cred-state-for-smd013\n' >"${isolated_spool}/cred_state"
/bin/chmod 0600 "${isolated_spool}/cred_state"
/bin/mkdir -m 0755 "${isolated_spool}/job99999"
printf '#!/bin/sh\nexit 0\n' >"${isolated_spool}/job99999/slurm_script"
/bin/chmod 0755 "${isolated_spool}/job99999/slurm_script"

printf 'clean_stop old_pid=%s old_command=%s\n' "$old_pid" "$old_command"
stop_daemon "$old_pid" initial || exit 1
daemon_was_stopped=1
make_stale_sack >"${run_dir}/stale-sack-phase-a.txt" || exit 1

start_candidate "$isolated_conf" "${run_dir}/phase-a-corrupt-state.log" no
phase_a_pid=$current_pid
printf 'start phase=corrupt_state pid=%s\n' "$phase_a_pid"
if ! wait_for_daemon "$phase_a_pid" "$old_start" \
	"${run_dir}/node-phase-a.txt"; then
	printf 'error: corrupt-state phase did not become ready\n' >&2
	exit 1
fi
if ! /usr/bin/grep -q 'failed to restore job state from file' \
	"${run_dir}/phase-a-corrupt-state.log"; then
	printf 'error: corrupt cred_state warning not observed\n' >&2
	exit 1
fi
phase_a_start=$(extract_start_time "${run_dir}/node-phase-a.txt")
run_smoke corrupt-state || exit 1
smoke_a=$active_smoke
printf 'phase_a=PASS pid=%s job_id=%s\n' "$phase_a_pid" "$smoke_a"

stop_daemon "$phase_a_pid" corrupt-state || exit 1
/usr/bin/stat -f 'phase_a_saved_cred path=%N mode=%Sp owner=%Su group=%Sg size=%z' \
	"${isolated_spool}/cred_state" >"${run_dir}/phase-a-saved-cred.txt" || exit 1
make_stale_sack >"${run_dir}/stale-sack-phase-b.txt" || exit 1

start_candidate "$isolated_conf" "${run_dir}/phase-b-cleanstart.log" yes
phase_b_pid=$current_pid
printf 'start phase=cleanstart pid=%s\n' "$phase_b_pid"
if ! wait_for_daemon "$phase_b_pid" "$phase_a_start" \
	"${run_dir}/node-phase-b.txt"; then
	printf 'error: cleanstart phase did not become ready\n' >&2
	exit 1
fi
if [ -e "${isolated_spool}/job99999/slurm_script" ] || \
	[ -d "${isolated_spool}/job99999" ]; then
	printf 'error: vestigial job directory was not removed by -c\n' >&2
	exit 1
fi
if ! /usr/bin/grep -q 'Purging vestigial job script' \
	"${run_dir}/phase-b-cleanstart.log"; then
	printf 'error: vestigial job cleanup log not observed\n' >&2
	exit 1
fi
phase_b_start=$(extract_start_time "${run_dir}/node-phase-b.txt")
run_smoke cleanstart || exit 1
smoke_b=$active_smoke
printf 'phase_b=PASS pid=%s job_id=%s\n' "$phase_b_pid" "$smoke_b"

stop_daemon "$phase_b_pid" cleanstart || exit 1
start_candidate "$production_conf" "${run_dir}/production-restore.log" no
restored_pid=$current_pid
printf 'start phase=production_restore pid=%s\n' "$restored_pid"
if ! wait_for_daemon "$restored_pid" "$phase_b_start" \
	"${run_dir}/node-restored.txt"; then
	printf 'error: production-spool restore did not become ready\n' >&2
	exit 1
fi
run_smoke production-restore || exit 1
smoke_final=$active_smoke
printf 'production_restore=PASS pid=%s job_id=%s\n' \
	"$restored_pid" "$smoke_final"

"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || exit 1
"$squeue" -w "$node_name" >"${run_dir}/queue-final.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-final.txt" || \
	! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-final.txt" || \
	! /usr/bin/grep -q 'AllocTRES=$' "${run_dir}/node-final.txt"; then
	printf 'error: final node resources were not released\n' >&2
	exit 1
fi
/bin/ps -p "$restored_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/slurmd-final.txt" || exit 1
/usr/bin/stat -f 'final_sack path=%N mode=%Sp owner=%Su group=%Sg device=%d inode=%i' \
	"$sack_socket" >"${run_dir}/sack-final.txt" || exit 1

success=1
trap - EXIT HUP INT TERM
printf '%s\n' \
	"SMD013_ROOT_RUN_COMPLETE current_pid=${restored_pid} phase_a_job=${smoke_a} phase_b_job=${smoke_b} final_job=${smoke_final} run_dir=${run_dir}" \
	"NOTICE current slurmd is the validated /tmp candidate using production config and spool."
