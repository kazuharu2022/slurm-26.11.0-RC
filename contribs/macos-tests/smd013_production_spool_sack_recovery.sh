#!/bin/sh

set -u

if [ "${SMD013_PRODUCTION_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD013_PRODUCTION_CONFIRMED=YES after confirming PC-210 is idle' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
production_conf=${prefix}/etc/slurm.conf
production_key=${prefix}/etc/slurm.key
production_gres_conf=${prefix}/etc/gres.conf
production_slurmd=${prefix}/sbin/slurmd
production_lib=${prefix}/lib/slurm/libslurmfull.dylib
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
production_plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_label=org.schedmd.slurmd
service_target=system/${service_label}
pid_file=/var/run/slurmd.pid
sack_socket=/var/run/slurm/sack.socket
production_spool=/var/spool/slurmd
node_name=PC-210
partition=debug
test_user=testuser
expected_slurmd_hash=a3df64dde33256a7dff621854ff56501e854cc51ffab2ebb6f91ec5a92d94d72
expected_lib_hash=b037119a9187a189b6ba3a1efbd2b733f5f62802af6bd51f3ae8f0a3e5765d8c
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
# launchd canonicalizes /tmp to /private/tmp in its service path readback.
run_dir=/private/tmp/slurm-smd013-production-${run_stamp}
isolated_spool=${run_dir}/spool
phase_a_conf=${run_dir}/slurm.conf.phase-a
phase_b_conf=${run_dir}/slurm.conf.phase-b
phase_a_log=${run_dir}/slurmd-phase-a.log
phase_b_log=${run_dir}/slurmd-phase-b.log
phase_a_plist=${run_dir}/org.schedmd.slurmd.phase-a.plist
phase_b_plist=${run_dir}/org.schedmd.slurmd.phase-b.plist
smoke_dir=${run_dir}/smoke
old_pid=
old_start=
active_job=
phase_a_job=
phase_b_job=
final_job=
ready_pid=
ready_start=
sleep_guard_pid=
recovery_required=0
success=0

export SLURM_CONF="$production_conf"

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
}

is_running()
{
	[ -n "$1" ] && /bin/kill -0 "$1" >/dev/null 2>&1
}

service_loaded()
{
	/bin/launchctl print "$service_target" >/dev/null 2>&1
}

get_service_pid()
{
	/bin/launchctl print "$service_target" 2>/dev/null | /usr/bin/awk '
		$1 == "pid" && $2 == "=" { print $3; exit }
	'
}

get_service_path()
{
	/bin/launchctl print "$service_target" 2>/dev/null | /usr/bin/awk '
		$1 == "path" && $2 == "=" { print $3; exit }
	'
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
	while [ "$attempt" -lt 180 ]; do
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

wait_accounting_complete()
{
	job_id=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		"$sacct" -j "$job_id" -n -P \
			--format=JobIDRaw,State,ExitCode,NodeList >"$file" \
			2>"${file%.txt}.err" || true
		if /usr/bin/awk -F '|' -v job="$job_id" '
			$1 == job && $2 == "COMPLETED" && $3 == "0:0" { job_ok = 1 }
			$1 == job ".batch" && $2 == "COMPLETED" && $3 == "0:0" { batch_ok = 1 }
			END { exit !(job_ok && batch_ok) }
		' "$file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_service_unloaded()
{
	previous_pid=$1
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		if ! service_loaded && ! is_running "$previous_pid"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_service_ready()
{
	previous_pid=$1
	previous_start=$2
	expected_plist=$3
	expected_conf=$4
	node_file=$5
	launchd_file=$6
	attempt=0
	stable=0
	ready_pid=
	ready_start=
	while [ "$attempt" -lt 180 ]; do
		observed_pid=
		pid_from_file=
		service_loaded && observed_pid=$(get_service_pid 2>/dev/null || true)
		[ -f "$pid_file" ] && pid_from_file=$(/bin/cat "$pid_file" 2>/dev/null)
		if [ -n "$observed_pid" ] && [ "$observed_pid" != "$previous_pid" ] && \
			[ "$pid_from_file" = "$observed_pid" ] && is_running "$observed_pid" && \
			[ "$(get_service_path)" = "$expected_plist" ] && [ -S "$sack_socket" ] && \
			/bin/ps -p "$observed_pid" -o command= | \
				/usr/bin/grep -Fq "$expected_conf" && \
			"$scontrol" show node "$node_name" >"$node_file" 2>"${node_file}.err"; then
			state=$(node_field State "$node_file")
			cpu_alloc=$(node_field CPUAlloc "$node_file")
			start=$(node_field SlurmdStartTime "$node_file")
			if [ "$state" = IDLE ] && [ "$cpu_alloc" = 0 ] && \
				[ -n "$start" ] && [ "$start" != None ] && \
				[ "$start" != "$previous_start" ]; then
				stable=$((stable + 1))
				ready_pid=$observed_pid
				ready_start=$start
			else
				stable=0
			fi
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			/bin/launchctl print "$service_target" >"$launchd_file" 2>&1 || return 1
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_production_ready()
{
	node_file=$1
	launchd_file=$2
	attempt=0
	stable=0
	while [ "$attempt" -lt 180 ]; do
		observed_pid=
		pid_from_file=
		service_loaded && observed_pid=$(get_service_pid 2>/dev/null || true)
		[ -f "$pid_file" ] && pid_from_file=$(/bin/cat "$pid_file" 2>/dev/null)
		if [ -n "$observed_pid" ] && [ "$pid_from_file" = "$observed_pid" ] && \
			is_running "$observed_pid" && \
			[ "$(get_service_path)" = "$production_plist" ] && \
			[ -S "$sack_socket" ] && \
			/bin/ps -p "$observed_pid" -o command= | \
				/usr/bin/grep -Fq "$production_conf" && \
			"$scontrol" show node "$node_name" >"$node_file" 2>"${node_file}.err"; then
			state=$(node_field State "$node_file")
			cpu_alloc=$(node_field CPUAlloc "$node_file")
			if [ "$state" = IDLE ] && [ "$cpu_alloc" = 0 ]; then
				stable=$((stable + 1))
				ready_pid=$observed_pid
				ready_start=$(node_field SlurmdStartTime "$node_file")
			else
				stable=0
			fi
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			/bin/launchctl print "$service_target" >"$launchd_file" 2>&1 || return 1
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

bootout_service()
{
	previous_pid=$1
	label=$2
	/usr/bin/printf 'stop phase=%s pid=%s method=launchctl_bootout\n' \
		"$label" "$previous_pid"
	/bin/launchctl bootout "$service_target" \
		>"${run_dir}/bootout-${label}.out" 2>"${run_dir}/bootout-${label}.err" || return 1
	wait_service_unloaded "$previous_pid"
}

bootstrap_service()
{
	plist_path=$1
	label=$2
	/bin/launchctl enable "$service_target" >/dev/null 2>&1 || return 1
	/bin/launchctl bootstrap system "$plist_path" \
		>"${run_dir}/bootstrap-${label}.out" 2>"${run_dir}/bootstrap-${label}.err"
}

make_candidate_plist()
{
	destination=$1
	config_file=$2
	stdout_file=$3
	stderr_file=$4
	clean_flag=$5
	/bin/cp -p "$production_plist" "$destination" || return 1
	if [ "$clean_flag" = yes ]; then
		arguments="[\"${production_slurmd}\",\"-c\",\"-Dvvv\",\"-f\",\"${config_file}\",\"-N\",\"${node_name}\"]"
	else
		arguments="[\"${production_slurmd}\",\"-Dvvv\",\"-f\",\"${config_file}\",\"-N\",\"${node_name}\"]"
	fi
	/usr/bin/plutil -replace ProgramArguments -json "$arguments" "$destination" || return 1
	/usr/bin/plutil -replace EnvironmentVariables.SLURM_CONF \
		-string "$config_file" "$destination" || return 1
	/usr/bin/plutil -replace StandardOutPath -string "$stdout_file" \
		"$destination" || return 1
	/usr/bin/plutil -replace StandardErrorPath -string "$stderr_file" \
		"$destination" || return 1
	/usr/sbin/chown 0:0 "$destination" || return 1
	/bin/chmod 0644 "$destination" || return 1
	/usr/bin/plutil -lint "$destination" >/dev/null 2>&1
}

make_stale_sack()
{
	label=$1
	if [ -e "$sack_socket" ] || [ -L "$sack_socket" ]; then
		/bin/rm -f -- "$sack_socket" || return 1
	fi
	/usr/bin/touch "$sack_socket" || return 1
	/bin/chmod 0600 "$sack_socket" || return 1
	/usr/bin/stat -f 'stale_sack path=%N mode=%Sp owner=%Su group=%Sg device=%d inode=%i' \
		"$sack_socket" >"${run_dir}/stale-sack-${label}.txt"
}

run_smoke()
{
	case_name=$1
	case_dir=${smoke_dir}/${case_name}
	/bin/mkdir -m 0755 "$case_dir" || return 1
	/usr/sbin/chown "$test_user" "$case_dir" || return 1
	job_result=$(
		cd /tmp || exit 1
		/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
			SLURM_CONF="$production_conf" \
			"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
			--cpus-per-task=1 --mem=1G --gres=gpu:apple:1 --time=00:01:00 \
			--chdir=/tmp --job-name="smd013-${case_name}" \
			--output="${case_dir}/hostname.out" \
			--error="${case_dir}/hostname.err" --wrap=/bin/hostname
	) || return 1
	active_job=${job_result%%;*}
	/usr/bin/printf 'submitted phase=%s job_id=%s\n' "$case_name" "$active_job"
	wait_job_gone "$active_job" || return 1
	wait_accounting_complete "$active_job" "${case_dir}/sacct.txt" || return 1
	/usr/bin/grep -Eq '^PC-210(\.local)?$' "${case_dir}/hostname.out" || return 1
	[ ! -s "${case_dir}/hostname.err" ] || return 1
}

recover_production_service()
{
	current_service_pid=
	service_loaded && current_service_pid=$(get_service_pid 2>/dev/null || true)
	if service_loaded; then
		/bin/launchctl bootout "$service_target" >/dev/null 2>&1 || true
		[ -n "$current_service_pid" ] && \
			wait_service_unloaded "$current_service_pid" || true
	fi
	if [ -e "$sack_socket" ] && [ ! -S "$sack_socket" ]; then
		/bin/rm -f -- "$sack_socket" || return 1
	fi
	bootstrap_service "$production_plist" recovery || return 1
	wait_production_ready "${run_dir}/node-recovery.txt" \
		"${run_dir}/launchd-recovery.txt"
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$active_job"
	cancel_if_active "$phase_a_job"
	cancel_if_active "$phase_b_job"
	cancel_if_active "$final_job"
	if [ "$success" -ne 1 ] && [ "$recovery_required" -eq 1 ]; then
		if recover_production_service; then
			/usr/bin/printf 'recovery: production launchd service is stably IDLE pid=%s\n' \
				"$ready_pid" >&2
		else
			/usr/bin/printf 'fatal recovery: production launchd service did not recover\n' >&2
			rc=1
		fi
		/usr/bin/printf 'recovery: inspect run_dir=%s\n' "$run_dir" >&2
	fi
	exit "$rc"
}

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	fail 'run as root'
fi

for required in "$production_conf" "$production_key" "$production_gres_conf" \
	"$production_slurmd" "$production_lib" "$scontrol" "$squeue" "$sbatch" \
	"$scancel" "$sacct" "$production_plist" "$pid_file" "$production_spool" \
	/usr/bin/caffeinate; do
	[ -e "$required" ] || fail "missing required path: $required"
done
/usr/bin/id "$test_user" >/dev/null 2>&1 || fail "missing user: $test_user"

/bin/mkdir -m 0755 "$run_dir" "$isolated_spool" "$smoke_dir" || \
	fail 'cannot create run directories'
trap cleanup EXIT HUP INT TERM
/usr/bin/printf 'run_dir=%s\n' "$run_dir"
/usr/bin/caffeinate -dimsu -w "$$" >/dev/null 2>&1 &
sleep_guard_pid=$!
/bin/sleep 1
is_running "$sleep_guard_pid" || fail 'caffeinate sleep guard did not start'
/usr/bin/printf 'sleep_guard=ACTIVE pid=%s\n' "$sleep_guard_pid"

/usr/bin/plutil -lint "$production_plist" >"${run_dir}/production-plist-lint.txt" \
	2>&1 || fail 'production plist is invalid'
/bin/launchctl print-disabled system >"${run_dir}/launchd-disabled-before.txt" \
	2>&1 || fail 'cannot inspect launchd enabled state'
/usr/bin/grep -Fq "\"${service_label}\" => enabled" \
	"${run_dir}/launchd-disabled-before.txt" || fail 'production service is not enabled'
service_loaded || fail 'production launchd service is not loaded'
[ "$(get_service_path)" = "$production_plist" ] || fail 'unexpected launchd plist path'
/bin/launchctl print "$service_target" >"${run_dir}/launchd-before.txt" 2>&1 || \
	fail 'cannot inspect launchd service'
/usr/bin/grep -q 'state = running' "${run_dir}/launchd-before.txt" || \
	fail 'production launchd service is not running'

actual_slurmd_hash=$(/usr/bin/shasum -a 256 "$production_slurmd" | /usr/bin/awk '{print $1}')
actual_lib_hash=$(/usr/bin/shasum -a 256 "$production_lib" | /usr/bin/awk '{print $1}')
[ "$actual_slurmd_hash" = "$expected_slurmd_hash" ] || fail 'production slurmd hash mismatch'
[ "$actual_lib_hash" = "$expected_lib_hash" ] || fail 'production libslurmfull hash mismatch'
/usr/bin/shasum -a 256 "$production_conf" "$production_slurmd" "$production_lib" \
	"$production_plist" >"${run_dir}/production-artifacts-before.sha256" || \
	fail 'cannot hash production artifacts'
/bin/cp -p "$production_conf" "${run_dir}/slurm.conf.production-before" || \
	fail 'cannot snapshot production config'

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node read failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'

old_pid=$(get_service_pid)
pid_from_file=$(/bin/cat "$pid_file")
case "$old_pid:$pid_from_file" in
''|*[!0-9:]*) fail "invalid launchd/pidfile identity=$old_pid:$pid_from_file" ;;
esac
[ "$old_pid" = "$pid_from_file" ] || fail 'launchd and pidfile PID mismatch'
is_running "$old_pid" || fail "slurmd pid=$old_pid is not running"
/bin/ps -p "$old_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/slurmd-before.txt" || fail 'cannot inspect slurmd process'
/usr/bin/awk -v expected="$production_slurmd" '
	$1 == "root" && $3 == 1 && index($0, expected) { ok = 1 }
	END { exit !ok }
' "${run_dir}/slurmd-before.txt" || fail 'slurmd is not root/PPID-1/production-prefix'
old_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")
[ -n "$old_start" ] && [ "$old_start" != None ] || fail 'invalid SlurmdStartTime'
[ -S "$sack_socket" ] || fail 'SACK socket is absent'

[ "$(/usr/bin/grep -c '^SlurmdSpoolDir=' "$production_conf")" -eq 1 ] || \
	fail 'expected exactly one SlurmdSpoolDir'
/usr/bin/grep -qx "SlurmdSpoolDir=${production_spool}" "$production_conf" || \
	fail 'unexpected production SlurmdSpoolDir'
[ "$(/usr/bin/grep -c '^SlurmdLogFile=' "$production_conf")" -eq 1 ] || \
	fail 'expected exactly one SlurmdLogFile'

/bin/ln -s "$production_gres_conf" "${run_dir}/gres.conf" || \
	fail 'cannot link gres.conf'
/usr/bin/sed \
	-e "s#^SlurmdSpoolDir=.*\$#SlurmdSpoolDir=${isolated_spool}#" \
	-e "s#^SlurmdLogFile=.*\$#SlurmdLogFile=${phase_a_log}#" \
	"$production_conf" >"$phase_a_conf" || fail 'cannot generate phase A config'
/usr/bin/sed \
	-e "s#^SlurmdSpoolDir=.*\$#SlurmdSpoolDir=${isolated_spool}#" \
	-e "s#^SlurmdLogFile=.*\$#SlurmdLogFile=${phase_b_log}#" \
	"$production_conf" >"$phase_b_conf" || fail 'cannot generate phase B config'
/usr/bin/env SLURM_SACK_KEY="$production_key" \
	"$production_slurmd" -C -f "$phase_a_conf" \
	>"${run_dir}/phase-a-config-parse.txt" 2>&1 || fail 'phase A config parse failed'
/usr/bin/env SLURM_SACK_KEY="$production_key" \
	"$production_slurmd" -C -f "$phase_b_conf" \
	>"${run_dir}/phase-b-config-parse.txt" 2>&1 || fail 'phase B config parse failed'
make_candidate_plist "$phase_a_plist" "$phase_a_conf" \
	"${run_dir}/phase-a-launchd.out" "${run_dir}/phase-a-launchd.err" no || \
	fail 'cannot build phase A plist'
make_candidate_plist "$phase_b_plist" "$phase_b_conf" \
	"${run_dir}/phase-b-launchd.out" "${run_dir}/phase-b-launchd.err" yes || \
	fail 'cannot build phase B plist'

/usr/bin/printf 'invalid-cred-state-for-smd013-production\n' \
	>"${isolated_spool}/cred_state" || fail 'cannot create corrupt credential fixture'
/bin/chmod 0600 "${isolated_spool}/cred_state" || fail 'cannot mode credential fixture'
/bin/mkdir -m 0755 "${isolated_spool}/job99999" || fail 'cannot create vestigial job dir'
/usr/bin/printf '#!/bin/sh\nexit 0\n' \
	>"${isolated_spool}/job99999/slurm_script" || fail 'cannot create vestigial script'
/bin/chmod 0755 "${isolated_spool}/job99999/slurm_script" || \
	fail 'cannot mode vestigial script'
/usr/bin/find "$production_spool" -maxdepth 2 -print \
	>"${run_dir}/production-spool-before.txt" || fail 'cannot inspect production spool'

recovery_required=1
bootout_service "$old_pid" production || fail 'production launchd bootout failed'
make_stale_sack phase-a || fail 'cannot create phase A stale SACK fixture'
bootstrap_service "$phase_a_plist" phase-a || fail 'phase A bootstrap failed'
wait_service_ready "$old_pid" "$old_start" "$phase_a_plist" "$phase_a_conf" \
	"${run_dir}/node-phase-a.txt" "${run_dir}/launchd-phase-a.txt" || \
	fail 'phase A service did not become stably IDLE'
phase_a_pid=$ready_pid
phase_a_start=$ready_start
/usr/bin/grep -q 'failed to restore job state from file' "$phase_a_log" || \
	fail 'corrupt cred_state warning was not observed'
/usr/bin/stat -f 'phase_a_sack path=%N mode=%Sp owner=%Su group=%Sg device=%d inode=%i' \
	"$sack_socket" >"${run_dir}/sack-phase-a.txt" || fail 'cannot stat phase A SACK'
run_smoke phase-a || fail 'phase A smoke job failed'
phase_a_job=$active_job
active_job=
/usr/bin/printf 'phase_a=PASS pid=%s job_id=%s\n' "$phase_a_pid" "$phase_a_job"

bootout_service "$phase_a_pid" phase-a || fail 'phase A bootout failed'
/bin/cp "$phase_a_log" "${run_dir}/phase-a-log-evidence.txt" || \
	fail 'cannot snapshot phase A log'
/bin/chmod 0444 "${run_dir}/phase-a-log-evidence.txt" || \
	fail 'cannot make phase A log evidence readable'
/usr/bin/stat -f 'phase_a_saved_cred path=%N mode=%Sp owner=%Su group=%Sg size=%z' \
	"${isolated_spool}/cred_state" >"${run_dir}/phase-a-saved-cred.txt" || \
	fail 'phase A did not save credential state'
[ -e "${isolated_spool}/job99999/slurm_script" ] || \
	fail 'phase A unexpectedly removed vestigial script without -c'
make_stale_sack phase-b || fail 'cannot create phase B stale SACK fixture'
bootstrap_service "$phase_b_plist" phase-b || fail 'phase B bootstrap failed'
wait_service_ready "$phase_a_pid" "$phase_a_start" "$phase_b_plist" "$phase_b_conf" \
	"${run_dir}/node-phase-b.txt" "${run_dir}/launchd-phase-b.txt" || \
	fail 'phase B service did not become stably IDLE'
phase_b_pid=$ready_pid
phase_b_start=$ready_start
[ ! -e "${isolated_spool}/job99999/slurm_script" ] || \
	fail 'phase B did not remove vestigial script'
[ ! -d "${isolated_spool}/job99999" ] || \
	fail 'phase B did not remove vestigial job directory'
/usr/bin/grep -q 'Purging vestigial job script' "$phase_b_log" || \
	fail 'vestigial job cleanup log was not observed'
/usr/bin/stat -f 'phase_b_sack path=%N mode=%Sp owner=%Su group=%Sg device=%d inode=%i' \
	"$sack_socket" >"${run_dir}/sack-phase-b.txt" || fail 'cannot stat phase B SACK'
run_smoke phase-b || fail 'phase B smoke job failed'
phase_b_job=$active_job
active_job=
/usr/bin/printf 'phase_b=PASS pid=%s job_id=%s\n' "$phase_b_pid" "$phase_b_job"

bootout_service "$phase_b_pid" phase-b || fail 'phase B bootout failed'
/bin/cp "$phase_b_log" "${run_dir}/phase-b-log-evidence.txt" || \
	fail 'cannot snapshot phase B log'
/bin/chmod 0444 "${run_dir}/phase-b-log-evidence.txt" || \
	fail 'cannot make phase B log evidence readable'
if [ -e "$sack_socket" ] && [ ! -S "$sack_socket" ]; then
	/bin/rm -f -- "$sack_socket" || fail 'cannot remove stale SACK before production restore'
fi
bootstrap_service "$production_plist" production-restore || \
	fail 'production launchd bootstrap failed'
wait_service_ready "$phase_b_pid" "$phase_b_start" "$production_plist" \
	"$production_conf" "${run_dir}/node-production-restored.txt" \
	"${run_dir}/launchd-production-restored.txt" || \
	fail 'production service did not become stably IDLE'
restored_pid=$ready_pid
restored_start=$ready_start
recovery_required=0
run_smoke production-restore || fail 'production restore smoke job failed'
final_job=$active_job
active_job=
/usr/bin/printf 'production_restore=PASS pid=%s job_id=%s\n' \
	"$restored_pid" "$final_job"

"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || fail 'final node read failed'
"$squeue" -h -w "$node_name" -o '%i|%T|%u|%j|%N' \
	>"${run_dir}/queue-final.txt" || fail 'final queue read failed'
[ "$(node_field State "${run_dir}/node-final.txt")" = IDLE ] || fail 'final node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-final.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-final.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$(/bin/cat "${run_dir}/queue-final.txt")" ] || fail 'final queue is not empty'
[ "$(get_service_path)" = "$production_plist" ] || fail 'final service is not production plist'
[ -S "$sack_socket" ] || fail 'final SACK socket is absent'
[ -f "${production_spool}/cred_state" ] || fail 'production cred_state is absent'
[ ! -e "${production_spool}/job99999" ] || fail 'test fixture leaked into production spool'
/usr/bin/find "$production_spool" -maxdepth 2 -print \
	>"${run_dir}/production-spool-after.txt" || fail 'cannot inspect final production spool'
/usr/bin/shasum -a 256 "$production_conf" "$production_slurmd" "$production_lib" \
	"$production_plist" >"${run_dir}/production-artifacts-after.sha256" || \
	fail 'cannot hash final production artifacts'
/usr/bin/cmp -s "${run_dir}/production-artifacts-before.sha256" \
	"${run_dir}/production-artifacts-after.sha256" || fail 'production artifact hashes changed'
/usr/bin/cmp -s "${run_dir}/slurm.conf.production-before" "$production_conf" || \
	fail 'production config changed'
/bin/launchctl print "$service_target" >"${run_dir}/launchd-final.txt" 2>&1 || \
	fail 'cannot snapshot final launchd service'
/bin/ps -p "$restored_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/slurmd-final.txt" || fail 'cannot snapshot final slurmd process'
/usr/bin/stat -f 'final_sack path=%N mode=%Sp owner=%Su group=%Sg device=%d inode=%i' \
	"$sack_socket" >"${run_dir}/sack-final.txt" || fail 'cannot stat final SACK'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s\n' \
	"SMD013_PRODUCTION_REVALIDATION_COMPLETE initial_pid=${old_pid} phase_a_pid=${phase_a_pid} phase_a_job=${phase_a_job} phase_b_pid=${phase_b_pid} phase_b_job=${phase_b_job} restored_pid=${restored_pid} restored_start=${restored_start} final_job=${final_job} node=IDLE queue=EMPTY artifacts=UNCHANGED launchd=PRODUCTION run_dir=${run_dir}"
