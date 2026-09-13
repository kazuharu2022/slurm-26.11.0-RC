#!/bin/sh

set -u

if [ "${SMD205_REGISTRATION_MISMATCH_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD205_REGISTRATION_MISMATCH_CONFIRMED=YES after approving temporary production gres.conf replacement, two slurmd restarts, one blocked/cancelled job, and one recovery GPU smoke job' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
slurm_key=${prefix}/etc/slurm.key
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
mlx_job=${prefix}/share/macos-gpu-job/mlx_gpu_smoke.sbatch
pid_file=/var/run/slurmd.pid
sack_socket=/var/run/slurm/sack.socket
slurmd_log=/var/log/slurm/slurmd.log
launchd_stderr_log=/var/log/slurm/slurmd-launchd.err.log
plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_label=org.schedmd.slurmd
service_target=system/${service_label}
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd205-runtime-${run_stamp}
output_dir=${run_dir}/output
backup_gres=${run_dir}/gres.conf.before
candidate_gres=${run_dir}/gres.conf.zero
negative_payload=${run_dir}/must-not-run.sh
negative_marker=${output_dir}/MISMATCH_PAYLOAD_EXECUTED
negative_job=
smoke_job=
old_pid=
mismatch_pid=
restored_pid=
gres_modified=0
restart_required=0
phase_started=0
success=0
log_line_before=0
launchd_stderr_line_before=0

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

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }'
}

cancel_if_active()
{
	active_job=$1
	[ -n "$active_job" ] || return 0
	state=$(queue_state "$active_job")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$active_job" "$state" >&2
		"$scancel" "$active_job" >/dev/null 2>&1 || true
	fi
}

wait_job_gone()
{
	active_job=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ -z "$(queue_state "$active_job")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' \
				"$active_job" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_accounting_cancelled()
{
	active_job=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		"$sacct" -j "$active_job" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES,AllocTRES \
			>"$file" 2>"${file%.txt}.err" || true
		if /usr/bin/awk -F '|' -v job="$active_job" -v user="$test_user" '
			$1 == job && $2 == user && $3 ~ /^CANCELLED/ { ok = 1 }
			END { exit !ok }
		' "$file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_accounting_gpu_complete()
{
	active_job=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		"$sacct" -j "$active_job" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES%200,AllocTRES%200 \
			>"$file" 2>"${file%.txt}.err" || true
		if /usr/bin/awk -F '|' -v job="$active_job" -v user="$test_user" '
		function has(value, expected, n, items, i) {
			n = split(value, items, ",")
			for (i = 1; i <= n; i++)
				if (items[i] == expected)
					return 1
			return 0
		}
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" {
			job_ok = has($6, "gres/gpu=1") &&
				has($6, "gres/gpu:apple=1") &&
				has($7, "gres/gpu=1") &&
				has($7, "gres/gpu:apple=1")
		}
		$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" {
			batch_ok = 1
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
	phase=$2
	if service_loaded; then
		/bin/launchctl bootout "$service_target" \
			>"${run_dir}/bootout-${phase}.out" \
			2>"${run_dir}/bootout-${phase}.err" || return 1
		wait_service_unloaded "$previous_pid" || return 1
	fi
	bootstrap_service >"${run_dir}/bootstrap-${phase}.out" \
		2>"${run_dir}/bootstrap-${phase}.err" || return 1
	return 0
}

wait_invalid_registration()
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
			"$scontrol" show node "$node_name" >"${run_dir}/node-mismatch.txt" \
			2>"${run_dir}/node-mismatch.err"; then
			state=$(field_from_file State "${run_dir}/node-mismatch.txt")
			case "$state" in
			*DRAIN*) drain_ok=1 ;;
			*) drain_ok=0 ;;
			esac
			case "$state" in
			*INVALID_REG*|*INVAL*) invalid_ok=1 ;;
			*) invalid_ok=0 ;;
			esac
			if [ "$drain_ok" -eq 1 ] && [ "$invalid_ok" -eq 1 ] && \
				/usr/bin/grep -Fq \
				'gres/gpu count reported lower than configured (0 < 1)' \
				"${run_dir}/node-mismatch.txt"; then
				mismatch_pid=$observed_pid
				stable=$((stable + 1))
			else
				stable=0
			fi
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			/bin/launchctl print "$service_target" \
				>"${run_dir}/launchd-mismatch.txt" 2>&1 || return 1
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_restored_registration()
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
			"$scontrol" show node "$node_name" >"${run_dir}/node-restored-registration.txt" \
			2>"${run_dir}/node-restored-registration.err"; then
			state=$(field_from_file State "${run_dir}/node-restored-registration.txt")
			case "$state" in
			*NOT_RESPONDING*|*INVALID_REG*|*INVAL*|'') stable=0 ;;
			*)
				if /usr/bin/grep -Fq 'Gres=gpu:apple:1' \
					"${run_dir}/node-restored-registration.txt"; then
					restored_pid=$observed_pid
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
			/bin/launchctl print "$service_target" \
				>"${run_dir}/launchd-restored.txt" 2>&1 || return 1
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_idle()
{
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$scontrol" show node "$node_name" >"${run_dir}/node-idle.txt" \
			2>"${run_dir}/node-idle.err" || true
		state=$(field_from_file State "${run_dir}/node-idle.txt")
		cpu=$(field_from_file CPUAlloc "${run_dir}/node-idle.txt")
		mem=$(field_from_file AllocMem "${run_dir}/node-idle.txt")
		if [ "$state" = IDLE ] && [ "$cpu" = 0 ] && [ "$mem" = 0 ] && \
			/usr/bin/grep -Fq 'Gres=gpu:apple:1' "${run_dir}/node-idle.txt"; then
			/usr/bin/printf 'node_recovered state=%s CPUAlloc=%s AllocMem=%s wait_seconds=%s\n' \
				"$state" "$cpu" "$mem" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_pending_not_launched()
{
	attempt=0
	stable=0
	while [ "$attempt" -lt 60 ]; do
		state=$(queue_state "$negative_job")
		reason=$("$squeue" -h -j "$negative_job" -o '%R' 2>/dev/null |
			/usr/bin/awk 'NR == 1 { print; exit }')
		case "$state" in
		RUNNING|COMPLETING|'') return 1 ;;
		PENDING)
			case "$reason" in
			''|None|Priority) stable=0 ;;
			*) stable=$((stable + 1)) ;;
			esac
			;;
		*) stable=0 ;;
		esac
		[ ! -e "$negative_marker" ] || return 1
		if [ "$stable" -ge 5 ]; then
			/usr/bin/printf 'negative_job_blocked job_id=%s state=%s reason=%s wait_seconds=%s\n' \
				"$negative_job" "$state" "$reason" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

restore_gres_file()
{
	[ -f "$backup_gres" ] || return 1
	/bin/cp -p "$backup_gres" "$gres_conf" || return 1
	/usr/bin/cmp -s "$backup_gres" "$gres_conf" || return 1
	current_meta=$(/usr/bin/stat -f '%u:%g:%Lp' "$gres_conf") || return 1
	[ "$current_meta" = "$original_meta" ] || return 1
	gres_modified=0
	restart_required=1
	return 0
}

resume_if_needed()
{
	"$scontrol" show node "$node_name" >"${run_dir}/node-before-resume.txt" \
		2>"${run_dir}/node-before-resume.err" || return 1
	state=$(field_from_file State "${run_dir}/node-before-resume.txt")
	case "$state" in
	*INVALID_REG*|*INVAL*|*NOT_RESPONDING*) return 1 ;;
	*DRAIN*|DOWN*)
		"$scontrol" update NodeName="$node_name" State=RESUME \
			>"${run_dir}/resume.out" 2>"${run_dir}/resume.err" || return 1
		;;
	esac
	wait_idle
}

recover_production()
{
	recovery_previous=
	if [ -f "$backup_gres" ]; then
		/bin/cp -p "$backup_gres" "$gres_conf" || return 1
		/usr/bin/cmp -s "$backup_gres" "$gres_conf" || return 1
	fi
	service_loaded && recovery_previous=$(get_service_pid 2>/dev/null || true)
	if service_loaded; then
		/bin/launchctl bootout "$service_target" >/dev/null 2>&1 || return 1
		wait_service_unloaded "$recovery_previous" || return 1
	fi
	bootstrap_service >/dev/null 2>&1 || return 1
	wait_restored_registration "$recovery_previous" || return 1
	resume_if_needed || return 1
	gres_modified=0
	restart_required=0
	return 0
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
	cancel_if_active "$negative_job"
	cancel_if_active "$smoke_job"
	if [ "$gres_modified" -eq 1 ] || [ "$restart_required" -eq 1 ]; then
		if recover_production; then
			/usr/bin/printf 'recovery: production gres.conf and launchd service restored\n' >&2
		else
			/usr/bin/printf 'fatal recovery: automatic production restore failed; backup=%s\n' \
				"$backup_gres" >&2
			rc=1
		fi
	fi
	make_output_readable || rc=1
	if [ "$success" -ne 1 ]; then
		if [ "$phase_started" -eq 1 ]; then
			/usr/bin/printf 'recovery: inspect run_dir=%s and controller node state before continuing\n' \
				"$run_dir" >&2
		else
			/usr/bin/printf 'recovery: stopped before production mutation; inspect run_dir=%s\n' \
				"$run_dir" >&2
		fi
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$gres_conf" "$slurm_key" "$slurmd" \
	"$scontrol" "$squeue" "$sbatch" "$scancel" "$sacct" "$mlx_job" \
	"$pid_file" "$slurmd_log" "$plist"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for command in /usr/bin/awk /usr/bin/cmp /usr/bin/env /usr/bin/grep \
	/usr/bin/id /usr/bin/pgrep /usr/bin/sed /usr/bin/shasum /usr/bin/stat \
	/usr/bin/sudo /usr/bin/tail /usr/bin/tr /usr/bin/uname /usr/bin/wc \
	/usr/sbin/chown /bin/cat /bin/chmod /bin/cp /bin/date /bin/kill \
	/bin/launchctl /bin/mkdir /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
{
	/usr/bin/printf '#!/bin/sh\n'
	/usr/bin/printf '/usr/bin/touch %s\n' "$negative_marker"
	/usr/bin/printf '/bin/hostname\n'
} >"$negative_payload" || fail 'cannot create negative payload'
/bin/chmod 0555 "$negative_payload" || fail 'cannot set negative payload mode'
/usr/sbin/chown 0:0 "$negative_payload" || fail 'cannot set negative payload owner'
/usr/bin/printf '%s\n' '# SMD-205: intentionally no GPU device record' \
	>"$candidate_gres" || fail 'cannot create zero-GRES candidate'
/bin/chmod 0644 "$candidate_gres" || fail 'cannot set candidate mode'
/usr/sbin/chown 0:0 "$candidate_gres" || fail 'cannot set candidate owner'
/usr/bin/printf 'run_dir=%s mutation=worker_gres_only expected=INVALID_REG+DRAIN\n' "$run_dir"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show config >"${run_dir}/controller-config.txt" || \
	fail 'controller config readback failed'
if /usr/bin/grep -Eiq '^SlurmdParameters[[:space:]]*=.*config_overrides' \
	"${run_dir}/controller-config.txt"; then
	fail 'controller config_overrides would bypass the intended hardware validation boundary'
fi
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
[ "$(field_from_file State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(field_from_file CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'CPUAlloc is not zero'
[ "$(field_from_file AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
/usr/bin/grep -Fq 'Gres=gpu:apple:1' "${run_dir}/node-before.txt" || \
	fail 'controller node record lacks gpu:apple:1'
/usr/bin/grep -Fq 'gres/gpu=1,gres/gpu:apple=1' "${run_dir}/node-before.txt" || \
	fail 'controller CfgTRES lacks generic or typed GPU'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

service_loaded || fail "launchd service is not loaded: $service_target"
/bin/launchctl print "$service_target" >"${run_dir}/launchd-before.txt" 2>&1 || \
	fail 'cannot inspect launchd service'
old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$old_pid" ;;
esac
[ "$(get_service_pid)" = "$old_pid" ] || fail 'launchd and pidfile PID mismatch'
is_running "$old_pid" || fail "slurmd pid=$old_pid is not running"

/bin/cp -p "$gres_conf" "$backup_gres" || fail 'cannot back up production gres.conf'
original_meta=$(/usr/bin/stat -f '%u:%g:%Lp' "$gres_conf") || fail 'cannot read gres.conf metadata'
/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$plist" \
	>"${run_dir}/production-before.sha256"
"$slurmd" -G -f "$slurm_conf" >"${run_dir}/production-gres-before.stdout" \
	2>"${run_dir}/production-gres-before.stderr" || fail 'production slurmd -G failed'
/usr/bin/grep -Eq 'Gres Name=gpu Type=apple Count=1 .*File=/dev/null' \
	"${run_dir}/production-gres-before.stderr" || fail 'production GRES is not gpu:apple:1'
log_line_before=$(/usr/bin/wc -l <"$slurmd_log" | /usr/bin/tr -d ' ')
if [ -f "$launchd_stderr_log" ]; then
	launchd_stderr_line_before=$(/usr/bin/wc -l <"$launchd_stderr_log" | /usr/bin/tr -d ' ')
fi

gres_modified=1
restart_required=1
/bin/cp "$candidate_gres" "$gres_conf" || fail 'cannot apply zero-GRES candidate'
phase_started=1
/usr/bin/printf 'candidate_applied backup=%s original_meta=%s\n' "$backup_gres" "$original_meta"
restart_service "$old_pid" mismatch || fail 'cannot restart slurmd with zero-GRES candidate'
wait_invalid_registration "$old_pid" || \
	fail 'controller did not expose stable INVALID_REG+DRAIN with lower-count reason'
/usr/bin/printf 'mismatch_registration=PASS old_pid=%s mismatch_pid=%s state=%s reason=lower_count_0_lt_1\n' \
	"$old_pid" "$mismatch_pid" "$(field_from_file State "${run_dir}/node-mismatch.txt")"

negative_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=128M --gres=gpu:apple:1 --time=00:01:00 \
		--chdir=/tmp --job-name=smd205-must-not-run \
		--output="${output_dir}/negative-%j.out" \
		--error="${output_dir}/negative-%j.err" "$negative_payload"
) || fail 'negative GPU job submission failed'
negative_job=${negative_job%%;*}
case "$negative_job" in
''|*[!0-9]*) fail "invalid negative job id=$negative_job" ;;
esac
/usr/bin/printf 'submitted negative_job=%s\n' "$negative_job"
wait_pending_not_launched || fail 'negative job did not remain safely pending'
"$scontrol" -o show job "$negative_job" >"${run_dir}/negative-job-pending.txt" || \
	fail 'cannot capture pending negative job'
[ ! -e "$negative_marker" ] || fail 'negative payload unexpectedly executed'
"$scancel" "$negative_job" >"${run_dir}/negative-scancel.out" \
	2>"${run_dir}/negative-scancel.err" || fail 'cannot cancel negative job'
wait_job_gone "$negative_job" || fail 'negative job remained in queue after cancel'
wait_accounting_cancelled "$negative_job" "${run_dir}/negative-sacct.txt" || \
	fail 'negative job cancellation accounting missing'
[ ! -e "$negative_marker" ] || fail 'negative payload executed during cancellation'
/usr/bin/printf 'negative_payload=NOT_EXECUTED job_id=%s\n' "$negative_job"

restore_gres_file || fail 'cannot restore production gres.conf bytes or metadata'
/usr/bin/printf 'production_gres_file_restored=PASS\n'
restart_service "$mismatch_pid" restored || fail 'cannot restart slurmd with restored GRES'
wait_restored_registration "$mismatch_pid" || fail 'restored slurmd did not register without INVALID_REG'
resume_if_needed || fail 'node did not recover to IDLE after restored registration'
restart_required=0
/usr/bin/printf 'production_registration_restored mismatch_pid=%s restored_pid=%s\n' \
	"$mismatch_pid" "$restored_pid"

"$slurmd" -G -f "$slurm_conf" >"${run_dir}/production-gres-after.stdout" \
	2>"${run_dir}/production-gres-after.stderr" || fail 'restored production slurmd -G failed'
/usr/bin/grep -Eq 'Gres Name=gpu Type=apple Count=1 .*File=/dev/null' \
	"${run_dir}/production-gres-after.stderr" || fail 'restored GRES is not gpu:apple:1'
/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$plist" \
	>"${run_dir}/production-after.sha256"
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production hashes were not restored exactly'

smoke_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=2 --mem=4G --gres=gpu:apple:1 --time=00:02:00 \
		--chdir=/tmp --job-name=smd205-recovery-smoke \
		--output="${output_dir}/smoke-%j.out" \
		--error="${output_dir}/smoke-%j.err" "$mlx_job"
) || fail 'post-recovery GPU smoke submission failed'
smoke_job=${smoke_job%%;*}
case "$smoke_job" in
''|*[!0-9]*) fail "invalid smoke job id=$smoke_job" ;;
esac
/usr/bin/printf 'submitted smoke_job=%s\n' "$smoke_job"
wait_job_gone "$smoke_job" || fail 'post-recovery GPU smoke remained in queue'
wait_accounting_gpu_complete "$smoke_job" "${run_dir}/smoke-sacct.txt" || \
	fail 'post-recovery GPU accounting did not complete with generic/typed GRES'
/usr/bin/grep -Fq 'slurm_job_gpus=0' "${output_dir}/smoke-${smoke_job}.out" || \
	fail 'post-recovery smoke lacks SLURM_JOB_GPUS=0'
/usr/bin/grep -Fq "'device_name': 'Apple M5 Max'" "${output_dir}/smoke-${smoke_job}.out" || \
	fail 'post-recovery smoke did not use Apple M5 Max'
/usr/bin/grep -Fq 'gpu_smoke_test=PASS' "${output_dir}/smoke-${smoke_job}.out" || \
	fail 'post-recovery MLX smoke failed'
[ ! -s "${output_dir}/smoke-${smoke_job}.err" ] || fail 'post-recovery smoke stderr is not empty'

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || fail 'final node readback failed'
[ "$(field_from_file State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node is not IDLE'
[ "$(field_from_file CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(field_from_file AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs after test'
[ "$(get_service_pid)" = "$restored_pid" ] || fail 'final launchd PID mismatch'
[ "$(/bin/cat "$pid_file")" = "$restored_pid" ] || fail 'final pidfile PID mismatch'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-after.txt" 2>/dev/null; then
	fail 'slurmstepd remains after test'
fi

log_first=$((log_line_before + 1))
/usr/bin/sed -n "${log_first},\$p" "$slurmd_log" >"${run_dir}/slurmd-log-delta.txt"
launchd_stderr_first=$((launchd_stderr_line_before + 1))
if [ -f "$launchd_stderr_log" ]; then
	/usr/bin/sed -n "${launchd_stderr_first},\$p" "$launchd_stderr_log" \
		>"${run_dir}/launchd-stderr-delta.txt"
else
	: >"${run_dir}/launchd-stderr-delta.txt"
fi
if ! /usr/bin/grep -Fq 'Ignoring file-less GPU gpu:apple from final GRES list' \
	"${run_dir}/slurmd-log-delta.txt" && \
	! /usr/bin/grep -Fq 'Ignoring file-less GPU gpu:apple from final GRES list' \
	"${run_dir}/launchd-stderr-delta.txt"; then
	fail 'worker logs lack zero-GRES warning'
fi
/usr/bin/grep -Eq "Launching batch JobId=${smoke_job} .* UID 3001" \
	"${run_dir}/slurmd-log-delta.txt" || fail 'worker log lacks recovery smoke launch'

make_output_readable || fail 'cannot make output evidence readable'
success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD205_REGISTRATION_MISMATCH_COMPLETE negative_job=%s smoke_job=%s old_pid=%s mismatch_pid=%s restored_pid=%s production_restored=PASS run_dir=%s\n' \
	"$negative_job" "$smoke_job" "$old_pid" "$mismatch_pid" "$restored_pid" "$run_dir"
