#!/bin/sh

set -u

mode=${1:-}
source_root=/Users/REDACTED_USER/dev/slurm.26-05
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
plist_source=${source_root}/etc/launchd/org.schedmd.slurmd.plist
plist_target=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_target=system/org.schedmd.slurmd
service_label=org.schedmd.slurmd
pid_file=/var/run/slurmd.pid
sack_socket=/var/run/slurm/sack.socket
marker=${prefix}/.smd014-reboot-validation.env
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
node_name=PC-210
test_user=testuser
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd014-reboot-${mode:-invalid}-${run_stamp}
active_job=
success=0

runtime_paths='sbin/slurmd
sbin/slurmstepd
bin/srun
lib/libslurm.46.dylib
lib/slurm/libslurm_pmi.dylib
lib/slurm/libslurmfull.dylib'

export SLURM_CONF="$slurm_conf"

usage()
{
	printf '%s\n' \
		"usage: $0 prepare" \
		"       $0 verify" >&2
	exit 64
}

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

get_service_runs()
{
	/bin/launchctl print "$service_target" 2>/dev/null | /usr/bin/awk '
		$1 == "runs" && $2 == "=" { print $3; exit }
	'
}

get_boot_epoch()
{
	/usr/sbin/sysctl -n kern.boottime | /usr/bin/awk -F '[=,]' '
	{
		value = $2
		gsub(/[^0-9]/, "", value)
		print value
		exit
	}'
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

sha256_file()
{
	/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
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

validate_runtime_hashes()
{
	output_file=$1
	: >"$output_file"
	printf '%s\n' "$runtime_paths" | while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		actual=$(sha256_file "${prefix}/${rel}") || exit 1
		expected=$(expected_hash "$rel") || exit 1
		if [ "$actual" != "$expected" ]; then
			printf 'error: production hash mismatch path=%s expected=%s actual=%s\n' \
				"$rel" "$expected" "$actual" >&2
			exit 1
		fi
		printf '%s  %s\n' "$actual" "$rel" >>"$output_file"
	done
}

read_marker()
{
	marker_key=$1
	/usr/bin/awk -F '=' -v key="$marker_key" '
		$1 == key {
			sub(/^[^=]*=/, "")
			print
			exit
		}
	' "$marker"
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

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$active_job"
	if [ "$success" -ne 1 ]; then
		printf 'recovery: no daemon or launchd configuration was changed; inspect run_dir=%s marker=%s\n' \
			"$run_dir" "$marker" >&2
	fi
	exit "$rc"
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

wait_accounting_complete()
{
	job_id=$1
	output_file=$2
	attempt=0
	while [ "$attempt" -lt 20 ]; do
		"$sacct" -j "$job_id" \
			--format=JobID,JobName,User,State,ReqTRES,AllocTRES,ExitCode,NodeList \
			-P >"$output_file" || return 1
		if /usr/bin/awk -F '|' -v id="$job_id" '
			$1 == id && $4 == "COMPLETED" && $7 == "0:0" { job_ok = 1 }
			$1 == id ".batch" && $4 == "COMPLETED" && $7 == "0:0" { batch_ok = 1 }
			END { exit !(job_ok && batch_ok) }
		' "$output_file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

require_common_state()
{
	service_loaded || {
		printf 'error: launchd service is not loaded: %s\n' "$service_target" >&2
		return 1
	}
	/bin/launchctl print "$service_target" >"${run_dir}/launchd.txt" 2>&1 || return 1
	/usr/bin/grep -q 'state = running' "${run_dir}/launchd.txt" || return 1
	/bin/launchctl print-disabled system >"${run_dir}/launchd-disabled.txt" 2>&1 || return 1
	/usr/bin/grep -Fq "\"${service_label}\" => enabled" \
		"${run_dir}/launchd-disabled.txt" || {
		printf 'error: launchd service is not enabled\n' >&2
		return 1
	}
	[ -f "$pid_file" ] && [ -S "$sack_socket" ] || return 1
	service_pid=$(get_service_pid)
	pid_from_file=$(/bin/cat "$pid_file")
	case "$service_pid:$pid_from_file" in
	''|*[!0-9:]*) return 1 ;;
	esac
	[ "$service_pid" = "$pid_from_file" ] && is_running "$service_pid" || return 1
	/bin/ps -p "$service_pid" -o user=,pid=,ppid=,lstart=,command= \
		>"${run_dir}/slurmd.txt" || return 1
	/usr/bin/awk -v expected="${prefix}/sbin/slurmd" '
		$1 == "root" && $3 == 1 && index($0, expected) { ok = 1 }
		END { exit !ok }
	' "${run_dir}/slurmd.txt" || {
		printf 'error: slurmd is not root/PPID-1/production-prefix\n' >&2
		return 1
	}
	return 0
}

prepare_reboot()
{
	if [ "${SMD014_REBOOT_CONFIRMED:-}" != YES ]; then
		printf '%s\n' \
			'error: confirm a controlled reboot window and rerun prepare with' \
			'SMD014_REBOOT_CONFIRMED=YES' >&2
		exit 75
	fi
	if [ -e "$marker" ]; then
		printf 'error: existing reboot marker must be inspected first: %s\n' \
			"$marker" >&2
		exit 75
	fi
	require_common_state || exit 1
	active_jobs=$("$squeue" -h -w "$node_name" -o '%i %T %u %j') || exit 1
	if [ -n "$active_jobs" ]; then
		printf 'error: node has active jobs; reboot preparation stopped\n%s\n' \
			"$active_jobs" >&2
		exit 75
	fi
	"$scontrol" ping >"${run_dir}/controller-before.txt" || exit 1
	"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || exit 1
	/usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-before.txt" || {
		printf 'error: node is not IDLE before reboot\n' >&2
		exit 75
	}
	old_start=$(extract_start_time "${run_dir}/node-before.txt")
	[ -n "$old_start" ] && [ "$old_start" != None ] || exit 1
	old_pid=$(get_service_pid)
	old_runs=$(get_service_runs)
	old_boot=$(get_boot_epoch)
	[ -n "$old_boot" ] && [ -n "$old_pid" ] && [ -n "$old_runs" ] || {
		printf 'error: incomplete pre-reboot numeric state\n' >&2
		exit 1
	}
	case "$old_boot:$old_pid:$old_runs" in
	*[!0-9:]*) printf 'error: invalid pre-reboot numeric state\n' >&2; exit 1 ;;
	esac
	/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$plist_target" \
		>"${run_dir}/run-at-load.txt" || exit 1
	/usr/libexec/PlistBuddy -c 'Print :KeepAlive:SuccessfulExit' "$plist_target" \
		>"${run_dir}/keepalive-successful-exit.txt" || exit 1
	/usr/bin/grep -qx true "${run_dir}/run-at-load.txt" || exit 1
	/usr/bin/grep -qx false "${run_dir}/keepalive-successful-exit.txt" || exit 1
	installed_plist_hash=$(sha256_file "$plist_target") || exit 1
	source_plist_hash=$(sha256_file "$plist_source") || exit 1
	[ "$installed_plist_hash" = "$source_plist_hash" ] || {
		printf 'error: installed plist differs from source\n' >&2
		exit 1
	}
	validate_runtime_hashes "${run_dir}/production-sha256.txt" || exit 1
	launchd_log_lines=$(/usr/bin/wc -l </var/log/slurm/slurmd-launchd.err.log | \
		/usr/bin/tr -d ' ')
	slurmd_log_lines=$(/usr/bin/wc -l </var/log/slurm/slurmd.log | \
		/usr/bin/tr -d ' ')
	marker_tmp=${marker}.tmp.$$
	/bin/rm -f "$marker_tmp"
	(
		umask 077
		printf '%s\n' \
			'marker_version=1' \
			"prepared_epoch=$(/bin/date '+%s')" \
			"boot_epoch=${old_boot}" \
			"slurmd_pid=${old_pid}" \
			"slurmd_start=${old_start}" \
			"service_runs=${old_runs}" \
			"plist_sha256=${installed_plist_hash}" \
			"launchd_log_lines=${launchd_log_lines}" \
			"slurmd_log_lines=${slurmd_log_lines}" \
			"prepare_run_dir=${run_dir}" >"$marker_tmp"
	) || exit 1
	/usr/sbin/chown root:wheel "$marker_tmp" || exit 1
	/bin/chmod 0600 "$marker_tmp" || exit 1
	/bin/mv "$marker_tmp" "$marker" || exit 1
	/usr/bin/stat -f 'marker=%N mode=%Sp owner=%Su group=%Sg' "$marker"
	success=1
	printf '%s\n' \
		"SMD014_REBOOT_PREPARED old_boot_epoch=${old_boot} old_pid=${old_pid} old_start=${old_start} run_dir=${run_dir}" \
		'NEXT_USER_ACTION: sudo /sbin/shutdown -r now' \
		"AFTER_LOGIN: sudo /bin/sh ${source_root}/contribs/macos-tests/smd014_reboot_validation.sh verify"
}

capture_new_log_lines()
{
	log_file=$1
	old_lines=$2
	output_file=$3
	current_lines=$(/usr/bin/wc -l <"$log_file" | /usr/bin/tr -d ' ')
	if [ "$current_lines" -ge "$old_lines" ]; then
		first_line=$((old_lines + 1))
		/usr/bin/sed -n "${first_line},\$p" "$log_file" >"$output_file"
	else
		/bin/cp "$log_file" "$output_file"
	fi
}

verify_reboot()
{
	[ -f "$marker" ] || {
		printf 'error: reboot marker is missing: %s\n' "$marker" >&2
		exit 66
	}
	marker_version=$(read_marker marker_version)
	old_boot=$(read_marker boot_epoch)
	old_pid=$(read_marker slurmd_pid)
	old_start=$(read_marker slurmd_start)
	expected_plist_hash=$(read_marker plist_sha256)
	old_launchd_log_lines=$(read_marker launchd_log_lines)
	old_slurmd_log_lines=$(read_marker slurmd_log_lines)
	[ "$marker_version" = 1 ] || exit 1
	[ -n "$old_boot" ] && [ -n "$old_pid" ] && \
		[ -n "$old_launchd_log_lines" ] && [ -n "$old_slurmd_log_lines" ] || {
		printf 'error: incomplete reboot marker\n' >&2
		exit 1
	}
	case "$old_boot:$old_pid:$old_launchd_log_lines:$old_slurmd_log_lines" in
	*[!0-9:]*) printf 'error: invalid reboot marker\n' >&2; exit 1 ;;
	esac
	new_boot=$(get_boot_epoch)
	case "$new_boot" in
	''|*[!0-9]*) printf 'error: invalid current boot epoch\n' >&2; exit 1 ;;
	esac
	if [ "$new_boot" -le "$old_boot" ]; then
		printf 'error: reboot not detected old_boot_epoch=%s current_boot_epoch=%s\n' \
			"$old_boot" "$new_boot" >&2
		exit 75
	fi
	printf 'reboot_detected old_boot_epoch=%s new_boot_epoch=%s\n' \
		"$old_boot" "$new_boot"
	attempt=0
	stable=0
	controller_policy_block=0
	controller_connectivity_block=0
	unexpected_reboot_observations=0
	not_responding_observations=0
	while [ "$attempt" -lt 180 ]; do
		if require_common_state >/dev/null 2>&1 && \
			"$scontrol" ping >"${run_dir}/controller-after.txt" 2>/dev/null && \
			"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" \
				2>"${run_dir}/node-after.err"; then
			new_pid=$(get_service_pid)
			new_start=$(extract_start_time "${run_dir}/node-after.txt")
			if [ "$new_pid" != "$old_pid" ] && [ -n "$new_start" ] && \
				[ "$new_start" != None ] && [ "$new_start" != "$old_start" ] && \
				/usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-after.txt"; then
				stable=$((stable + 1))
			else
				stable=0
			fi
			if /usr/bin/grep -q 'State=.*DOWN' "${run_dir}/node-after.txt" && \
				/usr/bin/grep -q 'Reason=Node unexpectedly rebooted' \
					"${run_dir}/node-after.txt"; then
				unexpected_reboot_observations=$((unexpected_reboot_observations + 1))
			else
				unexpected_reboot_observations=0
			fi
			if /usr/bin/grep -q 'State=.*NOT_RESPONDING' \
				"${run_dir}/node-after.txt"; then
				not_responding_observations=$((not_responding_observations + 1))
			else
				not_responding_observations=0
			fi
		else
			stable=0
			unexpected_reboot_observations=0
			not_responding_observations=0
		fi
		[ "$stable" -ge 3 ] && break
		if [ "$unexpected_reboot_observations" -ge 3 ]; then
			controller_policy_block=1
			break
		fi
		if [ "$not_responding_observations" -ge 5 ]; then
			controller_connectivity_block=1
			break
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	if [ "$controller_policy_block" -eq 1 ]; then
		"$scontrol" show config | /usr/bin/grep -E \
			'ReturnToService|SlurmdTimeout|ResumeTimeout' \
			>"${run_dir}/controller-policy.txt" || exit 1
		return_to_service=$(/usr/bin/awk \
			'$1 == "ReturnToService" { print $3; exit }' \
			"${run_dir}/controller-policy.txt")
		printf '%s\n' \
			"blocked: launchd RunAtLoad succeeded, but controller kept ${node_name} DOWN after an unexpected reboot (ReturnToService=${return_to_service})" \
			"REQUIRED_EXTERNAL_ACTION_ON_CONTROLLER: /usr/local/slurm/26.11.0/bin/scontrol update NodeName=${node_name} State=RESUME" \
			"AFTER_RESUME_ON_MAC: sudo /bin/sh ${source_root}/contribs/macos-tests/smd014_reboot_validation.sh verify" >&2
		exit 75
	fi
	if [ "$controller_connectivity_block" -eq 1 ]; then
		local_ip=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || true)
		reported_node_addr=$(/usr/bin/awk '
		{
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^NodeAddr=/) {
					sub(/^NodeAddr=/, "", $i)
					print $i
					exit
				}
			}
		}' "${run_dir}/node-after.txt")
		printf '%s\n' \
			"blocked: launchd/slurmd are running locally, but controller reports ${node_name} NOT_RESPONDING" \
			"local_en0_address=${local_ip} controller_NodeAddr=${reported_node_addr}" \
			"REQUIRED_READ_ONLY_CHECK_ON_CONTROLLER:" \
			"  getent ahostsv4 ${reported_node_addr}" \
			"  getent hosts ${reported_node_addr}" \
			"  ping -c 2 ${local_ip}" \
			"  nc -vz -w 3 ${reported_node_addr} 6818" \
			"  nc -vz -w 3 ${local_ip} 6818" >&2
		exit 75
	fi
	if [ "$stable" -lt 3 ]; then
		printf 'error: launchd/slurmd/controller did not become stable after reboot\n' >&2
		exit 1
	fi
	printf 'runatload_ready old_pid=%s new_pid=%s old_start=%s new_start=%s wait_seconds=%s\n' \
		"$old_pid" "$new_pid" "$old_start" "$new_start" "$attempt"
	new_plist_hash=$(sha256_file "$plist_target") || exit 1
	[ "$new_plist_hash" = "$expected_plist_hash" ] || {
		printf 'error: installed plist changed across reboot\n' >&2
		exit 1
	}
	validate_runtime_hashes "${run_dir}/production-sha256.txt" || exit 1
	/bin/launchctl print "$service_target" >"${run_dir}/launchd-final.txt" 2>&1 || exit 1
	/usr/bin/stat -f 'sack=%N mode=%Sp owner=%Su group=%Sg device=%d inode=%i' \
		"$sack_socket" >"${run_dir}/sack-final.txt" || exit 1
	/usr/bin/sw_vers >"${run_dir}/sw-vers.txt" || exit 1
	/usr/bin/uname -a >"${run_dir}/uname.txt" || exit 1
	capture_new_log_lines /var/log/slurm/slurmd-launchd.err.log \
		"$old_launchd_log_lines" "${run_dir}/launchd-new.log" || exit 1
	capture_new_log_lines /var/log/slurm/slurmd.log \
		"$old_slurmd_log_lines" "${run_dir}/slurmd-new.log" || exit 1
	if ! /usr/bin/grep -q 'slurmd started on' "${run_dir}/launchd-new.log" && \
		! /usr/bin/grep -q 'slurmd started on' "${run_dir}/slurmd-new.log"; then
		printf 'error: no post-reboot slurmd startup record found\n' >&2
		exit 1
	fi
	smoke_dir=${run_dir}/smoke
	/bin/mkdir -m 0755 "$smoke_dir" || exit 1
	/usr/sbin/chown "$test_user" "$smoke_dir" || exit 1
	submit_result=$(
		cd /tmp || exit 1
		/usr/bin/sudo -H -u "$test_user" /usr/bin/env \
			SLURM_CONF="$slurm_conf" \
			"$sbatch" --parsable --partition=debug --nodes=1 --ntasks=1 \
			--cpus-per-task=1 --mem=1G --gres=gpu:apple:1 --time=00:01:00 \
			--chdir=/tmp --job-name=smd014-reboot \
			--output="${smoke_dir}/hostname.out" \
			--error="${smoke_dir}/hostname.err" --wrap=/bin/hostname
	) || exit 1
	smoke_job=${submit_result%%;*}
	active_job=$smoke_job
	printf 'submitted smoke_job=%s\n' "$smoke_job"
	wait_job_gone "$smoke_job" || exit 1
	wait_accounting_complete "$smoke_job" "${smoke_dir}/sacct.txt" || {
		printf 'error: smoke accounting is not COMPLETED 0:0\n' >&2
		exit 1
	}
	/usr/bin/grep -Eq '^PC-210(\.local)?$' "${smoke_dir}/hostname.out" || exit 1
	active_job=
	"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || exit 1
	"$squeue" -w "$node_name" >"${run_dir}/queue-final.txt" || exit 1
	if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-final.txt" || \
		! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-final.txt" || \
		! /usr/bin/grep -q 'AllocTRES=$' "${run_dir}/node-final.txt" || \
		[ -n "$("$squeue" -h -w "$node_name")" ]; then
		printf 'error: final node resources were not released\n' >&2
		exit 1
	fi
	completed_marker=${marker}.completed-${run_stamp}
	/bin/mv "$marker" "$completed_marker" || exit 1
	success=1
	printf '%s\n' \
		"SMD014_REBOOT_COMPLETE old_boot_epoch=${old_boot} new_boot_epoch=${new_boot} old_pid=${old_pid} new_pid=${new_pid} smoke_job=${smoke_job} marker=${completed_marker} run_dir=${run_dir}"
}

case "$mode" in
prepare|verify) ;;
*) usage ;;
esac

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	printf 'error: run as root with sudo\n' >&2
	exit 77
fi

for required_file in "$slurm_conf" "$plist_source" "$plist_target" \
	"$scontrol" "$squeue" "$sbatch" "$scancel" "$sacct"; do
	[ -e "$required_file" ] || {
		printf 'error: missing %s\n' "$required_file" >&2
		exit 66
	}
done
for required_command in /bin/cat /bin/chmod /bin/cp /bin/date /bin/hostname \
	/bin/kill /bin/launchctl /bin/mkdir /bin/mv /bin/ps /bin/rm /bin/sleep \
	/usr/bin/awk /usr/bin/env /usr/bin/grep /usr/bin/id /usr/bin/install \
	/usr/bin/plutil /usr/bin/sed /usr/bin/shasum /usr/bin/stat /usr/bin/sudo \
	/usr/bin/sw_vers /usr/bin/tr /usr/bin/uname /usr/bin/wc \
	/usr/libexec/PlistBuddy /usr/sbin/chown /usr/sbin/ipconfig \
	/usr/sbin/sysctl; do
	[ -x "$required_command" ] || {
		printf 'error: required command is not executable: %s\n' \
			"$required_command" >&2
		exit 69
	}
done
if ! /usr/bin/id "$test_user" >/dev/null 2>&1; then
	printf 'error: test user %s does not exist\n' "$test_user" >&2
	exit 67
fi

/bin/mkdir -m 0755 "$run_dir" || exit 1
printf 'mode=%s run_dir=%s marker=%s\n' "$mode" "$run_dir" "$marker"
trap cleanup EXIT HUP INT TERM

case "$mode" in
prepare) prepare_reboot ;;
verify) verify_reboot ;;
esac
