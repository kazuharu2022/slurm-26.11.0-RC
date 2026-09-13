#!/bin/sh

set -u

if [ "${SMD124_SPANK_EXIT_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD124_SPANK_EXIT_CONFIRMED=YES after confirming PC-210 is idle' >&2
	exit 64
fi

source_root=/Users/REDACTED_USER/dev/slurm.26-05
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
clang=/usr/bin/clang
plist_buddy=/usr/libexec/PlistBuddy
plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_label=org.schedmd.slurmd
service_target=system/${service_label}
pid_file=/var/run/slurmd.pid
sack_socket=/var/run/slurm/sack.socket
default_plugstack=${prefix}/etc/plugstack.conf
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd124-exit-${run_stamp}
plugin=${run_dir}/smd124_spank_slurmd_lifecycle.so
plugstack=${run_dir}/plugstack.conf
event_log=${run_dir}/spank-slurmd-events.log
readable_event_log=${run_dir}/spank-slurmd-events-evidence.txt
backup_conf=${run_dir}/slurm.conf.before
candidate_conf=${run_dir}/slurm.conf.smd124-exit
output_dir=${run_dir}/output
smoke_script=${run_dir}/smoke.sh
smoke_job=
old_pid=
old_start=
active_start=
new_pid=
restart_required=0
config_backed_up=0
success=0

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
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' "$job_id" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_batch_accounting()
{
	job_id=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		"$sacct" -j "$job_id" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList >"$file" \
			2>"${file%.txt}.err" || true
		if /usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
			$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { job_ok = 1 }
			$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" { batch_ok = 1 }
			END { exit !(job_ok && batch_ok) }
		' "$file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_reconfigure()
{
	previous_start=$1
	output_file=$2
	attempt=0
	stable=0
	observed_start=
	while [ "$attempt" -lt 180 ]; do
		if "$scontrol" show node "$node_name" >"$output_file" 2>/dev/null; then
			state=$(node_field State "$output_file")
			candidate_start=$(node_field SlurmdStartTime "$output_file")
			if [ "$state" = IDLE ] && [ -n "$candidate_start" ] && \
				[ "$candidate_start" != None ] && [ "$candidate_start" != "$previous_start" ]; then
				observed_start=$candidate_start
				stable=$((stable + 1))
			else
				stable=0
			fi
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			/usr/bin/printf '%s\n' "$observed_start"
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
	while is_running "$pid" && [ "$attempt" -lt 90 ]; do
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	! is_running "$pid"
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
	output_file=$3
	launchd_file=$4
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
			"$scontrol" show node "$node_name" >"$output_file" 2>"${output_file}.err"; then
			state=$(node_field State "$output_file")
			start=$(node_field SlurmdStartTime "$output_file")
			if [ "$state" = IDLE ] && [ -n "$start" ] && [ "$start" != None ] && \
				[ "$start" != "$previous_start" ]; then
				stable=$((stable + 1))
				new_pid=$observed_pid
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

wait_any_service_ready()
{
	output_file=$1
	launchd_file=$2
	attempt=0
	stable=0
	while [ "$attempt" -lt 180 ]; do
		observed_pid=
		pid_from_file=
		service_loaded && observed_pid=$(get_service_pid 2>/dev/null || true)
		[ -f "$pid_file" ] && pid_from_file=$(/bin/cat "$pid_file" 2>/dev/null)
		if [ -n "$observed_pid" ] && [ "$pid_from_file" = "$observed_pid" ] && \
			is_running "$observed_pid" && [ -S "$sack_socket" ] && \
			"$scontrol" show node "$node_name" >"$output_file" \
				2>"${output_file}.err"; then
			state=$(node_field State "$output_file")
			if [ "$state" = IDLE ]; then
				stable=$((stable + 1))
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

callback_count()
{
	callback=$1
	/usr/bin/awk -v cb="callback=${callback}" '
		$1 == cb && $2 == "context=slurmd" { count++ }
		END { print count + 0 }
	' "$event_log"
}

wait_callback_count()
{
	callback=$1
	expected=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		[ "$(callback_count "$callback")" = "$expected" ] && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

snapshot_event_log()
{
	[ -f "$event_log" ] || return 0
	/bin/cp "$event_log" "$readable_event_log" || return 1
	/usr/sbin/chown 0:0 "$readable_event_log" || return 1
	/bin/chmod 0444 "$readable_event_log" || return 1
}

restore_config_file()
{
	[ "$config_backed_up" -eq 1 ] || return 0
	/bin/cp "$backup_conf" "$slurm_conf" || return 1
	/usr/bin/cmp -s "$backup_conf" "$slurm_conf" || return 1
	return 0
}

bootstrap_production_service()
{
	/bin/launchctl enable "$service_target" >/dev/null 2>&1 || return 1
	/bin/launchctl bootstrap system "$plist" >/dev/null 2>&1 || return 1
	return 0
}

recover_production_service()
{
	recovery_previous_pid=
	service_loaded && recovery_previous_pid=$(get_service_pid 2>/dev/null || true)
	if service_loaded && is_running "$recovery_previous_pid"; then
		if [ -n "$old_pid" ] && [ "$recovery_previous_pid" = "$old_pid" ]; then
			"$scontrol" reconfigure >/dev/null 2>&1 || return 1
		fi
		wait_any_service_ready "${run_dir}/recovery-node.txt" \
			"${run_dir}/recovery-launchd.txt"
		return $?
	fi
	if service_loaded; then
		/bin/launchctl bootout "$service_target" >/dev/null 2>&1 || true
		if [ -n "$recovery_previous_pid" ]; then
			wait_service_unloaded "$recovery_previous_pid" || return 1
		fi
	fi
	if ! service_loaded; then
		bootstrap_production_service || return 1
	fi
	wait_any_service_ready "${run_dir}/recovery-node.txt" \
		"${run_dir}/recovery-launchd.txt"
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$smoke_job"
	if ! restore_config_file; then
		/usr/bin/printf 'fatal recovery: production config restore failed backup=%s\n' \
			"$backup_conf" >&2
		rc=1
	fi
	if [ "$restart_required" -eq 1 ]; then
		if recover_production_service; then
			/usr/bin/printf 'recovery: production launchd service is stably IDLE\n' >&2
		else
			/usr/bin/printf 'fatal recovery: production launchd service bootstrap failed\n' >&2
			rc=1
		fi
	fi
	if ! snapshot_event_log; then
		/usr/bin/printf 'warning: could not snapshot SPANK slurmd event log\n' >&2
		rc=1
	fi
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: inspect run_dir=%s and verify launchd/node state\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$slurmd" "$scontrol" "$squeue" "$sbatch" \
	"$scancel" "$sacct" "$clang" "$plist_buddy" "$plist" "$pid_file" \
	"${source_root}/contribs/macos-tests/smd124_spank_slurmd_lifecycle.c"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for required_command in /bin/cat /bin/chmod /bin/cp /bin/date /bin/kill \
	/bin/launchctl /bin/mkdir /bin/ps /bin/sleep /usr/bin/awk /usr/bin/cmp \
	/usr/bin/env /usr/bin/file /usr/bin/grep /usr/bin/id /usr/bin/nm \
	/usr/bin/plutil /usr/bin/shasum /usr/bin/sudo /usr/bin/tr /usr/bin/wc \
	/usr/sbin/chown; do
	[ -x "$required_command" ] || fail "required command is not executable: $required_command"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
: >"$event_log" || fail 'cannot create event log'
/bin/chmod 0600 "$event_log" || fail 'cannot protect event log'
/usr/sbin/chown 0:0 "$event_log" || fail 'cannot set event log owner'
{
	/usr/bin/printf '#!/bin/sh\n'
	/usr/bin/printf '/bin/hostname\n'
} >"$smoke_script" || fail 'cannot create smoke script'
/bin/chmod 0555 "$smoke_script" || fail 'cannot set smoke mode'
/usr/sbin/chown 0:0 "$smoke_script" || fail 'cannot set smoke owner'
/usr/bin/printf 'run_dir=%s\n' "$run_dir"

"$clang" -Wall -Wextra -Werror -fPIC -bundle -undefined dynamic_lookup \
	-I"${prefix}/include" -o "$plugin" \
	"${source_root}/contribs/macos-tests/smd124_spank_slurmd_lifecycle.c" \
	>"${run_dir}/compile.out" 2>"${run_dir}/compile.err" || fail 'SPANK plugin compile failed'
/bin/chmod 0555 "$plugin" || fail 'cannot set plugin mode'
/usr/sbin/chown 0:0 "$plugin" || fail 'cannot set plugin owner'
/usr/bin/file "$plugin" >"${run_dir}/plugin-file.txt"
/usr/bin/grep -Fq 'Mach-O 64-bit bundle arm64' "${run_dir}/plugin-file.txt" || \
	fail 'compiled plugin is not an arm64 Mach-O bundle'
/usr/bin/nm -gU "$plugin" >"${run_dir}/plugin-exports.txt" || fail 'cannot inspect plugin exports'
for symbol in plugin_name plugin_type plugin_version spank_plugin_version \
	slurm_spank_init slurm_spank_slurmd_exit; do
	/usr/bin/grep -Eq " _${symbol}$" "${run_dir}/plugin-exports.txt" || \
		fail "missing plugin export=$symbol"
done
/usr/bin/printf 'required %s %s\n' "$plugin" "$event_log" >"$plugstack" || \
	fail 'cannot create plugstack config'
/bin/chmod 0444 "$plugstack" || fail 'cannot set plugstack mode'
/usr/sbin/chown 0:0 "$plugstack" || fail 'cannot set plugstack owner'

trap cleanup EXIT HUP INT TERM

/usr/bin/plutil -lint "$plist" >"${run_dir}/plist-lint.txt" 2>&1 || \
	fail 'production launchd plist is invalid'
[ "$("$plist_buddy" -c 'Print :Label' "$plist")" = "$service_label" ] || \
	fail 'production launchd plist Label mismatch'
[ "$("$plist_buddy" -c 'Print :ProgramArguments:0' "$plist")" = "$slurmd" ] || \
	fail 'production launchd plist slurmd path mismatch'
[ "$("$plist_buddy" -c 'Print :KeepAlive:SuccessfulExit' "$plist")" = false ] || \
	fail 'production launchd plist must not restart after a successful exit'
service_loaded || fail "launchd service is not loaded: $service_target"
/bin/launchctl print "$service_target" >"${run_dir}/launchd-before.txt" 2>&1 || \
	fail 'cannot read launchd service'
/usr/bin/grep -q 'state = running' "${run_dir}/launchd-before.txt" || \
	fail 'launchd service is not running'
/bin/launchctl print-disabled system >"${run_dir}/launchd-disabled-before.txt" 2>&1 || \
	fail 'cannot read launchd enabled state'
/usr/bin/grep -Fq "\"${service_label}\" => enabled" \
	"${run_dir}/launchd-disabled-before.txt" || fail 'launchd service is not enabled'
"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
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
/usr/bin/awk -v expected="$slurmd" '
	$1 == "root" && $3 == 1 && index($0, expected) { ok = 1 }
	END { exit !ok }
' "${run_dir}/slurmd-before.txt" || fail 'slurmd is not root/PPID-1/production-prefix'
old_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")
[ -n "$old_start" ] && [ "$old_start" != None ] || fail 'invalid initial SlurmdStartTime'
[ -S "$sack_socket" ] || fail 'SACK socket is absent'

if /usr/bin/grep -Eq '^[[:space:]]*PlugStackConfig[[:space:]]*=' "$slurm_conf"; then
	fail 'production config already has PlugStackConfig; refusing to replace it'
fi
if [ -s "$default_plugstack" ]; then
	fail "default plugstack is non-empty: $default_plugstack"
fi

/bin/cp -p "$slurm_conf" "$backup_conf" || fail 'cannot back up slurm.conf'
config_backed_up=1
/bin/cp "$backup_conf" "$candidate_conf" || fail 'cannot create candidate config'
{
	/usr/bin/printf '\n# SMD-124 temporary slurmd lifecycle test\n'
	/usr/bin/printf 'PlugStackConfig=%s\n' "$plugstack"
} >>"$candidate_conf" || fail 'cannot append PlugStackConfig'
"$slurmd" -C -f "$candidate_conf" >"${run_dir}/candidate-parse.txt" \
	2>"${run_dir}/candidate-parse.err" || fail 'candidate configuration did not parse'
/usr/bin/shasum -a 256 "$backup_conf" >"${run_dir}/config-before.sha256"
/usr/bin/shasum -a 256 "$candidate_conf" >"${run_dir}/config-candidate.sha256"
/usr/bin/shasum -a 256 "$plugin" >"${run_dir}/plugin.sha256"

restart_required=1
/bin/cp "$candidate_conf" "$slurm_conf" || fail 'cannot apply candidate config'
"$scontrol" reconfigure >"${run_dir}/reconfigure-apply.out" \
	2>"${run_dir}/reconfigure-apply.err" || fail 'candidate reconfigure failed'
active_start=$(wait_reconfigure "$old_start" "${run_dir}/node-active.txt") || \
	fail 'worker did not become stably IDLE with lifecycle plugin'
[ "$(get_service_pid)" = "$old_pid" ] || fail 'slurmd PID changed during reconfigure'
[ "$(/bin/cat "$pid_file")" = "$old_pid" ] || fail 'pidfile changed during reconfigure'
wait_callback_count slurm_spank_init 1 || fail 'slurmd init callback not observed'
[ "$(callback_count slurm_spank_slurmd_exit)" = 0 ] || \
	fail 'slurmd exit callback occurred before shutdown'
/usr/bin/awk -v pid="pid=${old_pid}" '
	$1 == "callback=slurm_spank_init" && $2 == "context=slurmd" &&
	$3 == "euid=0" && $4 == "egid=0" && $5 == pid { ok = 1 }
	END { exit !ok }
' "$event_log" || fail 'slurmd init callback identity/PID mismatch'
/usr/bin/printf 'slurmd_plugin_loaded pid=%s old_start=%s new_start=%s\n' \
	"$old_pid" "$old_start" "$active_start"

[ -z "$("$squeue" -h -w "$node_name")" ] || \
	fail 'PC-210 received a job before graceful stop; refusing bootout'
restore_config_file || fail 'production config file restore failed before shutdown'
/usr/bin/shasum -a 256 "$slurm_conf" >"${run_dir}/config-restored-before-stop.sha256"
/usr/bin/printf 'graceful_stop old_pid=%s method=launchctl_bootout\n' "$old_pid"
/bin/launchctl bootout "$service_target" >"${run_dir}/bootout.out" \
	2>"${run_dir}/bootout.err" || fail 'launchctl bootout failed'
wait_service_unloaded "$old_pid" || \
	fail "launchd service or old slurmd pid=$old_pid remained after bootout"
wait_callback_count slurm_spank_slurmd_exit 1 || fail 'slurmd exit callback not observed'
[ "$(callback_count slurm_spank_init)" = 1 ] || fail 'unexpected slurmd init count'
[ "$(/usr/bin/wc -l <"$event_log" | /usr/bin/tr -d ' ')" = 2 ] || \
	fail 'unexpected slurmd lifecycle event count'
/usr/bin/awk -v pid="pid=${old_pid}" '
	$1 == "callback=slurm_spank_slurmd_exit" && $2 == "context=slurmd" &&
	$3 == "euid=0" && $4 == "egid=0" && $5 == pid { ok = 1 }
	END { exit !ok }
' "$event_log" || fail 'slurmd exit callback identity/PID mismatch'
snapshot_event_log || fail 'cannot snapshot lifecycle event log'
/usr/bin/printf 'slurmd_graceful_exit=PASS pid=%s callbacks=2 identity=0:0\n' "$old_pid"

bootstrap_production_service || fail 'production launchd bootstrap failed'
wait_service_ready "$old_pid" "$active_start" "${run_dir}/node-restarted.txt" \
	"${run_dir}/launchd-restarted.txt" || fail 'production launchd service did not become ready'
restart_required=0
new_start=$(node_field SlurmdStartTime "${run_dir}/node-restarted.txt")
/usr/bin/printf 'production_restarted old_pid=%s new_pid=%s new_start=%s\n' \
	"$old_pid" "$new_pid" "$new_start"
[ "$(/usr/bin/wc -l <"$event_log" | /usr/bin/tr -d ' ')" = 2 ] || \
	fail 'test plugin loaded after production restart'

smoke_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=128M --time=00:01:00 --chdir=/tmp \
		--job-name=smd124-exit-smoke --output="${output_dir}/smoke-%j.out" \
		--error="${output_dir}/smoke-%j.err" "$smoke_script"
) || fail 'post-restart smoke submission failed'
smoke_job=${smoke_job%%;*}
/usr/bin/printf 'submitted smoke_job=%s\n' "$smoke_job"
wait_job_gone "$smoke_job" || fail 'post-restart smoke did not leave queue'
wait_batch_accounting "$smoke_job" "${run_dir}/smoke-sacct.txt" || \
	fail 'post-restart smoke accounting did not reach COMPLETED 0:0'
/usr/bin/grep -Eq '^PC-210(\.local)?$' "${output_dir}/smoke-${smoke_job}.out" || \
	fail 'post-restart smoke hostname mismatch'
[ ! -s "${output_dir}/smoke-${smoke_job}.err" ] || fail 'post-restart smoke stderr is not empty'
[ "$(/usr/bin/wc -l <"$event_log" | /usr/bin/tr -d ' ')" = 2 ] || \
	fail 'test plugin ran after production restart'

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final node queue is not empty'
service_loaded || fail 'launchd service is not loaded after test'
[ "$(get_service_pid)" = "$new_pid" ] || fail 'final launchd PID changed unexpectedly'
/usr/bin/cmp -s "$backup_conf" "$slurm_conf" || fail 'final config is not byte-for-byte restored'
/usr/bin/shasum -a 256 "$slurm_conf" >"${run_dir}/config-restored-final.sha256"

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD124_PHASE_B_COMPLETE old_pid=%s new_pid=%s smoke_job=%s callbacks=2 slurmd_exit=PASS run_dir=%s\n' \
	"$old_pid" "$new_pid" "$smoke_job" "$run_dir"
