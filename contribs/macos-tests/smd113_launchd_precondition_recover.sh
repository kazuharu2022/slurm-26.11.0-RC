#!/bin/sh

set -u

if [ "${SMD113_LAUNCHD_RECOVERY_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD113_LAUNCHD_RECOVERY_CONFIRMED=YES after approving' \
		'recovery of the unmanaged production slurmd into launchd' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
pid_file=/var/run/slurmd.pid
sack_socket=/var/run/slurm/sack.socket
plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_label=org.schedmd.slurmd
service_target=system/${service_label}
node_name=PC-210
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd113-launchd-recovery-${run_stamp}
old_pid=
new_pid=
old_start=
new_start=
old_stopped=0
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

bootstrap_service()
{
	/bin/launchctl enable "$service_target" || return 1
	/bin/launchctl bootstrap system "$plist" || return 1
}

wait_old_gone()
{
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		if ! is_running "$old_pid"; then
			/usr/bin/printf 'old_slurmd_stopped pid=%s wait_seconds=%s\n' \
				"$old_pid" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_stable_idle()
{
	previous_pid=$1
	attempt=0
	stable=0
	while [ "$attempt" -lt 180 ]; do
		observed_pid=
		pidfile_pid=
		service_loaded && observed_pid=$(get_service_pid 2>/dev/null || true)
		[ -f "$pid_file" ] && pidfile_pid=$(/bin/cat "$pid_file" 2>/dev/null)
		if [ -n "$observed_pid" ] && [ "$observed_pid" != "$previous_pid" ] && \
			[ "$pidfile_pid" = "$observed_pid" ] && is_running "$observed_pid" && \
			[ -S "$sack_socket" ] && \
			"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" \
			2>"${run_dir}/node-after.err"; then
			state=$(field_from_file State "${run_dir}/node-after.txt")
			cpu=$(field_from_file CPUAlloc "${run_dir}/node-after.txt")
			mem=$(field_from_file AllocMem "${run_dir}/node-after.txt")
			alloc=$(field_from_file AllocTRES "${run_dir}/node-after.txt")
			new_start=$(field_from_file SlurmdStartTime "${run_dir}/node-after.txt")
			if [ "$state" = IDLE ] && [ "$cpu" = 0 ] && [ "$mem" = 0 ] && \
				[ -z "$alloc" ] && [ -n "$new_start" ] && \
				[ "$new_start" != "$old_start" ]; then
				new_pid=$observed_pid
				stable=$((stable + 1))
			else
				stable=0
			fi
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			/bin/launchctl print "$service_target" \
				>"${run_dir}/launchd-after.txt" 2>&1 || return 1
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

recover()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$old_stopped" -eq 1 ] && ! service_loaded; then
		/usr/bin/printf '%s\n' \
			'recovery: launchd service is absent; retrying production bootstrap' >&2
		bootstrap_service >"${run_dir}/recovery-bootstrap.out" \
			2>"${run_dir}/recovery-bootstrap.err" || true
	fi
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: inspect run_dir=%s before Phase B\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$slurmd" "$scontrol" "$squeue" \
	"$pid_file" "$sack_socket" "$plist"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for command in /usr/bin/awk /usr/bin/cmp /usr/bin/grep /usr/bin/id \
	/usr/bin/pgrep /usr/bin/shasum \
	/usr/bin/tr /usr/bin/uname /bin/cat /bin/date /bin/kill \
	/bin/launchctl /bin/mkdir /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/usr/bin/printf 'run_dir=%s mode=LAUNCHD_PRECONDITION_RECOVERY\n' "$run_dir"

trap recover EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || \
	fail 'controller ping failed before any change'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || \
	fail 'controller is not UP before any change'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" \
	2>"${run_dir}/node-before.err" || fail 'node readback failed before any change'
state=$(field_from_file State "${run_dir}/node-before.txt")
cpu=$(field_from_file CPUAlloc "${run_dir}/node-before.txt")
mem=$(field_from_file AllocMem "${run_dir}/node-before.txt")
alloc=$(field_from_file AllocTRES "${run_dir}/node-before.txt")
[ "$state" = IDLE ] || fail "node is not IDLE state=$state"
[ "$cpu" = 0 ] || fail "CPUAlloc is not zero value=$cpu"
[ "$mem" = 0 ] || fail "AllocMem is not zero value=$mem"
[ -z "$alloc" ] || fail "AllocTRES is not empty value=$alloc"
queue_before=$("$squeue" -h -w "$node_name") || fail 'queue query failed'
[ -z "$queue_before" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before recovery'
fi

old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$old_pid" ;;
esac
is_running "$old_pid" || fail "pidfile slurmd is not running pid=$old_pid"
old_start=$(field_from_file SlurmdStartTime "${run_dir}/node-before.txt")
[ -n "$old_start" ] || fail 'initial SlurmdStartTime is missing'
/usr/bin/shasum -a 256 "$slurm_conf" "$plist" \
	>"${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'
/bin/launchctl print-disabled system >"${run_dir}/launchd-disabled-before.txt" \
	2>&1 || fail 'cannot inspect launchd disabled state'
/usr/bin/grep -Fq '"org.schedmd.slurmd" => enabled' \
	"${run_dir}/launchd-disabled-before.txt" || fail 'launchd service is disabled'

if service_loaded; then
	/bin/launchctl print "$service_target" >"${run_dir}/launchd-before.txt" \
		2>&1 || fail 'cannot inspect loaded launchd service'
	[ "$(get_service_pid)" = "$old_pid" ] || \
		fail 'loaded launchd PID and pidfile PID differ'
	success=1
	trap - EXIT HUP INT TERM
	/usr/bin/printf 'SMD113_LAUNCHD_PRECONDITION_ALREADY_READY pid=%s start=%s run_dir=%s\n' \
		"$old_pid" "$old_start" "$run_dir"
	exit 0
fi

/bin/ps -p "$old_pid" -o pid=,ppid=,lstart=,state=,command= \
	>"${run_dir}/unmanaged-slurmd-before.txt" || fail 'cannot inspect pidfile process'
ppid=$(/bin/ps -p "$old_pid" -o ppid= | /usr/bin/tr -d ' ')
[ "$ppid" = 1 ] || fail "unmanaged slurmd parent is not launchd ppid=$ppid"
command_line=$(/bin/ps -p "$old_pid" -o command=)
case "$command_line" in
"$slurmd "*" -f $slurm_conf"*) ;;
*) fail "pidfile process is not the expected production slurmd command=$command_line" ;;
esac

/usr/bin/printf 'stop_unmanaged_slurmd pid=%s signal=TERM\n' "$old_pid"
/bin/kill -TERM "$old_pid" || fail 'cannot signal unmanaged slurmd'
wait_old_gone || fail 'unmanaged slurmd did not stop within 90 seconds'
old_stopped=1

bootstrap_service >"${run_dir}/bootstrap.out" 2>"${run_dir}/bootstrap.err" || \
	fail 'production launchd bootstrap failed'
wait_stable_idle "$old_pid" || \
	fail 'launchd slurmd did not reach stable IDLE with a new PID'

/usr/bin/shasum -a 256 "$slurm_conf" "$plist" \
	>"${run_dir}/production-after.sha256" || fail 'cannot hash final production inputs'
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input hashes changed'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD113_LAUNCHD_PRECONDITION_RECOVERED old_pid=%s new_pid=%s ' \
	"$old_pid" "$new_pid"
/usr/bin/printf 'old_start=%s new_start=%s production_unchanged=PASS run_dir=%s\n' \
	"$old_start" "$new_start" "$run_dir"
