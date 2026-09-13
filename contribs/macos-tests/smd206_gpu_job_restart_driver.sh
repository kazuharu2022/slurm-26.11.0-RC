#!/bin/sh

set -u

if [ "${SMD206_GPU_JOB_RESTART_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD206_GPU_JOB_RESTART_CONFIRMED=YES after approving one launchd slurmd restart while a GPU job is running, target cancellation, and queued recovery GPU job execution' >&2
	exit 64
fi

source_dir=/Users/REDACTED_USER/dev/slurm.26-05/contribs/macos-tests
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
mlx_job=${prefix}/share/macos-gpu-job/mlx_gpu_smoke.sbatch
payload_source=${source_dir}/smd206_restart_survivor_payload.sh
pid_file=/var/run/slurmd.pid
sack_socket=/var/run/slurm/sack.socket
slurmd_log=/var/log/slurm/slurmd.log
plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_label=org.schedmd.slurmd
service_target=system/${service_label}
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd206-running-${run_stamp}
output_dir=${run_dir}/output
payload=${run_dir}/survivor-payload.sh
heartbeat=${output_dir}/target-heartbeat.txt
target_job=
probe_job=
target_pid=
old_pid=
new_pid=
old_start=
new_start=
restart_started=0
success=0
log_line_before=0

export SLURM_CONF="$slurm_conf"

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

field_from_file()
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

tres_count_is_one()
{
	value=$1
	key=$2
	/usr/bin/awk -v value="$value" -v key="$key" 'BEGIN {
		n = split(value, item, ",")
		seen = 0
		for (i = 1; i <= n; i++) {
			split(item[i], pair, "=")
			if (pair[1] == key && pair[2] == "1")
				seen++
		}
		exit !(seen == 1)
	}'
}

verify_gpu_counts()
{
	file=$1
	/usr/bin/grep -Fq 'Gres=gpu:apple:1' "$file" || return 1
	cfg=$(field_from_file CfgTRES "$file")
	tres_count_is_one "$cfg" gres/gpu || return 1
	tres_count_is_one "$cfg" gres/gpu:apple || return 1
	return 0
}

verify_single_gpu_allocation()
{
	file=$1
	alloc=$(field_from_file AllocTRES "$file")
	tres_count_is_one "$alloc" gres/gpu || return 1
	tres_count_is_one "$alloc" gres/gpu:apple || return 1
	return 0
}

queue_state()
{
	queue_output=$("$squeue" -h -j "$1" -o '%T' 2>/dev/null) || return 1
	/usr/bin/printf '%s\n' "$queue_output" |
		/usr/bin/awk 'NR == 1 { print; exit }'
}

job_field()
{
	job_id=$1
	field=$2
	job_output=$("$scontrol" -o show job "$job_id" 2>/dev/null) || return 1
	/usr/bin/printf '%s\n' "$job_output" | /usr/bin/awk -v key="${field}=" '
	{
		for (i = 1; i <= NF; i++) {
			if (index($i, key) == 1) {
				sub(key, "", $i)
				print $i
				exit
			}
		}
	}'
}

cancel_if_active()
{
	job_id=$1
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id" 2>/dev/null) || return 0
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
		state=$(queue_state "$job_id") || return 1
		if [ -z "$state" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' "$job_id" "$attempt"
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

bootstrap_service()
{
	/bin/launchctl enable "$service_target" || return 1
	/bin/launchctl bootstrap system "$plist" || return 1
}

restart_service()
{
	previous_pid=$1
	/bin/launchctl bootout "$service_target" \
		>"${run_dir}/bootout.out" 2>"${run_dir}/bootout.err" || return 1
	wait_service_unloaded "$previous_pid" || return 1
	bootstrap_service >"${run_dir}/bootstrap.out" 2>"${run_dir}/bootstrap.err" || return 1
	return 0
}

wait_restarted_registration()
{
	previous_pid=$1
	attempt=0
	stable=0
	while [ "$attempt" -lt 180 ]; do
		observed_pid=
		pid_from_file=
		service_loaded && observed_pid=$(get_service_pid 2>/dev/null || true)
		[ -f "$pid_file" ] && pid_from_file=$(/bin/cat "$pid_file" 2>/dev/null)
		if [ -n "$observed_pid" ] && [ "$observed_pid" != "$previous_pid" ] && \
			[ "$pid_from_file" = "$observed_pid" ] && is_running "$observed_pid" && \
			[ -S "$sack_socket" ] && \
			"$scontrol" show node "$node_name" >"${run_dir}/node-after-restart.txt" \
			2>"${run_dir}/node-after-restart.err"; then
			state=$(field_from_file State "${run_dir}/node-after-restart.txt")
			new_start=$(field_from_file SlurmdStartTime "${run_dir}/node-after-restart.txt")
			case "$state" in
			*NOT_RESPONDING*|*INVALID_REG*|*INVAL*|DOWN*|'') stable=0 ;;
			*)
				if [ -n "$new_start" ] && [ "$new_start" != "$old_start" ] && \
					verify_gpu_counts "${run_dir}/node-after-restart.txt" && \
					verify_single_gpu_allocation "${run_dir}/node-after-restart.txt"; then
					new_pid=$observed_pid
					stable=$((stable + 1))
				else
					stable=0
				fi
				;;
			esac
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			/bin/launchctl print "$service_target" >"${run_dir}/launchd-after-restart.txt" 2>&1 || return 1
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_marker()
{
	job_id=$1
	file=$2
	marker=$3
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		if [ -f "$file" ] && /usr/bin/grep -Fq "$marker" "$file"; then
			return 0
		fi
		state=$(queue_state "$job_id") || return 1
		case "$state" in
		RUNNING|COMPLETING|PENDING) ;;
		*) return 1 ;;
		esac
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

heartbeat_sequence()
{
	[ -f "$heartbeat" ] || return 1
	/usr/bin/awk 'NR == 1 { print $1; exit }' "$heartbeat"
}

wait_pending_resources()
{
	phase=$1
	attempt=0
	stable=0
	: >"${run_dir}/probe-pending-${phase}.txt"
	while [ "$attempt" -lt 60 ]; do
		target_state=$(queue_state "$target_job") || return 1
		state=$(queue_state "$probe_job") || return 1
		reason=$(job_field "$probe_job" Reason) || return 1
		/usr/bin/printf 'attempt=%s target_state=%s probe_state=%s canonical_reason=%s\n' \
			"$attempt" "$target_state" "$state" "$reason" \
			>>"${run_dir}/probe-pending-${phase}.txt"
		if [ "$target_state" = RUNNING ] && [ "$state" = PENDING ] && \
			[ "$reason" = Resources ]; then
			stable=$((stable + 1))
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			/usr/bin/printf 'probe_blocked phase=%s target_job=%s state=%s probe_job=%s state=%s reason=%s wait_seconds=%s\n' \
				"$phase" "$target_job" "$target_state" "$probe_job" "$state" \
				"$reason" "$attempt"
			return 0
		fi
		if [ "$target_state" != RUNNING ] || [ "$state" = RUNNING ] || \
			[ -z "$state" ]; then
			return 1
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

capture_accounting()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES%200,AllocTRES%200 \
		>"$file" 2>"${file%.txt}.err" || true
}

wait_accounting()
{
	kind=$1
	job_id=$2
	file=$3
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		capture_accounting "$job_id" "$file"
		if /usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" -v kind="$kind" '
		function has(value, expected, n, item, i) {
			n = split(value, item, ",")
			for (i = 1; i <= n; i++)
				if (item[i] == expected)
					return 1
			return 0
		}
		$1 == job && $2 == user {
			if (kind == "cancel")
				state_ok = ($3 ~ /^CANCELLED/)
			else
				state_ok = ($3 == "COMPLETED" && $4 == "0:0")
			job_ok = state_ok && has($6, "gres/gpu=1") &&
				has($6, "gres/gpu:apple=1") && has($7, "gres/gpu=1") &&
				has($7, "gres/gpu:apple=1")
		}
		$1 == job ".batch" {
			if (kind == "cancel")
				batch_ok = ($3 ~ /^CANCELLED/)
			else
				batch_ok = ($3 == "COMPLETED" && $4 == "0:0")
		}
		END { exit !(job_ok && batch_ok) }
		' "$file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_pid_absent()
{
	pid=$1
	case "$pid" in
	''|*[!0-9]*) return 1 ;;
	esac
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if ! is_running "$pid"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_final_idle()
{
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" \
			2>"${run_dir}/node-final.err" || true
		state=$(field_from_file State "${run_dir}/node-final.txt")
		cpu=$(field_from_file CPUAlloc "${run_dir}/node-final.txt")
		mem=$(field_from_file AllocMem "${run_dir}/node-final.txt")
		alloc=$(field_from_file AllocTRES "${run_dir}/node-final.txt")
		if [ "$state" = IDLE ] && [ "$cpu" = 0 ] && [ "$mem" = 0 ] && \
			[ -z "$alloc" ] && verify_gpu_counts "${run_dir}/node-final.txt"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

recover_runtime()
{
	current=
	service_loaded && current=$(get_service_pid 2>/dev/null || true)
	if [ -z "$current" ] || ! is_running "$current"; then
		if service_loaded; then
			/bin/launchctl bootout "$service_target" >/dev/null 2>&1 || return 1
			wait_service_unloaded "$current" || return 1
		fi
		bootstrap_service >/dev/null 2>&1 || return 1
	fi
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if "$scontrol" show node "$node_name" >"${run_dir}/recovery-node.txt" 2>/dev/null; then
			state=$(field_from_file State "${run_dir}/recovery-node.txt")
			case "$state" in
			*INVALID_REG*|*INVAL*|*NOT_RESPONDING*) ;;
			*DRAIN*|DOWN*)
				"$scontrol" update NodeName="$node_name" State=RESUME >/dev/null 2>&1 || true
				;;
			*) return 0 ;;
			esac
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

make_output_readable()
{
	[ -d "$output_dir" ] || return 0
	/bin/chmod 0755 "$output_dir" || return 1
	for file in "$output_dir"/*; do
		[ -e "$file" ] || continue
		/bin/chmod 0644 "$file" || return 1
	done
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$target_job"
	cancel_if_active "$probe_job"
	[ -z "$target_job" ] || wait_job_gone "$target_job" >/dev/null 2>&1 || true
	[ -z "$probe_job" ] || wait_job_gone "$probe_job" >/dev/null 2>&1 || true
	if [ "$restart_started" -eq 1 ] && ! recover_runtime; then
		/usr/bin/printf 'fatal recovery: production launchd slurmd did not recover; inspect run_dir=%s\n' \
			"$run_dir" >&2
		rc=1
	fi
	make_output_readable || rc=1
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: production configuration was not changed; jobs were cancelled and launchd recovery was attempted; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$gres_conf" "$slurmd" "$scontrol" \
	"$squeue" "$sbatch" "$scancel" "$sacct" "$mlx_job" "$payload_source" \
	"$pid_file" "$sack_socket" "$slurmd_log" "$plist"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for command in /usr/bin/awk /usr/bin/cmp /usr/bin/env /usr/bin/grep \
	/usr/bin/id /usr/bin/install /usr/bin/pgrep /usr/bin/sed /usr/bin/shasum \
	/usr/bin/sudo /usr/bin/tr /usr/bin/uname /usr/bin/wc /usr/sbin/chown \
	/bin/bash /bin/cat /bin/chmod /bin/date /bin/kill /bin/launchctl \
	/bin/mkdir /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
/usr/bin/install -o 0 -g 0 -m 0555 "$payload_source" "$payload" || fail 'cannot stage payload'
/usr/bin/printf 'run_dir=%s phase=gpu_job_running_restart\n' "$run_dir"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
[ "$(field_from_file State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(field_from_file CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'CPUAlloc is not zero'
[ "$(field_from_file AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'AllocMem is not zero'
verify_gpu_counts "${run_dir}/node-before.txt" || fail 'initial configured GPU count is not exactly one'
queue_before=$("$squeue" -h -w "$node_name") || fail 'initial queue query failed'
[ -z "$queue_before" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

service_loaded || fail "launchd service is not loaded: $service_target"
/bin/launchctl print "$service_target" >"${run_dir}/launchd-before.txt" 2>&1 || fail 'cannot inspect launchd service'
old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$old_pid" ;;
esac
[ "$(get_service_pid)" = "$old_pid" ] || fail 'launchd and pidfile PID mismatch'
is_running "$old_pid" || fail "slurmd pid=$old_pid is not running"
[ "$(/bin/ps -p "$old_pid" -o ppid= | /usr/bin/tr -d ' ')" = 1 ] || fail 'slurmd is not parented by launchd'
old_start=$(field_from_file SlurmdStartTime "${run_dir}/node-before.txt")
[ -n "$old_start" ] || fail 'missing initial SlurmdStartTime'
/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$plist" >"${run_dir}/production-before.sha256"
"$slurmd" -G -f "$slurm_conf" >"${run_dir}/gres-before.stdout" 2>"${run_dir}/gres-before.stderr" || fail 'initial slurmd -G failed'
/usr/bin/grep -Eq 'Gres Name=gpu Type=apple Count=1 .*File=/dev/null' "${run_dir}/gres-before.stderr" || fail 'initial slurmd -G count is not one'
log_line_before=$(/usr/bin/wc -l <"$slurmd_log" | /usr/bin/tr -d ' ')

target_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=2 --mem=4G --gres=gpu:apple:1 --time=00:05:00 \
		--no-requeue --chdir=/tmp --job-name=smd206-restart-survivor \
		--output="${output_dir}/target-%j.out" --error="${output_dir}/target-%j.err" \
		"$payload" "$mlx_job" "$heartbeat"
) || fail 'target GPU job submission failed'
target_job=${target_job%%;*}
case "$target_job" in
''|*[!0-9]*) fail "invalid target job id=$target_job" ;;
esac
/usr/bin/printf 'submitted target_job=%s\n' "$target_job"
wait_marker "$target_job" "${output_dir}/target-${target_job}.out" 'restart_ready sequence=1' || fail 'target GPU job did not reach restart-ready marker'
target_pid=$(field_from_file payload_pid "${output_dir}/target-${target_job}.out")
case "$target_pid" in
''|*[!0-9]*) fail "invalid target payload pid=$target_pid" ;;
esac
/usr/bin/grep -Eq '^job_gpus=0$' "${output_dir}/target-${target_job}.out" || fail 'target wrapper lacks job_gpus=0'
/usr/bin/grep -Eq '^slurm_job_gpus=0$' "${output_dir}/target-${target_job}.out" || fail 'target lacks SLURM_JOB_GPUS=0'
/usr/bin/grep -Fq "actual_uid=${test_uid}" "${output_dir}/target-${target_job}.out" || fail 'target UID mismatch'
/usr/bin/grep -Fq "actual_gid=${test_gid}" "${output_dir}/target-${target_job}.out" || fail 'target GID mismatch'
/usr/bin/grep -Fq "'device_name': 'Apple M5 Max'" "${output_dir}/target-${target_job}.out" || fail 'target did not use Apple M5 Max'
/usr/bin/grep -Fq 'gpu_smoke_test=PASS' "${output_dir}/target-${target_job}.out" || fail 'target MLX smoke failed'
heartbeat_before=$(heartbeat_sequence) || fail 'cannot read heartbeat before restart'

"$scontrol" show node "$node_name" >"${run_dir}/node-target-running.txt" || fail 'cannot read allocated node'
verify_gpu_counts "${run_dir}/node-target-running.txt" || fail 'configured GPU count changed before restart'
verify_single_gpu_allocation "${run_dir}/node-target-running.txt" || fail 'allocated GPU count is not exactly one before restart'
"$scontrol" -d -o show job "$target_job" >"${run_dir}/target-before-restart.txt" || fail 'cannot capture target before restart'

probe_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=2 --mem=4G --gres=gpu:apple:1 --time=00:02:00 \
		--no-requeue --chdir=/tmp --job-name=smd206-post-restart-probe \
		--output="${output_dir}/probe-%j.out" --error="${output_dir}/probe-%j.err" \
		"$mlx_job"
) || fail 'probe GPU job submission failed'
probe_job=${probe_job%%;*}
case "$probe_job" in
''|*[!0-9]*) fail "invalid probe job id=$probe_job" ;;
esac
/usr/bin/printf 'submitted probe_job=%s\n' "$probe_job"
wait_pending_resources before-restart || \
	fail 'probe did not remain pending for the single allocated GPU before restart'

restart_started=1
restart_service "$old_pid" || fail 'launchd slurmd restart failed while GPU job was running'
wait_restarted_registration "$old_pid" || fail 'restarted slurmd did not register with exactly one allocated GPU'
heartbeat_after=$(heartbeat_sequence) || fail 'cannot read heartbeat after restart'
[ "$heartbeat_after" -gt "$heartbeat_before" ] || fail 'target heartbeat did not advance across restart'
target_state_after=$(queue_state "$target_job") || fail 'target queue query failed after restart'
[ "$target_state_after" = RUNNING ] || fail 'target GPU job did not survive slurmd restart'
wait_pending_resources after-restart || \
	fail 'probe lost its Resources wait after slurmd restart'
/usr/bin/printf 'restart_survivor=PASS target_job=%s heartbeat=%s->%s old_pid=%s new_pid=%s gpu_alloc=1\n' \
	"$target_job" "$heartbeat_before" "$heartbeat_after" "$old_pid" "$new_pid"

"$scancel" "$target_job" >"${run_dir}/target-scancel.out" 2>"${run_dir}/target-scancel.err" || fail 'cannot cancel target after restart'
wait_job_gone "$target_job" || fail 'target remained after cancel'
wait_accounting cancel "$target_job" "${run_dir}/target-sacct.txt" || fail 'target cancellation accounting mismatch'
wait_pid_absent "$target_pid" || fail "target payload remains pid=$target_pid"

wait_marker "$probe_job" "${output_dir}/probe-${probe_job}.out" 'gpu_smoke_test=PASS' || fail 'probe MLX payload did not complete'
wait_job_gone "$probe_job" || fail 'probe remained after target release'
wait_accounting complete "$probe_job" "${run_dir}/probe-sacct.txt" || fail 'probe completion accounting mismatch'
/usr/bin/grep -Eq '^slurm_job_gpus=0$' "${output_dir}/probe-${probe_job}.out" || fail 'probe lacks SLURM_JOB_GPUS=0'
/usr/bin/grep -Fq "'device_name': 'Apple M5 Max'" "${output_dir}/probe-${probe_job}.out" || fail 'probe did not use Apple M5 Max'
[ ! -s "${output_dir}/probe-${probe_job}.err" ] || fail 'probe stderr is not empty'

wait_final_idle || fail 'final node did not release all resources with configured GPU count one'
queue_final=$("$squeue" -h -w "$node_name") || fail 'final queue query failed'
[ -z "$queue_final" ] || fail 'final node queue is not empty'
[ "$(get_service_pid)" = "$new_pid" ] || fail 'final launchd PID mismatch'
[ "$(/bin/cat "$pid_file")" = "$new_pid" ] || fail 'final pidfile PID mismatch'
is_running "$new_pid" || fail 'final slurmd is not running'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-final.txt" 2>/dev/null; then
	fail 'slurmstepd remains after test'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-final.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-final.txt" >"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'SMD-206 payload process remains'

/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$plist" >"${run_dir}/production-after.sha256"
/usr/bin/cmp -s "${run_dir}/production-before.sha256" "${run_dir}/production-after.sha256" || fail 'production hashes changed'
"$slurmd" -G -f "$slurm_conf" >"${run_dir}/gres-after.stdout" 2>"${run_dir}/gres-after.stderr" || fail 'final slurmd -G failed'
/usr/bin/grep -Eq 'Gres Name=gpu Type=apple Count=1 .*File=/dev/null' "${run_dir}/gres-after.stderr" || fail 'final slurmd -G count is not one'
log_first=$((log_line_before + 1))
/usr/bin/sed -n "${log_first},\$p" "$slurmd_log" >"${run_dir}/slurmd-log-delta.txt"
/usr/bin/grep -Fq "Launching batch JobId=${target_job}" "${run_dir}/slurmd-log-delta.txt" || fail 'worker log lacks target launch'
/usr/bin/grep -Fq "Launching batch JobId=${probe_job}" "${run_dir}/slurmd-log-delta.txt" || fail 'worker log lacks probe launch'
/usr/bin/grep -Fq "[${probe_job}.batch] done with step" "${run_dir}/slurmd-log-delta.txt" || fail 'worker log lacks probe completion'

make_output_readable || fail 'cannot make output evidence readable'
restart_started=0
success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD206_GPU_JOB_RESTART_COMPLETE target_job=%s probe_job=%s old_pid=%s new_pid=%s heartbeat=%s->%s configured_gpu=1 allocated_during_restart=1 final_allocated_gpu=0 production_unchanged=PASS run_dir=%s\n' \
	"$target_job" "$probe_job" "$old_pid" "$new_pid" "$heartbeat_before" "$heartbeat_after" "$run_dir"
