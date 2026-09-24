#!/bin/sh

set -u

if [ "${SMD401_PMIX_RESTART_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD401_PMIX_RESTART_CONFIRMED=YES after approval' >&2
	exit 64
fi

service_target=system/org.schedmd.slurmd
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
mpi_plugin=${prefix}/lib/slurm/mpi_pmix_v6.so
mpi_generic=${prefix}/lib/slurm/mpi_pmix.so
pid_file=/var/run/slurmd.pid
slurmd_log=/var/log/slurm/slurmd.log
node_name=PC-210
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/private/tmp/slurm-smd401-pmix-restart.${run_stamp}.$$
old_pid=
new_pid=
old_start=
new_start=
log_start_line=1
restart_attempted=0
success=0

export SLURM_CONF="$slurm_conf"

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
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

make_evidence_readable()
{
	if [ -d "$run_dir" ]; then
		/bin/chmod -R a+rX "$run_dir" >/dev/null 2>&1 || true
	fi
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	make_evidence_readable
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf \
			'recovery: restart_attempted=%s; inspect run_dir=%s\n' \
			"$restart_attempted" "$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with administrator authentication'
for required in "$slurm_conf" "$slurmd" "$scontrol" "$squeue" "$srun" \
	"$mpi_plugin" "$mpi_generic" "$pid_file" "$slurmd_log"; do
	[ -e "$required" ] || fail "missing $required"
done

/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
trap cleanup EXIT HUP INT TERM

/bin/launchctl print "$service_target" >"${run_dir}/launchctl-before.txt" || \
	fail 'launchd service is not loaded'
/usr/bin/grep -Fq 'state = running' "${run_dir}/launchctl-before.txt" || \
	fail 'launchd service is not running'
old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*) fail "invalid old slurmd pid=$old_pid" ;;
esac
/bin/kill -0 "$old_pid" >/dev/null 2>&1 || fail 'old slurmd is not running'
/bin/ps -p "$old_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/process-before.txt" || fail 'cannot capture old slurmd process'

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || \
	fail 'controller ping failed before restart'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || \
	fail 'controller is not UP before restart'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || \
	fail 'cannot read node before restart'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || \
	fail 'node is not IDLE before restart'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || \
	fail 'node CPUAlloc is not zero before restart'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || \
	fail 'node AllocMem is not zero before restart'
[ -z "$(node_field AllocTRES "${run_dir}/node-before.txt")" ] || \
	fail 'node AllocTRES is not empty before restart'
[ -z "$("$squeue" -h -w "$node_name")" ] || \
	fail 'node has active jobs before restart'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/stepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before restart'
fi
old_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")
[ -n "$old_start" ] && [ "$old_start" != None ] || \
	fail 'old SlurmdStartTime is invalid'
plugin_mtime=$(/usr/bin/stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' "$mpi_plugin")
/usr/bin/printf 'old_pid=%s\nold_start=%s\nplugin_mtime=%s\n' \
	"$old_pid" "$old_start" "$plugin_mtime" >"${run_dir}/restart-boundary.txt"
/usr/bin/shasum -a 256 "$slurm_conf" "$slurmd" "$mpi_plugin" \
	"$mpi_generic" "$srun" >"${run_dir}/inputs-before.sha256"
log_start_line=$(( $(/usr/bin/wc -l <"$slurmd_log") + 1 ))

restart_attempted=1
/bin/launchctl kickstart -k "$service_target" \
	>"${run_dir}/kickstart.out" 2>"${run_dir}/kickstart.err" || \
	fail 'launchctl kickstart failed'

attempt=0
while [ "$attempt" -lt 60 ]; do
	if [ -f "$pid_file" ]; then
		candidate_pid=$(/bin/cat "$pid_file" 2>/dev/null || true)
		case "$candidate_pid" in
		''|*[!0-9]*) ;;
		*)
			if [ "$candidate_pid" != "$old_pid" ] &&
			    /bin/kill -0 "$candidate_pid" >/dev/null 2>&1; then
				new_pid=$candidate_pid
				break
			fi
			;;
		esac
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
[ -n "$new_pid" ] || fail 'new slurmd pid did not appear within 60 seconds'

attempt=0
while [ "$attempt" -lt 90 ]; do
	if "$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" \
		2>"${run_dir}/node-after.err"; then
		new_start=$(node_field SlurmdStartTime "${run_dir}/node-after.txt")
		if [ "$(node_field State "${run_dir}/node-after.txt")" = IDLE ] &&
		    [ -n "$new_start" ] && [ "$new_start" != "$old_start" ]; then
			break
		fi
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
[ "$attempt" -lt 90 ] || fail 'node did not return to IDLE with a new start time'
[ "$(node_field CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || \
	fail 'node CPUAlloc is not zero after restart'
[ "$(node_field AllocMem "${run_dir}/node-after.txt")" = 0 ] || \
	fail 'node AllocMem is not zero after restart'
[ -z "$(node_field AllocTRES "${run_dir}/node-after.txt")" ] || \
	fail 'node AllocTRES is not empty after restart'
[ -z "$("$squeue" -h -w "$node_name")" ] || \
	fail 'node queue is not empty after restart'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/stepd-after.txt" 2>/dev/null; then
	fail 'slurmstepd exists after restart'
fi

/bin/launchctl print "$service_target" >"${run_dir}/launchctl-after.txt" || \
	fail 'cannot read launchd service after restart'
/usr/bin/grep -Fq 'state = running' "${run_dir}/launchctl-after.txt" || \
	fail 'launchd service is not running after restart'
"$scontrol" ping >"${run_dir}/controller-after.txt" 2>&1 || \
	fail 'controller ping failed after restart'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-after.txt" || \
	fail 'controller is not UP after restart'
"$srun" --mpi=list >"${run_dir}/mpi-list-after.txt" \
	2>"${run_dir}/mpi-list-after.err" || fail 'cannot list MPI plugins after restart'
[ ! -s "${run_dir}/mpi-list-after.err" ] || \
	fail 'srun --mpi=list emitted stderr after restart'
/usr/bin/grep -Eq '^[[:space:]]+pmix$' \
	"${run_dir}/mpi-list-after.txt" || fail 'generic pmix is absent after restart'
/usr/bin/grep -Fq 'pmix_v6' "${run_dir}/mpi-list-after.txt" || \
	fail 'pmix_v6 is absent after restart'

/usr/bin/tail -n "+${log_start_line}" "$slurmd_log" \
	>"${run_dir}/slurmd-log-delta.txt"
/usr/bin/grep -Ei \
	'MPI: Cannot create context for mpi/pmix|pmi/pmix: can not load|'\
'incorrect PMIx library version|Failed to initialize MPI plugins|'\
'symbol not found|Library not loaded' \
	"${run_dir}/slurmd-log-delta.txt" >"${run_dir}/pmix-load-errors.txt" || true
[ ! -s "${run_dir}/pmix-load-errors.txt" ] || \
	fail 'PMIx load error found after restart'
/usr/bin/shasum -a 256 "$slurm_conf" "$slurmd" "$mpi_plugin" \
	"$mpi_generic" "$srun" >"${run_dir}/inputs-after.sha256"
/usr/bin/cmp -s "${run_dir}/inputs-before.sha256" \
	"${run_dir}/inputs-after.sha256" || fail 'production input changed during restart'
/bin/ps -p "$new_pid" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/process-after.txt" || fail 'cannot capture new slurmd process'

success=1
make_evidence_readable
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s%s\n' \
	'SMD401_PMIX_SLURMD_RESTART_COMPLETE' \
	" old_pid=$old_pid new_pid=$new_pid" \
	" old_start=$old_start new_start=$new_start" \
	" production_inputs_unchanged=PASS run_dir=$run_dir"
