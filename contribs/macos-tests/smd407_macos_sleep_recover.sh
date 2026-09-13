#!/bin/sh

set -u

if [ "${SMD407_MAC_SLEEP_RECOVERY_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD407_MAC_SLEEP_RECOVERY_CONFIRMED=YES after approving the bounded launchd restart' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
slurmd=${prefix}/sbin/slurmd
pid_file=/var/run/slurmd.pid
service_target=system/org.schedmd.slurmd
plist=/Library/LaunchDaemons/org.schedmd.slurm.slurmd.plist
node_name=PC-210
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-sleep-recovery-${run_stamp}
old_pid=
new_pid=

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
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

service_pid()
{
	/bin/launchctl print "$service_target" 2>/dev/null | /usr/bin/awk '
		$1 == "pid" && $2 == "=" { print $3; exit }
	'
}

is_running()
{
	case "$1" in
	''|*[!0-9]*) return 1 ;;
	esac
	/bin/kill -0 "$1" >/dev/null 2>&1
}

hash_production()
{
	output=$1
	/usr/bin/shasum -a 256 \
		"$slurm_conf" \
		"${prefix}/etc/gres.conf" \
		"$slurmd" \
		"${prefix}/lib/slurm/libslurmfull.dylib" \
		"${prefix}/lib/slurm/tls_none.so" \
		"$plist" >"$output"
}

wait_new_daemon()
{
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		pidfile_pid=
		loaded_pid=
		[ -f "$pid_file" ] && pidfile_pid=$(/bin/cat "$pid_file" 2>/dev/null)
		loaded_pid=$(service_pid 2>/dev/null || true)
		if [ -n "$pidfile_pid" ] && [ "$pidfile_pid" != "$old_pid" ] && \
		   [ "$loaded_pid" = "$pidfile_pid" ] && is_running "$pidfile_pid"; then
			new_pid=$pidfile_pid
			/usr/bin/printf 'new_daemon pid=%s wait_seconds=%s\n' \
				"$new_pid" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_stable_idle()
{
	attempt=0
	stable=0
	while [ "$attempt" -lt 180 ]; do
		if "$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" \
		   2>"${run_dir}/node-after.err"; then
			state=$(field_from_file State "${run_dir}/node-after.txt")
			cpu=$(field_from_file CPUAlloc "${run_dir}/node-after.txt")
			mem=$(field_from_file AllocMem "${run_dir}/node-after.txt")
			alloc=$(field_from_file AllocTRES "${run_dir}/node-after.txt")
			if [ "$state" = IDLE ] && [ "$cpu" = 0 ] && \
			   [ "$mem" = 0 ] && [ -z "$alloc" ]; then
				stable=$((stable + 1))
			else
				stable=0
			fi
		else
			stable=0
		fi
		if [ "$stable" -ge 3 ]; then
			/usr/bin/printf 'node_recovered state=IDLE stable_checks=%s wait_seconds=%s\n' \
				"$stable" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this recovery is for macOS'
[ "$(/bin/hostname -s)" = PC-210 ] || fail "unexpected host=$(/bin/hostname -s)"
for required in "$slurm_conf" "$scontrol" "$squeue" "$slurmd" \
	"$pid_file" "$plist"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_path in /bin/cat /bin/date /bin/hostname /bin/kill \
	/bin/launchctl /bin/mkdir /bin/ps /bin/sleep /usr/bin/awk \
	/usr/bin/cmp /usr/bin/grep /usr/bin/id /usr/bin/pgrep /usr/bin/pmset \
	/usr/bin/shasum /usr/bin/uname; do
	[ -x "$command_path" ] || fail "missing command=$command_path"
done

export SLURM_CONF="$slurm_conf"
umask 077
/bin/mkdir "$run_dir" || fail 'cannot create run directory'
/usr/bin/printf 'mode=MAC_SLEEP_RECOVERY run_dir=%s node=%s\n' \
	"$run_dir" "$node_name"

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || \
	fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || \
	fail 'controller is not UP'
"$scontrol" show config >"${run_dir}/controller-config-before.txt" 2>&1 || \
	fail 'cannot read controller config'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" \
	2>"${run_dir}/node-before.err" || fail 'cannot read PC-210 node'
state=$(field_from_file State "${run_dir}/node-before.txt")
cpu=$(field_from_file CPUAlloc "${run_dir}/node-before.txt")
mem=$(field_from_file AllocMem "${run_dir}/node-before.txt")
alloc=$(field_from_file AllocTRES "${run_dir}/node-before.txt")
case "$state" in
*DOWN*NOT_RESPONDING*|*NOT_RESPONDING*DOWN*) ;;
*) fail "expected DOWN+NOT_RESPONDING state, got=$state" ;;
esac
[ "$cpu" = 0 ] || fail "CPUAlloc is not zero value=$cpu"
[ "$mem" = 0 ] || fail "AllocMem is not zero value=$mem"
[ -z "$alloc" ] || fail "AllocTRES is not empty value=$alloc"
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 queue is not empty'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before recovery'
fi

old_pid=$(/bin/cat "$pid_file")
is_running "$old_pid" || fail "pidfile slurmd is not running pid=$old_pid"
loaded_pid=$(service_pid)
[ "$loaded_pid" = "$old_pid" ] || \
	fail "launchd PID differs from pidfile service=$loaded_pid pidfile=$old_pid"
/bin/launchctl print "$service_target" >"${run_dir}/launchd-before.txt" 2>&1 || \
	fail 'cannot inspect launchd service'
/bin/launchctl procinfo "$old_pid" >"${run_dir}/procinfo-before.txt" 2>&1 || \
	fail 'cannot inspect launchd process identity'
/usr/bin/grep -q "$service_target" "${run_dir}/procinfo-before.txt" || \
	fail 'slurmd process is not associated with expected launchd service'
/bin/ps -p "$old_pid" -o pid,ppid,lstart,etime,state,%cpu,%mem,command \
	>"${run_dir}/slurmd-before.txt" || fail 'cannot inspect slurmd process'
/usr/bin/pmset -g log >"${run_dir}/pmset-log.txt" 2>"${run_dir}/pmset-log.err" || \
	fail 'cannot capture sleep/wake log'
hash_production "${run_dir}/production-before.sha256" || \
	fail 'cannot hash production inputs'

/usr/bin/printf 'restart launchd_service=%s old_pid=%s state=%s\n' \
	"$service_target" "$old_pid" "$state"
/bin/launchctl kickstart -k "$service_target" \
	>"${run_dir}/kickstart.out" 2>"${run_dir}/kickstart.err" || \
	fail 'launchctl kickstart failed'
wait_new_daemon || fail 'replacement slurmd did not become launchd-managed'
wait_stable_idle || fail 'PC-210 did not recover to stable IDLE'

/bin/launchctl print "$service_target" >"${run_dir}/launchd-after.txt" 2>&1 || \
	fail 'cannot inspect final launchd service'
/bin/ps -p "$new_pid" -o pid,ppid,lstart,etime,state,%cpu,%mem,command \
	>"${run_dir}/slurmd-after.txt" || fail 'cannot inspect replacement slurmd'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 queue is not empty after recovery'
hash_production "${run_dir}/production-after.sha256" || \
	fail 'cannot hash final production inputs'
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production inputs changed'

/usr/bin/printf '%s\n' \
	"SMD407_MAC_SLEEP_RECOVERY_COMPLETE old_pid=$old_pid new_pid=$new_pid cause=IDLE_SLEEP_TIMEOUT node_state=IDLE allocations=ZERO queue=EMPTY production_unchanged=PASS run_dir=$run_dir"
