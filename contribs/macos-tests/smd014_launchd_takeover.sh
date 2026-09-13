#!/bin/sh

set -u

source_root=/Users/REDACTED_USER/dev/slurm.26-05
package_root=${SMD014_PACKAGE_ROOT:-/tmp/slurm-smd014-stage.lWYKyQ}
prefix=/opt/slurm/26.11.0
stage_prefix=${package_root}${prefix}
production_conf=${prefix}/etc/slurm.conf
production_key=${prefix}/etc/slurm.key
production_gres_conf=${prefix}/etc/gres.conf
plist_source=${source_root}/etc/launchd/org.schedmd.slurmd.plist
plist_installer=${source_root}/etc/launchd/install-slurmd-launchdaemon.sh
plist_target=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_target=system/org.schedmd.slurmd
pid_file=/var/run/slurmd.pid
sack_socket=/var/run/slurm/sack.socket
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
node_name=PC-210
test_user=testuser
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd014-${run_stamp}
backup_dir=${prefix}/.smd014-backup-${run_stamp}
recovery_dir=${run_dir}/recovery-candidate
active_job=
daemon_was_stopped=0
service_started=0
production_update_started=0
production_verified=0
success=0
current_pid=
smoke_job=

runtime_paths='sbin/slurmd
sbin/slurmstepd
bin/srun
lib/libslurm.46.dylib
lib/slurm/libslurm_pmi.dylib
lib/slurm/libslurmfull.dylib'

export SLURM_CONF="$production_conf"

is_running()
{
	check_pid=$1
	[ -n "$check_pid" ] && /bin/kill -0 "$check_pid" >/dev/null 2>&1
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
	while is_running "$stopping_pid" && [ "$attempt" -lt 45 ]; do
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	! is_running "$stopping_pid"
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

wait_for_service_ready()
{
	previous_pid=$1
	previous_start=$2
	node_file=$3
	launchd_file=$4
	attempt=0
	stable=0
	while [ "$attempt" -lt 90 ]; do
		observed_pid=
		service_loaded && observed_pid=$(get_service_pid 2>/dev/null || true)
		pid_from_file=
		[ -f "$pid_file" ] && pid_from_file=$(/bin/cat "$pid_file" 2>/dev/null)
		if [ -n "$observed_pid" ] && [ "$observed_pid" != "$previous_pid" ] && \
			[ "$pid_from_file" = "$observed_pid" ] && is_running "$observed_pid" && \
			[ -S "$sack_socket" ] && \
			"$scontrol" show node "$node_name" >"$node_file" 2>"${node_file}.err"; then
			observed_start=$(extract_start_time "$node_file" 2>/dev/null || true)
			if [ -n "$observed_start" ] && [ "$observed_start" != None ] && \
				[ "$observed_start" != "$previous_start" ] && \
				/usr/bin/grep -q 'State=IDLE ' "$node_file"; then
				stable=$((stable + 1))
			else
				stable=0
			fi
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			/bin/launchctl print "$service_target" >"$launchd_file" 2>&1 || return 1
			current_pid=$observed_pid
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_for_recovery_ready()
{
	recovery_pid=$1
	attempt=0
	stable=0
	while [ "$attempt" -lt 60 ]; do
		pid_from_file=
		[ -f "$pid_file" ] && pid_from_file=$(/bin/cat "$pid_file" 2>/dev/null)
		if is_running "$recovery_pid" && [ "$pid_from_file" = "$recovery_pid" ] && \
			[ -S "$sack_socket" ] && \
			"$scontrol" show node "$node_name" >"${run_dir}/node-recovery.txt" \
			2>"${run_dir}/node-recovery.txt.err" && \
			/usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-recovery.txt"; then
			stable=$((stable + 1))
		else
			stable=0
		fi
		[ "$stable" -ge 3 ] && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

run_smoke()
{
	case_name=$1
	case_dir=${run_dir}/smoke/${case_name}
	/bin/mkdir -p -m 0755 "$case_dir" || return 1
	/usr/sbin/chown "$test_user" "$case_dir" || return 1
	submit_result=$(
		cd /tmp || exit 1
		/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
			SLURM_CONF="$production_conf" \
			"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
			--cpus-per-task=1 --mem=1G --gres=gpu:apple:1 --time=00:01:00 \
			--chdir=/tmp --job-name="smd014-${case_name}" \
			--output="${case_dir}/hostname.out" \
			--error="${case_dir}/hostname.err" --wrap=/bin/hostname
	) || return 1
	job_id=${submit_result%%;*}
	active_job=$job_id
	printf 'submitted phase=%s job_id=%s\n' "$case_name" "$job_id" >&2
	wait_job_gone "$job_id" >&2 || return 1
	"$sacct" -j "$job_id" \
		--format=JobID,JobName,User,State,ReqTRES,AllocTRES,ExitCode,NodeList \
		-P >"${case_dir}/sacct.txt" || return 1
	if ! /usr/bin/awk -F '|' -v id="$job_id" '
		$1 == id && $4 == "COMPLETED" && $7 == "0:0" { job_ok = 1 }
		$1 == id ".batch" && $4 == "COMPLETED" && $7 == "0:0" { batch_ok = 1 }
		END { exit !(job_ok && batch_ok) }
	' "${case_dir}/sacct.txt"; then
		printf 'error: phase=%s job=%s job/batch is not COMPLETED 0:0\n' \
			"$case_name" "$job_id" >&2
		return 1
	fi
	/usr/bin/grep -Eq '^PC-210(\.local)?$' "${case_dir}/hostname.out" || return 1
	smoke_job=$job_id
	active_job=
}

expected_hash()
{
	case "$1" in
	sbin/slurmd) printf '%s\n' a3df64dde33256a7dff621854ff56501e854cc51ffab2ebb6f91ec5a92d94d72 ;;
	sbin/slurmstepd) printf '%s\n' 738fe94b7cb24702de8c5c1b65c0c82a619e072d1e1a12aa4a0d143092d643b0 ;;
	bin/srun) printf '%s\n' 0d5ff8c6ea7d793fe4f33588bf6c890d8e4bc7abe742296f6cbf5e061c0103d9 ;;
	lib/libslurm.46.dylib) printf '%s\n' 17ab187a85e6c6d04e40d2744ff0a7332c8e091c7932d82d5041c9923b9c9011 ;;
	lib/slurm/libslurm_pmi.dylib) printf '%s\n' 32e1f7c92a121a7a01d4970f7836d6610c20e10b185898cd7274bb791d7f5e28 ;;
	lib/slurm/libslurmfull.dylib) printf '%s\n' cbe62a38946a3f0a17f2bcf8840638ff31120d626dbbdffdf7f89a36ab852fae ;;
	*) return 1 ;;
	esac
}

sha256_file()
{
	/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

validate_package()
{
	: >"${run_dir}/package-sha256.txt"
	printf '%s\n' "$runtime_paths" | while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		staged=${stage_prefix}/${rel}
		[ -f "$staged" ] || exit 1
		expected=$(expected_hash "$rel") || exit 1
		actual=$(sha256_file "$staged") || exit 1
		if [ "$actual" != "$expected" ]; then
			printf 'error: staged hash mismatch path=%s expected=%s actual=%s\n' \
				"$rel" "$expected" "$actual" >&2
			exit 1
		fi
		printf '%s  %s\n' "$actual" "$rel" >>"${run_dir}/package-sha256.txt"
	done
}

restore_runtime_backup()
{
	[ -d "$backup_dir" ] || return 0
	printf '%s\n' "$runtime_paths" | while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		backup=${backup_dir}/${rel}
		[ -f "$backup" ] || continue
		/usr/bin/install -o root -g wheel -m 0755 "$backup" \
			"${prefix}/${rel}" || exit 1
	done
}

start_recovery_candidate()
{
	observed_pid=
	[ -f "$pid_file" ] && observed_pid=$(/bin/cat "$pid_file" 2>/dev/null)
	if is_running "$observed_pid"; then
		printf 'recovery: slurmd already running pid=%s; no duplicate start\n' \
			"$observed_pid" >&2
		return 0
	fi
	/usr/bin/nohup /usr/bin/env DYLD_LIBRARY_PATH="$recovery_dir" \
		SLURM_SACK_KEY="$production_key" \
		"${recovery_dir}/slurmd" -Dvvv -f "$production_conf" \
		>"${run_dir}/recovery-slurmd.log" 2>&1 </dev/null &
	recovery_pid=$!
	if wait_for_recovery_ready "$recovery_pid"; then
		printf 'recovery: validated candidate started pid=%s\n' "$recovery_pid" >&2
	else
		printf 'fatal recovery: candidate pid=%s did not become ready\n' \
			"$recovery_pid" >&2
	fi
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$active_job"
	if [ "$success" -ne 1 ]; then
		if [ "$service_started" -eq 1 ] && service_loaded; then
			/bin/launchctl bootout "$service_target" >/dev/null 2>&1 || true
		fi
		if [ "$production_update_started" -eq 1 ] && \
			[ "$production_verified" -ne 1 ]; then
			if restore_runtime_backup; then
				printf 'recovery: production runtime backup restored from %s\n' \
					"$backup_dir" >&2
			else
				printf 'fatal recovery: production runtime restore failed; backup=%s\n' \
					"$backup_dir" >&2
			fi
		fi
		[ "$daemon_was_stopped" -eq 1 ] && start_recovery_candidate
		if [ "$production_update_started" -eq 1 ] || \
			[ "$daemon_was_stopped" -eq 1 ] || [ "$service_started" -eq 1 ]; then
			printf 'recovery: inspect evidence=%s backup=%s\n' \
				"$run_dir" "$backup_dir" >&2
		fi
	fi
	exit "$rc"
}

trap cleanup EXIT HUP INT TERM

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	printf 'error: run as root with sudo\n' >&2
	exit 77
fi

if [ "${SMD014_CONTROLLER_IDLE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: first confirm that PC-210 has no jobs and is IDLE,' \
		'then rerun with SMD014_CONTROLLER_IDLE_CONFIRMED=YES' >&2
	exit 75
fi

for required_file in "$production_conf" "$production_key" \
	"$production_gres_conf" "$plist_source" "$plist_installer" \
	"$scontrol" "$squeue" "$sbatch" "$scancel" "$sacct" "$pid_file"; do
	if [ ! -e "$required_file" ]; then
		printf 'error: missing %s\n' "$required_file" >&2
		exit 66
	fi
done || exit 1
for required_command in /bin/cat /bin/cp /bin/date /bin/hostname /bin/kill \
	/bin/launchctl /bin/mkdir /bin/ps /bin/sleep /bin/zsh \
	/usr/bin/awk /usr/bin/cmp /usr/bin/dirname /usr/bin/env /usr/bin/grep \
	/usr/bin/id /usr/bin/install /usr/bin/nohup /usr/bin/plutil \
	/usr/bin/shasum /usr/bin/stat /usr/bin/sudo /usr/bin/tr \
	/usr/sbin/chown; do
	if [ ! -x "$required_command" ]; then
		printf 'error: required command is not executable: %s\n' \
			"$required_command" >&2
		exit 69
	fi
done || exit 1
if [ ! -d "$stage_prefix" ]; then
	printf 'error: prepared package missing: %s\n' "$stage_prefix" >&2
	exit 66
fi
if ! /usr/bin/id "$test_user" >/dev/null 2>&1; then
	printf 'error: test user %s does not exist\n' "$test_user" >&2
	exit 67
fi

/bin/mkdir -p -m 0755 "$run_dir" "${run_dir}/smoke" "$recovery_dir" || exit 1
/usr/bin/install -m 0755 "${stage_prefix}/sbin/slurmd" \
	"${recovery_dir}/slurmd" || exit 1
/usr/bin/install -m 0755 "${stage_prefix}/lib/slurm/libslurmfull.dylib" \
	"${recovery_dir}/libslurmfull.dylib" || exit 1

printf 'run_dir=%s\n' "$run_dir"
printf 'package_root=%s\n' "$package_root"
printf 'backup_dir=%s\n' "$backup_dir"
validate_package || exit 1
/usr/bin/plutil -lint "$plist_source" >"${run_dir}/plist-lint.txt" 2>&1 || exit 1
/bin/zsh -n "$plist_installer" || exit 1

if service_loaded; then
	printf 'error: %s is already loaded; test not started\n' "$service_target" >&2
	exit 75
fi
if [ -e "$plist_target" ]; then
	printf 'error: unmanaged target plist already exists: %s\n' "$plist_target" >&2
	exit 75
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
printf 'preflight=PASS old_pid=%s old_start=%s\n' "$old_pid" "$old_start"

/bin/mkdir -p -m 0700 "$backup_dir" || exit 1
: >"${run_dir}/production-before-sha256.txt"
: >"${run_dir}/production-after-sha256.txt"
production_update_started=1
printf '%s\n' "$runtime_paths" | while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	production_file=${prefix}/${rel}
	staged_file=${stage_prefix}/${rel}
	backup_file=${backup_dir}/${rel}
	[ -f "$production_file" ] || exit 1
	/bin/mkdir -p "$(/usr/bin/dirname "$backup_file")" || exit 1
	/bin/cp -p "$production_file" "$backup_file" || exit 1
	/usr/bin/shasum -a 256 "$production_file" \
		>>"${run_dir}/production-before-sha256.txt" || exit 1
	/usr/bin/install -o root -g wheel -m 0755 "$staged_file" \
		"$production_file" || exit 1
	/usr/bin/cmp -s "$staged_file" "$production_file" || exit 1
	/usr/bin/shasum -a 256 "$production_file" \
		>>"${run_dir}/production-after-sha256.txt" || exit 1
done || exit 1

SLURM_SACK_KEY="$production_key" "${prefix}/sbin/slurmd" -C \
	-f "$production_conf" >"${run_dir}/production-parse.txt" 2>&1 || exit 1
"${prefix}/sbin/slurmd" -V >"${run_dir}/production-version.txt" || exit 1
"${prefix}/bin/srun" --version >"${run_dir}/srun-version.txt" || exit 1
"$scontrol" ping >"${run_dir}/controller-after-install.txt" || exit 1
"$scontrol" show node "$node_name" >"${run_dir}/node-after-install.txt" || exit 1
production_verified=1
printf 'production_install=PASS backup=%s\n' "$backup_dir"

printf 'stop unmanaged_slurmd pid=%s signal=TERM\n' "$old_pid"
/bin/kill -TERM "$old_pid" || exit 1
daemon_was_stopped=1
if ! wait_for_stop "$old_pid"; then
	printf 'error: unmanaged slurmd pid=%s did not stop\n' "$old_pid" >&2
	exit 1
fi
printf 'unmanaged_slurmd_stopped pid=%s\n' "$old_pid"

service_started=1
"$plist_installer" >"${run_dir}/installer.out" \
	2>"${run_dir}/installer.err" || exit 1
if ! wait_for_service_ready "$old_pid" "$old_start" \
	"${run_dir}/node-bootstrap.txt" "${run_dir}/launchd-bootstrap.txt"; then
	printf 'error: launchd bootstrap did not become ready\n' >&2
	exit 1
fi
bootstrap_pid=$current_pid
bootstrap_start=$(extract_start_time "${run_dir}/node-bootstrap.txt")
run_smoke bootstrap || exit 1
smoke_bootstrap=$smoke_job
printf 'bootstrap=PASS pid=%s job_id=%s\n' "$bootstrap_pid" "$smoke_bootstrap"

/bin/launchctl bootout "$service_target" \
	>"${run_dir}/bootout-clean.out" 2>"${run_dir}/bootout-clean.err" || exit 1
if ! wait_for_stop "$bootstrap_pid"; then
	printf 'error: launchd clean bootout pid=%s did not stop\n' "$bootstrap_pid" >&2
	exit 1
fi
/bin/launchctl enable "$service_target" || exit 1
/bin/launchctl bootstrap system "$plist_target" \
	>"${run_dir}/bootstrap-clean.out" 2>"${run_dir}/bootstrap-clean.err" || exit 1
if ! wait_for_service_ready "$bootstrap_pid" "$bootstrap_start" \
	"${run_dir}/node-clean-restart.txt" "${run_dir}/launchd-clean-restart.txt"; then
	printf 'error: launchd clean restart did not become ready\n' >&2
	exit 1
fi
clean_pid=$current_pid
clean_start=$(extract_start_time "${run_dir}/node-clean-restart.txt")
run_smoke clean-restart || exit 1
smoke_clean=$smoke_job
printf 'clean_restart=PASS old_pid=%s new_pid=%s job_id=%s\n' \
	"$bootstrap_pid" "$clean_pid" "$smoke_clean"

printf 'kill launchd_slurmd pid=%s signal=KILL\n' "$clean_pid"
/bin/kill -KILL "$clean_pid" || exit 1
if ! wait_for_service_ready "$clean_pid" "$clean_start" \
	"${run_dir}/node-keepalive.txt" "${run_dir}/launchd-keepalive.txt"; then
	printf 'error: KeepAlive restart did not become ready\n' >&2
	exit 1
fi
keepalive_pid=$current_pid
run_smoke keepalive || exit 1
smoke_keepalive=$smoke_job
printf 'keepalive_restart=PASS old_pid=%s new_pid=%s job_id=%s\n' \
	"$clean_pid" "$keepalive_pid" "$smoke_keepalive"

"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || exit 1
"$squeue" -w "$node_name" >"${run_dir}/queue-final.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-final.txt" || \
	! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-final.txt" || \
	! /usr/bin/grep -q 'AllocTRES=$' "${run_dir}/node-final.txt"; then
	printf 'error: final node resources were not released\n' >&2
	exit 1
fi
/bin/launchctl print "$service_target" >"${run_dir}/launchd-final.txt" 2>&1 || exit 1
/bin/ps -p "$keepalive_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/slurmd-final.txt" || exit 1
if ! /usr/bin/grep -q '/opt/slurm/26.11.0/sbin/slurmd -D' \
	"${run_dir}/slurmd-final.txt"; then
	printf 'error: final slurmd is not running from production prefix\n' >&2
	exit 1
fi
final_ppid=$(/bin/ps -p "$keepalive_pid" -o ppid= | /usr/bin/tr -d ' ')
if [ "$final_ppid" != 1 ]; then
	printf 'error: launchd slurmd parent is not PID 1: ppid=%s\n' "$final_ppid" >&2
	exit 1
fi
for log_file in /var/log/slurm/slurmd.log \
	/var/log/slurm/slurmd-launchd.out.log \
	/var/log/slurm/slurmd-launchd.err.log; do
	[ -f "$log_file" ] || {
		printf 'error: expected launchd log file missing: %s\n' "$log_file" >&2
		exit 1
	}
done
/usr/bin/stat -f 'final_sack path=%N mode=%Sp owner=%Su group=%Sg device=%d inode=%i' \
	"$sack_socket" >"${run_dir}/sack-final.txt" || exit 1

success=1
trap - EXIT HUP INT TERM
printf '%s\n' \
	"SMD014_TAKEOVER_COMPLETE current_pid=${keepalive_pid} bootstrap_job=${smoke_bootstrap} clean_restart_job=${smoke_clean} keepalive_job=${smoke_keepalive} backup=${backup_dir} run_dir=${run_dir}" \
	"NOTICE launchd takeover and restart checks passed; Mac boot-time start remains untested until a controlled reboot."
