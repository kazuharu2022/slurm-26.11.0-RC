#!/bin/sh

set -u

if [ "${SMD113_RUNTIME_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s%s%s\n' \
		'error: set SMD113_RUNTIME_CONFIRMED=YES after approving a temporary slurmd switch,' \
		' intentional node DRAIN, one cancelled failure job,' \
		' and one recovery smoke job' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurm_key=${prefix}/etc/slurm.key
gres_conf=${prefix}/etc/gres.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_label=org.schedmd.slurmd
service_target=system/${service_label}
pid_file=/var/run/slurmd.pid
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
volume_size_mib=64
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd113-runtime-${run_stamp}
mount_point=${run_dir}/volume
mount_point_physical=
image=${run_dir}/smd113-runtime.dmg
isolated_spool=
filler=
candidate_conf=${run_dir}/slurm.conf.isolated-spool
candidate_log=${run_dir}/slurmd-isolated.log
output_dir=${run_dir}/output
failure_script=${run_dir}/must-not-run.sh
smoke_script=${run_dir}/smoke.sh
failure_marker=${output_dir}/FAILURE_PAYLOAD_EXECUTED
device=
mounted=0
production_stopped=0
candidate_pid=
old_pid=
restored_pid=
failure_job=
smoke_job=
success=0

export LC_ALL=C

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
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null | /usr/bin/awk 'NR == 1 { print; exit }'
}

cancel_if_active()
{
	job_id=$1
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id" 2>/dev/null || true)
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
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' "$job_id" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_accounting_terminal()
{
	job_id=$1
	output=$2
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		"$sacct" -j "$job_id" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList \
			>"$output" 2>"${output}.err" || true
		if /usr/bin/awk -F '|' -v id="$job_id" '
			$1 == id && $3 ~ /^(CANCELLED|FAILED|NODE_FAIL|TIMEOUT)/ { ok = 1 }
			END { exit !ok }
		' "$output"; then
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
	output=$2
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		"$sacct" -j "$job_id" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList \
			>"$output" 2>"${output}.err" || true
		if /usr/bin/awk -F '|' -v id="$job_id" '
			$1 == id && $3 == "COMPLETED" && $4 == "0:0" { ok = 1 }
			END { exit !ok }
		' "$output"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_process_stop()
{
	pid=$1
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

wait_service_unloaded()
{
	pid=$1
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if ! service_loaded && ! is_running "$pid"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_candidate_ready()
{
	previous_start=$1
	attempt=0
	stable=0
	while [ "$attempt" -lt 180 ]; do
		if is_running "$candidate_pid" && \
			"$scontrol" show node "$node_name" \
			>"${run_dir}/node-candidate.txt" 2>"${run_dir}/node-candidate.err"; then
			state=$(field_from_file State "${run_dir}/node-candidate.txt")
			start=$(field_from_file SlurmdStartTime "${run_dir}/node-candidate.txt")
			pid_value=$(/bin/cat "$pid_file" 2>/dev/null || true)
			if [ "$state" = IDLE ] && [ "$start" != "$previous_start" ] && \
				[ "$pid_value" = "$candidate_pid" ]; then
				stable=$((stable + 1))
			else
				stable=0
			fi
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			/usr/bin/printf 'isolated_daemon_ready pid=%s start=%s wait_seconds=%s\n' \
				"$candidate_pid" "$start" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_failure_state()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$scontrol" show node "$node_name" >"${run_dir}/node-failure.txt" \
			2>"${run_dir}/node-failure.err" || true
		"$scontrol" show job "$job_id" >"${run_dir}/job-failure.txt" \
			2>"${run_dir}/job-failure.err" || true
		state=$(field_from_file State "${run_dir}/node-failure.txt")
		if /usr/bin/grep -Fq 'Reason=SlurmdSpoolDir is full' \
			"${run_dir}/node-failure.txt"; then
			case "$state" in
			*DRAIN*)
				/usr/bin/printf 'failure_observed job_id=%s node_state=%s wait_seconds=%s\n' \
					"$job_id" "$state" "$attempt"
				return 0
				;;
			esac
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_registration()
{
	previous_pid=$1
	attempt=0
	stable=0
	while [ "$attempt" -lt 300 ]; do
		observed_pid=
		service_loaded && observed_pid=$(get_service_pid 2>/dev/null || true)
		if [ -n "$observed_pid" ] && [ "$observed_pid" != "$previous_pid" ] && \
			is_running "$observed_pid" && \
			"$scontrol" show node "$node_name" \
			>"${run_dir}/node-restored.txt" 2>"${run_dir}/node-restored.err"; then
			state=$(field_from_file State "${run_dir}/node-restored.txt")
			case "$state" in
			*NOT_RESPONDING*) stable=0 ;;
			*) stable=$((stable + 1)) ;;
			esac
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			restored_pid=$observed_pid
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
	while [ "$attempt" -lt 300 ]; do
		"$scontrol" show node "$node_name" >"${run_dir}/node-idle.txt" \
			2>"${run_dir}/node-idle.err" || true
		state=$(field_from_file State "${run_dir}/node-idle.txt")
		cpu=$(field_from_file CPUAlloc "${run_dir}/node-idle.txt")
		mem=$(field_from_file AllocMem "${run_dir}/node-idle.txt")
		if [ "$state" = IDLE ] && [ "$cpu" = 0 ] && [ "$mem" = 0 ]; then
			/usr/bin/printf 'node_recovered state=%s CPUAlloc=%s AllocMem=%s wait_seconds=%s\n' \
				"$state" "$cpu" "$mem" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

resume_if_needed()
{
	"$scontrol" show node "$node_name" >"${run_dir}/node-before-resume.txt" \
		2>"${run_dir}/node-before-resume.err" || return 1
	state=$(field_from_file State "${run_dir}/node-before-resume.txt")
	case "$state" in
	IDLE) return 0 ;;
	*DRAIN*|DOWN*)
		"$scontrol" update NodeName="$node_name" State=RESUME \
			>"${run_dir}/resume.out" 2>"${run_dir}/resume.err" || return 1
		;;
	*) return 1 ;;
	esac
	return 0
}

is_mounted()
{
	[ -n "$mount_point_physical" ] || return 1
	/sbin/mount | /usr/bin/awk -v target="$mount_point_physical" '
		$2 == "on" && $3 == target { found = 1 }
		END { exit !found }
	'
}

free_volume()
{
	[ "$mounted" -eq 1 ] || return 0
	/bin/rm -f -- "$filler" 2>/dev/null || return 1
	/usr/bin/find "$mount_point" -type f -name 'exhaust-*' -delete || return 1
	return 0
}

detach_volume()
{
	[ "$mounted" -eq 1 ] || return 0
	target=$device
	[ -n "$target" ] || target=$mount_point_physical
	[ -n "$target" ] || target=$mount_point
	/usr/bin/hdiutil detach "$target" >"${run_dir}/detach.out" \
		2>"${run_dir}/detach.err" || return 1
	mounted=0
	return 0
}

bootstrap_production()
{
	/bin/launchctl enable "$service_target" >/dev/null 2>&1 || return 1
	/bin/launchctl bootstrap system "$plist" \
		>"${run_dir}/bootstrap-production.out" \
		2>"${run_dir}/bootstrap-production.err" || return 1
	return 0
}

recover_production()
{
	previous_pid=$candidate_pid
	free_volume || return 1
	if is_running "$candidate_pid"; then
		/bin/kill -TERM "$candidate_pid" >/dev/null 2>&1 || return 1
		wait_process_stop "$candidate_pid" || return 1
	fi
	if [ "$mounted" -eq 1 ]; then
		if ! detach_volume; then
			target=$device
			[ -n "$target" ] || target=$mount_point_physical
			/usr/bin/hdiutil detach -force "$target" >/dev/null 2>&1 || return 1
			mounted=0
		fi
	fi
	/bin/rm -f -- "$image" 2>/dev/null || return 1
	if ! service_loaded; then
		bootstrap_production || return 1
	fi
	wait_registration "$previous_pid" || return 1
	resume_if_needed || return 1
	wait_idle || return 1
	production_stopped=0
	return 0
}

make_output_readable()
{
	for file in "$output_dir"/*; do
		[ -e "$file" ] || continue
		/bin/chmod 0644 "$file" || return 1
	done
	return 0
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$failure_job"
	cancel_if_active "$smoke_job"
	if [ "$production_stopped" -eq 1 ]; then
		if recover_production; then
			/usr/bin/printf '%s\n' \
				'recovery: isolated daemon/volume stopped and production launchd restored' >&2
		else
			/usr/bin/printf 'fatal recovery: automatic production restore failed; run_dir=%s\n' \
				"$run_dir" >&2
			rc=1
		fi
	else
		free_volume >/dev/null 2>&1 || true
		if [ "$mounted" -eq 1 ]; then
			target=$device
			[ -n "$target" ] || target=$mount_point_physical
			/usr/bin/hdiutil detach -force "$target" >/dev/null 2>&1 || true
			mounted=0
		fi
		/bin/rm -f -- "$image" 2>/dev/null || true
	fi
	make_output_readable >/dev/null 2>&1 || true
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: inspect run_dir=%s and controller/node state\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for file in "$slurm_conf" "$slurm_key" "$gres_conf" "$slurmd" \
	"$scontrol" "$squeue" "$sbatch" "$scancel" "$sacct" "$plist" "$pid_file"; do
	[ -e "$file" ] || fail "missing $file"
done
for command in /bin/cat /bin/chmod /bin/cp /bin/date /bin/dd /bin/kill \
	/bin/launchctl /bin/ln /bin/mkdir /bin/mv /bin/ps /bin/pwd /bin/rm \
	/bin/rmdir /bin/sh /bin/sleep /sbin/mount /usr/bin/awk /usr/bin/cmp \
	/usr/bin/env /usr/bin/find /usr/bin/grep /usr/bin/hdiutil /usr/bin/id \
	/usr/bin/nohup /usr/bin/pgrep /usr/bin/sed /usr/bin/shasum /usr/bin/stat \
	/usr/bin/sudo /usr/bin/tr /usr/bin/uname /usr/bin/wc; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$mount_point" "$output_dir" ||
	fail 'cannot create runtime directories'
/bin/chmod 0777 "$output_dir" || fail 'cannot make output directory writable'
mount_point_physical=$(cd "$mount_point" && /bin/pwd -P) ||
	fail 'cannot resolve physical mount point'
isolated_spool=${mount_point_physical}/spool
filler=${mount_point_physical}/filler.bin

{
	/usr/bin/printf '%s\n' '#!/bin/sh'
	/usr/bin/printf '/usr/bin/touch %s\n' "$failure_marker"
	/usr/bin/printf '%s\n' '/bin/hostname'
} >"$failure_script" || fail 'cannot create failure payload'
{
	/usr/bin/printf '%s\n' '#!/bin/sh'
	/usr/bin/printf '%s\n' '/bin/hostname'
	/usr/bin/printf '%s\n' 'echo SMD113_RECOVERY_SMOKE_PASS'
} >"$smoke_script" || fail 'cannot create smoke payload'
/bin/chmod 0555 "$failure_script" "$smoke_script" || fail 'cannot set payload mode'

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" ||
	fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" ||
	fail 'cannot read node before test'
[ "$(field_from_file State "${run_dir}/node-before.txt")" = IDLE ] ||
	fail 'node is not IDLE'
[ "$(field_from_file CPUAlloc "${run_dir}/node-before.txt")" = 0 ] ||
	fail 'node CPUAlloc is not zero'
[ "$(field_from_file AllocMem "${run_dir}/node-before.txt")" = 0 ] ||
	fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

service_loaded || fail "launchd service is not loaded: $service_target"
/bin/launchctl print "$service_target" >"${run_dir}/launchd-before.txt" 2>&1 ||
	fail 'cannot inspect production launchd service'
/usr/bin/grep -q 'state = running' "${run_dir}/launchd-before.txt" ||
	fail 'production launchd service is not running'
old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$old_pid" ;;
esac
[ "$(get_service_pid)" = "$old_pid" ] || fail 'launchd and pidfile PID mismatch'
is_running "$old_pid" || fail 'production slurmd is not running'
old_start=$(field_from_file SlurmdStartTime "${run_dir}/node-before.txt")
/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$plist" \
	"$failure_script" "$smoke_script" "$0" >"${run_dir}/inputs-before.sha256" ||
	fail 'cannot capture input hashes'

/usr/bin/hdiutil create -quiet -size "${volume_size_mib}m" -fs HFS+ \
	-volname SMD113RUNTIME "$image" >"${run_dir}/create.out" \
	2>"${run_dir}/create.err" || fail 'cannot create disposable disk image'
/usr/bin/hdiutil attach -nobrowse -owners on -mountpoint "$mount_point_physical" \
	"$image" >"${run_dir}/attach.out" 2>"${run_dir}/attach.err" ||
	fail 'cannot attach disposable disk image'
mounted=1
is_mounted || fail 'disposable volume is not mounted'
device=$(/usr/bin/awk -v mount="$mount_point_physical" '$NF == mount {
	print $1; exit
}' "${run_dir}/attach.out")
case "$device" in
/dev/disk*) ;;
*) fail "cannot identify attached device=$device" ;;
esac
/bin/mkdir -m 0755 "$isolated_spool" || fail 'cannot create isolated spool'
/bin/ln -s "$gres_conf" "${run_dir}/gres.conf" || fail 'cannot link gres.conf'

[ "$(/usr/bin/grep -c '^SlurmdSpoolDir=' "$slurm_conf")" -eq 1 ] ||
	fail 'expected exactly one SlurmdSpoolDir'
[ "$(/usr/bin/grep -c '^SlurmdLogFile=' "$slurm_conf")" -eq 1 ] ||
	fail 'expected exactly one SlurmdLogFile'
/usr/bin/sed \
	-e "s#^SlurmdSpoolDir=.*#SlurmdSpoolDir=${isolated_spool}#" \
	-e "s#^SlurmdLogFile=.*#SlurmdLogFile=${candidate_log}#" \
	"$slurm_conf" >"$candidate_conf" || fail 'cannot create isolated configuration'
/usr/bin/grep -qx "SlurmdSpoolDir=${isolated_spool}" "$candidate_conf" ||
	fail 'isolated spool was not applied'
/usr/bin/env SLURM_SACK_KEY="$slurm_key" "$slurmd" -C -f "$candidate_conf" \
	>"${run_dir}/candidate-parse.out" 2>"${run_dir}/candidate-parse.err" ||
	fail 'isolated configuration did not parse'
/usr/bin/printf '%s%s%s\n' \
	"run_dir=${run_dir} phase=isolated_spool_enospc volume_size_mib=${volume_size_mib}" \
	" old_pid=${old_pid} device=${device}" \
	" spool=${isolated_spool}"

/bin/launchctl bootout "$service_target" >"${run_dir}/bootout-production.out" \
	2>"${run_dir}/bootout-production.err" || fail 'cannot stop production launchd service'
production_stopped=1
wait_service_unloaded "$old_pid" || fail 'production launchd service did not stop cleanly'

/usr/bin/nohup /usr/bin/env SLURM_SACK_KEY="$slurm_key" \
	"$slurmd" -Dvvv -f "$candidate_conf" -N "$node_name" \
	>"${run_dir}/candidate-console.log" 2>&1 </dev/null &
candidate_pid=$!
/usr/bin/printf 'start isolated_candidate_pid=%s\n' "$candidate_pid"
wait_candidate_ready "$old_start" || fail 'isolated slurmd did not become stably IDLE'

/bin/df -k "$mount_point_physical" >"${run_dir}/volume-df-before.txt" ||
	fail 'cannot capture initial volume capacity'
if /bin/dd if=/dev/zero of="$filler" bs=1048576 count=128 \
	>"${run_dir}/fill-dd.out" 2>"${run_dir}/fill-dd.err"; then
	dd_rc=0
else
	dd_rc=$?
fi
[ "$dd_rc" -ne 0 ] || fail 'filler unexpectedly fit in the 64 MiB volume'
/usr/bin/grep -Eiq 'No space left on device|not enough space' \
	"${run_dir}/fill-dd.err" || fail 'dd failure was not ENOSPC'
if /bin/mkdir "${isolated_spool}/probe-dir" >"${run_dir}/mkdir-full.out" \
	2>"${run_dir}/mkdir-full.err"; then
	/bin/rmdir "${isolated_spool}/probe-dir" || fail 'cannot remove probe directory'
	index=1
	: >"${run_dir}/metadata-fill.err"
	while [ "$index" -le 10000 ]; do
		/bin/sh -c ': > "$1"' sh "${mount_point_physical}/exhaust-${index}" \
			2>>"${run_dir}/metadata-fill.err" || break
		index=$((index + 1))
	done
	[ "$index" -le 10000 ] || fail 'metadata exhaustion bound reached without ENOSPC'
	/bin/mkdir "${isolated_spool}/probe-dir" >"${run_dir}/mkdir-full-retry.out" \
		2>"${run_dir}/mkdir-full-retry.err" &&
		fail 'mkdir unexpectedly succeeded after metadata fill'
	/bin/cp "${run_dir}/mkdir-full-retry.err" "${run_dir}/mkdir-full.err" ||
		fail 'cannot preserve mkdir retry error'
fi
/usr/bin/grep -Eiq 'No space left on device|not enough space' \
	"${run_dir}/mkdir-full.err" || fail 'spool mkdir failure was not ENOSPC'
/bin/df -k "$mount_point_physical" >"${run_dir}/volume-df-full.txt" ||
	fail 'cannot capture full volume capacity'
/usr/bin/printf 'volume_full dd_rc=%s device=%s\n' "$dd_rc" "$device"

failure_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=64M --time=00:01:00 --chdir=/tmp \
		--job-name=smd113-enospc \
		--output="${output_dir}/failure-%j.out" \
		--error="${output_dir}/failure-%j.err" "$failure_script"
) || fail 'failure job submission failed'
failure_job=${failure_job%%;*}
case "$failure_job" in
''|*[!0-9]*) fail "invalid failure job id=$failure_job" ;;
esac
/usr/bin/printf 'submitted failure_job=%s\n' "$failure_job"
wait_failure_state "$failure_job" || fail 'expected spool-full DRAIN was not observed'
[ ! -e "$failure_marker" ] || fail 'failure payload executed unexpectedly'
is_running "$candidate_pid" || fail 'isolated slurmd crashed after spool ENOSPC'
/usr/bin/grep -Fq 'No space left on device' "$candidate_log" ||
	fail 'isolated slurmd log lacks ENOSPC'

"$scancel" "$failure_job" >"${run_dir}/failure-scancel.out" \
	2>"${run_dir}/failure-scancel.err" || fail 'cannot cancel failed launch job'
wait_job_gone "$failure_job" || fail 'failure job remained in queue'
wait_accounting_terminal "$failure_job" "${run_dir}/failure-sacct.txt" ||
	fail 'failure job terminal accounting is missing'
[ ! -e "$failure_marker" ] || fail 'failure payload marker appeared after cancellation'

free_volume || fail 'cannot free disposable volume'
/bin/mkdir "${isolated_spool}/recovery-dir" || fail 'spool mkdir did not recover'
/bin/rmdir "${isolated_spool}/recovery-dir" || fail 'cannot remove recovery directory'
/bin/df -k "$mount_point_physical" >"${run_dir}/volume-df-recovered.txt" ||
	fail 'cannot capture recovered volume capacity'

/bin/kill -TERM "$candidate_pid" || fail 'cannot stop isolated slurmd'
wait_process_stop "$candidate_pid" || fail 'isolated slurmd did not stop'
detach_volume || fail 'cannot detach disposable volume'
is_mounted && fail 'disposable volume remains mounted after detach'
/bin/rm -f -- "$image" || fail 'cannot remove disposable disk image'
[ ! -e "$image" ] || fail 'disposable disk image remains'

bootstrap_production || fail 'cannot bootstrap production launchd service'
wait_registration "$candidate_pid" || fail 'production slurmd did not register'
resume_if_needed || fail 'cannot RESUME recovered node'
wait_idle || fail 'node did not recover to IDLE'
production_stopped=0
/usr/bin/printf 'production_restored old_pid=%s candidate_pid=%s restored_pid=%s\n' \
	"$old_pid" "$candidate_pid" "$restored_pid"

smoke_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=64M --time=00:01:00 --chdir=/tmp \
		--job-name=smd113-recovery-smoke \
		--output="${output_dir}/smoke-%j.out" \
		--error="${output_dir}/smoke-%j.err" "$smoke_script"
) || fail 'recovery smoke submission failed'
smoke_job=${smoke_job%%;*}
case "$smoke_job" in
''|*[!0-9]*) fail "invalid smoke job id=$smoke_job" ;;
esac
/usr/bin/printf 'submitted smoke_job=%s\n' "$smoke_job"
wait_job_gone "$smoke_job" || fail 'recovery smoke remained in queue'
wait_accounting_complete "$smoke_job" "${run_dir}/smoke-sacct.txt" ||
	fail 'recovery smoke accounting is not COMPLETED 0:0'
/usr/bin/grep -Fq 'SMD113_RECOVERY_SMOKE_PASS' \
	"${output_dir}/smoke-${smoke_job}.out" || fail 'recovery smoke marker is missing'
[ ! -s "${output_dir}/smoke-${smoke_job}.err" ] || fail 'recovery smoke stderr is not empty'

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" ||
	fail 'cannot read final node state'
[ "$(field_from_file State "${run_dir}/node-after.txt")" = IDLE ] ||
	fail 'final node is not IDLE'
[ "$(field_from_file CPUAlloc "${run_dir}/node-after.txt")" = 0 ] ||
	fail 'final CPUAlloc is not zero'
[ "$(field_from_file AllocMem "${run_dir}/node-after.txt")" = 0 ] ||
	fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs after test'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-after.txt" 2>/dev/null; then
	fail 'slurmstepd remains after test'
fi
service_loaded || fail 'production launchd service is not loaded after recovery'
[ "$(get_service_pid)" = "$restored_pid" ] || fail 'final launchd PID mismatch'
[ "$(/bin/cat "$pid_file")" = "$restored_pid" ] || fail 'final pidfile PID mismatch'
/bin/launchctl print "$service_target" >"${run_dir}/launchd-after.txt" 2>&1 ||
	fail 'cannot inspect restored launchd service'
/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$plist" \
	"$failure_script" "$smoke_script" "$0" >"${run_dir}/inputs-after.sha256" ||
	fail 'cannot capture final input hashes'
/usr/bin/cmp -s "${run_dir}/inputs-before.sha256" \
	"${run_dir}/inputs-after.sha256" || fail 'production or test inputs changed'
make_output_readable || fail 'cannot make output evidence readable'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s\n' \
	"SMD113_SPOOL_ENOSPC_COMPLETE failure_job=${failure_job}" \
	" smoke_job=${smoke_job} old_pid=${old_pid} candidate_pid=${candidate_pid}" \
	" restored_pid=${restored_pid} production_restored=PASS run_dir=${run_dir}"
