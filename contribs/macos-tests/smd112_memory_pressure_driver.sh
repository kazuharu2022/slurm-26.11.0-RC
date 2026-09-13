#!/bin/sh

set -u

if [ "${SMD112_MEMORY_PRESSURE_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD112_MEMORY_PRESSURE_CONFIRMED=YES after accepting a bounded 1 GiB test' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
slurmd_log=/var/log/slurm/slurmd.log
source_dir=/Users/REDACTED_USER/dev/slurm.26-05/contribs/macos-tests
source_fixture=${source_dir}/smd112_memory_fixture.c
source_job=${source_dir}/smd112_memory_job.sh
source_driver=${source_dir}/smd112_memory_pressure_driver.sh
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
requested_mib=256
stage_mib=256
max_mib=1024
fixture_timeout=120
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd112-${run_stamp}
input_dir=${run_dir}/input
output_dir=${run_dir}/output
record_dir=${run_dir}/records
evidence_dir=${run_dir}/evidence
active_job=
fixture_pid=
slurmd_pid=
slurmd_start=
start_log_line=1
success=0

export SLURM_CONF="$slurm_conf"

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
}

is_uint()
{
	case "$1" in
	''|*[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
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

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ -n "$active_job" ]; then
		state=$(queue_state "$active_job")
		if [ -n "$state" ]; then
			/usr/bin/printf 'cleanup job_id=%s state=%s\n' \
				"$active_job" "$state" >&2
			"$scancel" "$active_job" >/dev/null 2>&1 || true
		fi
	fi
	if [ -d "$run_dir" ]; then
		/bin/chmod 0755 "$run_dir" "$input_dir" "$evidence_dir" \
			2>/dev/null || true
		/usr/bin/find "$evidence_dir" -type f -exec /bin/chmod 0644 {} \; \
			2>/dev/null || true
	fi
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf '%s\n' \
			"recovery: production was not changed; test job was cancelled; inspect run_dir=${run_dir}" >&2
	fi
	exit "$rc"
}

wait_job_gone()
{
	job=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ -z "$(queue_state "$job")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' \
				"$job" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_file()
{
	path=$1
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		[ -f "$path" ] && return 0
		state=$(queue_state "$active_job")
		[ -n "$state" ] || return 1
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

capture_pressure()
{
	label=$1
	/usr/bin/memory_pressure -Q >"${evidence_dir}/memory-pressure-${label}.txt" \
		2>"${evidence_dir}/memory-pressure-${label}.err" || return 1
	/usr/bin/vm_stat >"${evidence_dir}/vm-stat-${label}.txt" \
		2>"${evidence_dir}/vm-stat-${label}.err" || return 1
}

accounting_complete()
{
	file=$1
	/usr/bin/awk -F '|' -v job="$active_job" -v user="$test_user" '
	$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" &&
	index($5, "mem=256M") && index($6, "mem=256M") { root_ok = 1 }
	$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" &&
	index($6, "mem=256M") { batch_ok = 1 }
	END { exit !(root_ok && batch_ok) }
	' "$file"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for macOS'
for path in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" "$scancel" \
	"$sacct" "$pid_file" "$slurmd_log" "$source_fixture" "$source_job" \
	"$source_driver"; do
	[ -e "$path" ] || fail "missing $path"
done
for command in /usr/bin/awk /usr/bin/clang /usr/bin/diff /usr/bin/find \
	/usr/bin/grep /usr/bin/id /usr/bin/memory_pressure /usr/bin/pgrep \
	/usr/bin/shasum /usr/bin/stat /usr/bin/sudo /usr/bin/tail /usr/bin/touch \
	/usr/bin/vm_stat /usr/bin/wc /usr/sbin/chown /bin/cat /bin/chmod \
	/bin/cp /bin/date /bin/kill /bin/mkdir /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$input_dir" "$evidence_dir" ||
	fail 'cannot create root-readable directories'
/bin/mkdir -m 0700 "$output_dir" "$record_dir" ||
	fail 'cannot create testuser directories'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" "$record_dir" ||
	fail 'cannot chown testuser directories'
/bin/cp "$source_job" "${input_dir}/job.sh" || fail 'cannot stage job script'
/usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror "$source_fixture" \
	-o "${input_dir}/memory-fixture" >"${run_dir}/clang.out" \
	2>"${run_dir}/clang.err" || fail 'cannot build bounded memory fixture'
/bin/chmod 0555 "${input_dir}/job.sh" "${input_dir}/memory-fixture" ||
	fail 'cannot set input modes'
trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 ||
	fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" ||
	fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" ||
	fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] ||
	fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] ||
	fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] ||
	fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

real_memory=$(node_field RealMemory "${run_dir}/node-before.txt")
is_uint "$real_memory" || fail "invalid RealMemory=$real_memory"
[ "$real_memory" -ge 65536 ] || fail "RealMemory is below 64 GiB: $real_memory MiB"
capture_pressure before || fail 'cannot capture initial memory pressure'
physical_bytes=$(/usr/bin/awk '/^The system has [0-9]+ / { print $4; exit }' \
	"${evidence_dir}/memory-pressure-before.txt")
is_uint "$physical_bytes" || fail "invalid physical memory bytes=$physical_bytes"
max_bytes=$((max_mib * 1024 * 1024))
[ "$max_bytes" -le $((physical_bytes / 50)) ] ||
	fail 'bounded allocation exceeds 2 percent of physical memory'
free_percent=$(/usr/bin/awk -F ': ' '/free percentage/ {
		gsub(/%/, "", $2); print $2; exit
	}' "${evidence_dir}/memory-pressure-before.txt")
is_uint "$free_percent" || fail "invalid free memory percentage=$free_percent"
[ "$free_percent" -ge 50 ] ||
	fail "free memory percentage is below safe threshold: ${free_percent}%"

slurmd_pid=$(/bin/cat "$pid_file")
is_uint "$slurmd_pid" || fail "invalid slurmd pid=$slurmd_pid"
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail 'slurmd is not running'
slurmd_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")
start_log_line=$(( $(/usr/bin/wc -l <"$slurmd_log") + 1 ))
/usr/bin/shasum -a 256 "$slurm_conf" "$source_fixture" "$source_job" \
	"$source_driver" >"${run_dir}/inputs-before.sha256"
/usr/bin/printf '%s%s%s\n' \
	"run_dir=${run_dir} requested_mib=${requested_mib} max_mib=${max_mib}" \
	" stage_mib=${stage_mib} physical_bytes=${physical_bytes}" \
	" free_percent=${free_percent} slurmd_pid=${slurmd_pid}"

submit_err=${evidence_dir}/submit.err
active_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
		"SLURM_CONF=${slurm_conf}" "$sbatch" --parsable --export=NONE \
		--partition="$partition" --nodes=1 --ntasks=1 --cpus-per-task=1 \
		--mem="${requested_mib}M" --time=00:03:00 --chdir=/tmp \
		--job-name=smd112-memory --output="${output_dir}/%j.out" \
		--error="${output_dir}/%j.err" "${input_dir}/job.sh" \
		"${input_dir}/memory-fixture" "$record_dir" "$max_mib" \
		"$stage_mib" "$fixture_timeout" 2>"$submit_err"
) || fail 'memory job submission failed'
active_job=${active_job%%;*}
is_uint "$active_job" || fail "invalid job id=$active_job"
[ ! -s "$submit_err" ] || fail 'sbatch emitted stderr'
/usr/bin/printf 'submitted memory_job=%s requested_mib=%s\n' \
	"$active_job" "$requested_mib"

: >"${evidence_dir}/stage-metrics.tsv"
/usr/bin/printf 'stage_mib\tpid\trss_kb\tnode_alloc_mem_mib\tjob_state\n' \
	>"${evidence_dir}/stage-metrics.tsv"
current_mib=$stage_mib
while [ "$current_mib" -le "$max_mib" ]; do
	stage_name=$(/usr/bin/printf 'stage-%04d' "$current_mib")
	stage_file=${record_dir}/${stage_name}
	wait_file "$stage_file" || fail "stage marker not observed: $current_mib MiB"
	current_pid=$(/usr/bin/awk -F '=' '$1 == "pid" { print $2; exit }' \
		"$stage_file")
	allocated=$(/usr/bin/awk -F '=' '$1 == "allocated_mib" { print $2; exit }' \
		"$stage_file")
	is_uint "$current_pid" || fail "invalid fixture pid=$current_pid"
	[ "$allocated" = "$current_mib" ] || fail "stage value mismatch=$allocated"
	if [ -z "$fixture_pid" ]; then
		fixture_pid=$current_pid
	else
		[ "$current_pid" = "$fixture_pid" ] || fail 'fixture PID changed'
	fi
	process_uid=$(/bin/ps -o uid= -p "$fixture_pid" |
		/usr/bin/awk 'NR == 1 { gsub(/ /, ""); print }')
	[ "$process_uid" = "$test_uid" ] || fail "fixture UID mismatch=$process_uid"
	/bin/ps -o pid=,ppid=,pgid=,uid=,state=,command= -p "$fixture_pid" \
		>"${evidence_dir}/process-${current_mib}.txt" ||
		fail "cannot capture process stage=$current_mib"
	/usr/bin/grep -Fq "${input_dir}/memory-fixture" \
		"${evidence_dir}/process-${current_mib}.txt" || fail 'fixture identity mismatch'
	rss_kb=$(/bin/ps -o rss= -p "$fixture_pid" |
		/usr/bin/awk 'NR == 1 { gsub(/ /, ""); print }')
	is_uint "$rss_kb" || fail "invalid RSS=$rss_kb"
	"$scontrol" show node "$node_name" >"${evidence_dir}/node-${current_mib}.txt" ||
		fail "node readback failed stage=$current_mib"
	alloc_mem=$(node_field AllocMem "${evidence_dir}/node-${current_mib}.txt")
	[ "$alloc_mem" = "$requested_mib" ] ||
		fail "scheduler memory allocation mismatch=$alloc_mem"
	state=$(queue_state "$active_job")
	[ "$state" = RUNNING ] || fail "job is not RUNNING stage=$current_mib state=$state"
	capture_pressure "$current_mib" || fail "memory pressure capture failed stage=$current_mib"
	/usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' "$current_mib" \
		"$fixture_pid" "$rss_kb" "$alloc_mem" "$state" \
		>>"${evidence_dir}/stage-metrics.tsv"
	/usr/bin/printf 'stage_mib=%s rss_kb=%s alloc_mem_mib=%s state=%s\n' \
		"$current_mib" "$rss_kb" "$alloc_mem" "$state"
	if [ "$current_mib" -lt "$max_mib" ]; then
		ack_name=$(/usr/bin/printf 'ack-%04d' "$current_mib")
		/usr/bin/touch "${record_dir}/${ack_name}" || fail 'cannot release stage'
	fi
	current_mib=$((current_mib + stage_mib))
done

peak_rss_kb=$(/usr/bin/awk -F '\t' 'NR > 1 && $3 > max { max = $3 }
	END { print max + 0 }' "${evidence_dir}/stage-metrics.tsv")
[ "$peak_rss_kb" -ge $((max_mib * 1024 * 3 / 4)) ] ||
	fail "peak RSS below 75 percent of target: ${peak_rss_kb} KiB"
[ "$peak_rss_kb" -gt $((requested_mib * 1024 * 2)) ] ||
	fail 'process RSS did not exceed twice the requested memory'
/usr/bin/touch "${record_dir}/release" || fail 'cannot release memory fixture'
wait_job_gone "$active_job" || fail "memory job remained id=$active_job"

attempt=0
while [ "$attempt" -lt 60 ]; do
	"$sacct" -j "$active_job" -n -P \
		--format=JobIDRaw,User,State,ExitCode,ReqTRES,AllocTRES \
		>"${evidence_dir}/accounting.txt" \
		2>"${evidence_dir}/accounting.err" || true
	accounting_complete "${evidence_dir}/accounting.txt" && break
	/bin/sleep 1
	attempt=$((attempt + 1))
done
accounting_complete "${evidence_dir}/accounting.txt" || fail 'accounting mismatch'
stdout=${output_dir}/${active_job}.out
stderr=${output_dir}/${active_job}.err
[ -f "$stdout" ] || fail 'missing job stdout'
[ -f "$stderr" ] || fail 'missing job stderr'
[ ! -s "$stderr" ] || fail 'job stderr is not empty'
/usr/bin/grep -Fxq 'actual_uid=3001' "$stdout" || fail 'job UID mismatch'
/usr/bin/grep -Fxq 'actual_gid=3001' "$stdout" || fail 'job GID mismatch'
/usr/bin/grep -Fxq 'slurm_mem_per_node=256' "$stdout" ||
	fail 'SLURM_MEM_PER_NODE mismatch'
/usr/bin/grep -Fxq 'SMD112_ALLOCATOR_PASS max_mib=1024' "$stdout" ||
	fail 'allocator completion marker missing'
/bin/kill -0 "$fixture_pid" >/dev/null 2>&1 && fail 'fixture remains after completion'
completed_job=$active_job
active_job=

/bin/sleep 3
capture_pressure after || fail 'cannot capture final memory pressure'
"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" ||
	fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-final.txt")" = IDLE ] ||
	fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-final.txt")" = 0 ] ||
	fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-final.txt")" = 0 ] ||
	fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed'
[ "$(node_field SlurmdStartTime "${run_dir}/node-final.txt")" = "$slurmd_start" ] ||
	fail 'SlurmdStartTime changed'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-final.txt" 2>/dev/null; then
	fail 'slurmstepd remains after SMD-112'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-final.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-final.txt" \
	>"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'SMD-112 process remains'
/usr/bin/tail -n "+${start_log_line}" "$slurmd_log" \
	>"${run_dir}/slurmd-log-delta.txt"
/usr/bin/grep -Ei \
	'fatal:|_prlimit.*Invalid argument|out of memory|cannot allocate memory|segmentation|abort' \
	"${run_dir}/slurmd-log-delta.txt" >"${run_dir}/unexpected-errors.txt" || true
[ ! -s "${run_dir}/unexpected-errors.txt" ] || fail 'unexpected memory runtime error'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_fixture" "$source_job" \
	"$source_driver" >"${run_dir}/inputs-after.sha256"
/usr/bin/diff -u "${run_dir}/inputs-before.sha256" \
	"${run_dir}/inputs-after.sha256" >"${run_dir}/inputs.diff" ||
	fail 'production config or test inputs changed'

/usr/bin/printf '[stage-metrics]\n'
/bin/cat "${evidence_dir}/stage-metrics.tsv"
/usr/bin/printf '[accounting]\n'
/bin/cat "${evidence_dir}/accounting.txt"
success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s\n' \
	"SMD112_MEMORY_PRESSURE_COMPLETE job_id=${completed_job}" \
	" requested_mib=${requested_mib} touched_mib=${max_mib}" \
	" peak_rss_kb=${peak_rss_kb} enforcement=NOT_PRESENT production_unchanged=PASS run_dir=${run_dir}"
