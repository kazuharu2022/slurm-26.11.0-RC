#!/bin/sh

set -u

if [ "${SMD111_CHURN_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD111_CHURN_CONFIRMED=YES after accepting 80 short jobs' >&2
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
source_payload=${source_dir}/smd111_churn_payload.sh
source_driver=${source_dir}/smd111_job_churn_driver.sh
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
sequential_count=20
burst_count=36
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd111-${run_stamp}
input_dir=${run_dir}/input
output_dir=${run_dir}/output
record_dir=${run_dir}/records
evidence_dir=${run_dir}/evidence
submit_log_dir=${run_dir}/submit-logs
payload=${input_dir}/payload.sh
all_jobs=${run_dir}/all-jobs.tsv
expected=${run_dir}/expected.tsv
success_jobs=${run_dir}/success-jobs.txt
cancel_jobs=${run_dir}/cancel-jobs.txt
active_jobs=${run_dir}/active-jobs.txt
slurmd_pid=
slurmd_start=
start_log_line=1
node_cpu_total=
hold_count=
hold_running_count=0
hold_pending_count=0
hold_ready_count=0
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
	if [ -f "$active_jobs" ]; then
		while IFS= read -r job; do
			case "$job" in
			''|*[!0-9]*) continue ;;
			esac
			state=$(queue_state "$job")
			if [ -n "$state" ]; then
				/usr/bin/printf 'cleanup job_id=%s state=%s\n' \
					"$job" "$state" >&2
				"$scancel" "$job" >/dev/null 2>&1 || true
			fi
		done <"$active_jobs"
	fi
	if [ -d "$run_dir" ]; then
		/bin/chmod 0755 "$run_dir" "$input_dir" "$evidence_dir" \
			"$submit_log_dir" 2>/dev/null || true
		/usr/bin/find "$evidence_dir" "$submit_log_dir" -type f \
			-exec /bin/chmod 0644 {} \; 2>/dev/null || true
	fi
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf '%s\n' \
			"recovery: production was not changed; test jobs were cancelled; inspect run_dir=${run_dir}" >&2
	fi
	exit "$rc"
}

wait_job_gone()
{
	job=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ -z "$(queue_state "$job")" ]; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

submit_job()
{
	phase=$1
	mode=$2
	sequence=$3
	submit_err=${submit_log_dir}/${phase}-${sequence}.err
	job=$(
		cd /tmp || exit 1
		/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
			"SLURM_CONF=${slurm_conf}" "$sbatch" --parsable \
			--export=NONE --partition="$partition" --nodes=1 --ntasks=1 \
			--cpus-per-task=1 --mem=64M --time=00:03:00 --chdir=/tmp \
			--job-name="smd111-${phase}" \
			--output="${output_dir}/%j.out" \
			--error="${output_dir}/%j.err" \
			"$payload" "$mode" "$sequence" "$record_dir" \
			2>"$submit_err"
	) || return 1
	job=${job%%;*}
	case "$job" in
	''|*[!0-9]*) return 1 ;;
	esac
	[ ! -s "$submit_err" ] || return 1
	/usr/bin/printf '%s\n' "$job" >>"$active_jobs"
	/usr/bin/printf '%s\t%s\t%s\t%s\n' \
		"$job" "$phase" "$mode" "$sequence" >>"$all_jobs"
	/usr/bin/printf '%s\n' "$job"
}

capture_metrics()
{
	phase=$1
	rss_kb=$(/bin/ps -o rss= -p "$slurmd_pid" 2>/dev/null |
		/usr/bin/awk 'NR == 1 { gsub(/ /, ""); print }')
	fd_count=$(/usr/sbin/lsof -a -p "$slurmd_pid" -d 0-999999 -Ff 2>/dev/null |
		/usr/bin/awk '/^f[0-9]+$/ { count++ } END { print count + 0 }')
	thread_count=$(/bin/ps -M -p "$slurmd_pid" -o pid= 2>/dev/null |
		/usr/bin/awk 'END { print NR + 0 }')
	for value in "$rss_kb" "$fd_count" "$thread_count"; do
		is_uint "$value" || return 1
	done
	[ "$rss_kb" -gt 0 ] || return 1
	[ "$fd_count" -gt 0 ] || return 1
	[ "$thread_count" -gt 0 ] || return 1
	/usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
		"$(/bin/date '+%s')" "$phase" "$rss_kb" "$fd_count" \
		"$thread_count" >>"${run_dir}/metrics.tsv"
}

accounting_valid()
{
	file=$1
	/usr/bin/awk -F '|' '
	FNR == NR {
		split($0, fields, "\t")
		expected[fields[1]] = fields[2]
		count++
		next
	}
	{
		id = $1
		if (id in expected) {
			root_seen[id] = 1
			if ($2 != "testuser") bad = 1
			if (expected[id] == "COMPLETED") {
				if ($3 != "COMPLETED" || $4 != "0:0")
					bad = 1
			} else if (index($3, "CANCELLED") != 1) {
				bad = 1
			}
			next
		}
		parent = id
		sub(/\.batch$/, "", parent)
		if (parent in expected && id == parent ".batch") {
			batch_seen[parent] = 1
			if (expected[parent] == "COMPLETED" &&
			    ($3 != "COMPLETED" || $4 != "0:0"))
				bad = 1
			if (expected[parent] == "CANCELLED" &&
			    index($3, "CANCELLED") != 1)
				bad = 1
		}
	}
	END {
		for (id in expected) {
			if (!root_seen[id]) bad = 1
			if (expected[id] == "COMPLETED" && !batch_seen[id]) bad = 1
		}
		exit bad || count == 0
	}' "$expected" "$file"
}

wait_accounting_all()
{
	ids=$(/usr/bin/paste -sd, "$active_jobs")
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		"$sacct" -j "$ids" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList,AllocTRES \
			>"${evidence_dir}/accounting.txt" \
			2>"${evidence_dir}/accounting.err" || true
		if accounting_valid "${evidence_dir}/accounting.txt"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

validate_success_outputs()
{
	while IFS= read -r job; do
		stdout=${output_dir}/${job}.out
		stderr=${output_dir}/${job}.err
		[ -f "$stdout" ] || return 1
		[ -f "$stderr" ] || return 1
		[ ! -s "$stderr" ] || return 1
		/usr/bin/grep -Fqx "job_id=${job}" "$stdout" || return 1
		/usr/bin/grep -Fq 'SMD111_PAYLOAD_PASS ' "$stdout" || return 1
		/usr/bin/grep -Fxq 'uid=3001' "$stdout" || return 1
		/usr/bin/grep -Fxq 'gid=3001' "$stdout" || return 1
	done <"$success_jobs"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for macOS'
for path in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" "$scancel" \
	"$sacct" "$pid_file" "$slurmd_log" "$source_payload" "$source_driver"; do
	[ -e "$path" ] || fail "missing $path"
done
for command in /usr/bin/awk /usr/bin/find /usr/bin/grep /usr/bin/id \
	/usr/bin/paste /usr/bin/pgrep /usr/bin/sed /usr/bin/shasum /usr/bin/sort \
	/usr/bin/stat /usr/bin/sudo /usr/bin/tail /usr/bin/touch /usr/bin/tr /usr/bin/wc \
	/usr/sbin/chown /usr/sbin/lsof /bin/cat /bin/chmod /bin/cp /bin/date \
	/bin/kill /bin/mkdir /bin/mv /bin/ps /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$input_dir" "$evidence_dir" \
	"$submit_log_dir" || fail 'cannot create root-readable directories'
/bin/mkdir -m 0700 "$output_dir" "$record_dir" ||
	fail 'cannot create testuser directories'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" "$record_dir" ||
	fail 'cannot chown testuser directories'
/bin/cp "$source_payload" "$payload" || fail 'cannot stage payload'
/bin/chmod 0555 "$payload" || fail 'cannot set payload mode'
: >"$all_jobs"
: >"$expected"
: >"$success_jobs"
: >"$cancel_jobs"
: >"$active_jobs"
/usr/bin/printf 'epoch\tphase\trss_kb\tfd_count\tthread_count\n' \
	>"${run_dir}/metrics.tsv"
trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 ||
	fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" ||
	fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" ||
	fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] ||
	fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] ||
	fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

node_cpu_total=$(node_field CPUTot "${run_dir}/node-before.txt")
is_uint "$node_cpu_total" || fail "invalid CPUTot=$node_cpu_total"
[ "$node_cpu_total" -ge 4 ] || fail "CPUTot is too small: $node_cpu_total"
[ "$node_cpu_total" = 18 ] ||
	fail "official SMD-111 expects CPUTot=18, observed $node_cpu_total"
hold_count=$((node_cpu_total + 6))
[ "$hold_count" -le 32 ] || fail "hold job count is too large: $hold_count"
slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail 'slurmd is not running'
slurmd_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")
start_log_line=$(( $(/usr/bin/wc -l <"$slurmd_log") + 1 ))
/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" "$source_driver" \
	>"${run_dir}/inputs-before.sha256"
capture_metrics before || fail 'cannot capture initial slurmd metrics'
/usr/bin/printf '%s%s%s\n' \
	"run_dir=${run_dir} sequential=${sequential_count} burst=${burst_count}" \
	" hold=${hold_count} total=$((sequential_count + burst_count + hold_count))" \
	" slurmd_pid=${slurmd_pid}"

sequence=1
while [ "$sequence" -le "$sequential_count" ]; do
	job=$(submit_job sequential quick "$sequence") ||
		fail "sequential submit failed sequence=$sequence"
	/usr/bin/printf '%s\tCOMPLETED\n' "$job" >>"$expected"
	/usr/bin/printf '%s\n' "$job" >>"$success_jobs"
	wait_job_gone "$job" || fail "sequential job remained id=$job"
	sequence=$((sequence + 1))
done
capture_metrics after-sequential || fail 'cannot capture metrics after sequential phase'
/usr/bin/printf 'sequential_phase=COMPLETE jobs=%s\n' "$sequential_count"

: >"${run_dir}/burst-jobs.txt"
sequence=1
while [ "$sequence" -le "$burst_count" ]; do
	job=$(submit_job burst quick "$sequence") ||
		fail "burst submit failed sequence=$sequence"
	/usr/bin/printf '%s\n' "$job" >>"${run_dir}/burst-jobs.txt"
	/usr/bin/printf '%s\tCOMPLETED\n' "$job" >>"$expected"
	/usr/bin/printf '%s\n' "$job" >>"$success_jobs"
	sequence=$((sequence + 1))
done
capture_metrics burst-submitted || fail 'cannot capture burst metrics'
while IFS= read -r job; do
	wait_job_gone "$job" || fail "burst job remained id=$job"
done <"${run_dir}/burst-jobs.txt"
capture_metrics after-burst || fail 'cannot capture metrics after burst phase'
/usr/bin/printf 'burst_phase=COMPLETE jobs=%s\n' "$burst_count"

: >"${run_dir}/hold-jobs.tsv"
sequence=1
while [ "$sequence" -le "$hold_count" ]; do
	job=$(submit_job hold hold "$sequence") ||
		fail "hold submit failed sequence=$sequence"
	/usr/bin/printf '%s\t%s\n' "$sequence" "$job" >>"${run_dir}/hold-jobs.tsv"
	sequence=$((sequence + 1))
done

attempt=0
while [ "$attempt" -lt 120 ]; do
	hold_running_count=0
	hold_pending_count=0
	hold_ready_count=$(/usr/bin/find "$record_dir" -type f -name 'ready.*' |
		/usr/bin/wc -l | /usr/bin/tr -d ' ')
	while IFS="$(/usr/bin/printf '\t')" read -r sequence job; do
		state=$(queue_state "$job")
		case "$state" in
		RUNNING) hold_running_count=$((hold_running_count + 1)) ;;
		PENDING) hold_pending_count=$((hold_pending_count + 1)) ;;
		esac
	done <"${run_dir}/hold-jobs.tsv"
	if [ "$hold_running_count" -ge "$node_cpu_total" ] &&
		[ "$hold_pending_count" -ge 1 ] &&
		[ "$hold_ready_count" -ge "$node_cpu_total" ]; then
		break
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
[ "$hold_running_count" -ge "$node_cpu_total" ] ||
	fail "hold running capacity not reached count=$hold_running_count"
[ "$hold_pending_count" -ge 1 ] || fail 'hold phase did not create pending jobs'
[ "$hold_ready_count" -ge "$node_cpu_total" ] ||
	fail "hold payload barrier not reached count=$hold_ready_count"
capture_metrics hold-saturated || fail 'cannot capture saturated metrics'

running_index=0
: >"${run_dir}/hold-states-before.tsv"
while IFS="$(/usr/bin/printf '\t')" read -r sequence job; do
	state=$(queue_state "$job")
	/usr/bin/printf '%s\t%s\t%s\n' "$sequence" "$job" "$state" \
		>>"${run_dir}/hold-states-before.tsv"
	case "$state" in
	RUNNING)
		running_index=$((running_index + 1))
		if [ $((running_index % 2)) -eq 1 ]; then
			/usr/bin/printf '%s\n' "$job" >>"$cancel_jobs"
			/usr/bin/printf '%s\tCANCELLED\n' "$job" >>"$expected"
		else
			/usr/bin/printf '%s\n' "$job" >>"$success_jobs"
			/usr/bin/printf '%s\tCOMPLETED\n' "$job" >>"$expected"
		fi
		;;
	PENDING)
		/usr/bin/printf '%s\n' "$job" >>"$cancel_jobs"
		/usr/bin/printf '%s\tCANCELLED\n' "$job" >>"$expected"
		;;
	*) fail "unexpected hold state job=$job state=$state" ;;
	esac
done <"${run_dir}/hold-jobs.tsv"

cancel_count=$(/usr/bin/wc -l <"$cancel_jobs" | /usr/bin/tr -d ' ')
survivor_count=$((hold_count - cancel_count))
[ "$cancel_count" -gt 0 ] || fail 'no hold jobs selected for cancel'
[ "$survivor_count" -gt 0 ] || fail 'no hold jobs selected as survivors'
: >"${evidence_dir}/scancel.err"
while IFS= read -r job; do
	"$scancel" "$job" 2>>"${evidence_dir}/scancel.err" ||
		fail "scancel failed job=$job"
done <"$cancel_jobs"
[ ! -s "${evidence_dir}/scancel.err" ] || fail 'scancel emitted stderr'
/usr/bin/touch "${record_dir}/release"
while IFS="$(/usr/bin/printf '\t')" read -r sequence job; do
	wait_job_gone "$job" || fail "hold job remained id=$job"
done <"${run_dir}/hold-jobs.tsv"
capture_metrics after-hold || fail 'cannot capture metrics after hold phase'
/usr/bin/printf '%s%s%s\n' \
	"mixed_phase=COMPLETE jobs=${hold_count}" \
	" running_before=${hold_running_count} pending_before=${hold_pending_count}" \
	" cancelled=${cancel_count} survivors=${survivor_count}"

expected_total=$((sequential_count + burst_count + hold_count))
actual_total=$(/usr/bin/wc -l <"$active_jobs" | /usr/bin/tr -d ' ')
unique_total=$(/usr/bin/sort -u "$active_jobs" | /usr/bin/wc -l |
	/usr/bin/tr -d ' ')
expected_rows=$(/usr/bin/wc -l <"$expected" | /usr/bin/tr -d ' ')
success_count=$(/usr/bin/wc -l <"$success_jobs" | /usr/bin/tr -d ' ')
[ "$actual_total" = "$expected_total" ] ||
	fail "submitted job count mismatch expected=$expected_total actual=$actual_total"
[ "$unique_total" = "$expected_total" ] || fail 'job IDs are not unique'
[ "$expected_rows" = "$expected_total" ] || fail 'expected accounting row count mismatch'
[ $((success_count + cancel_count)) -eq "$expected_total" ] ||
	fail 'success/cancel classification count mismatch'

wait_accounting_all || fail 'aggregate accounting mismatch'
validate_success_outputs || fail 'successful payload output mismatch'

/bin/sleep 3
capture_metrics final || fail 'cannot capture final metrics'
/usr/bin/awk -F '\t' '
	NR == 2 {
		first_rss = $3
		first_fd = $4
		first_threads = $5
	}
	NR > 1 {
		last_rss = $3
		last_fd = $4
		last_threads = $5
		if (!peak_fd || $4 > peak_fd) peak_fd = $4
		if (!peak_threads || $5 > peak_threads) peak_threads = $5
	}
	END {
		printf "rss_first_kb=%d\n", first_rss
		printf "rss_final_kb=%d\n", last_rss
		printf "rss_growth_kb=%d\n", last_rss - first_rss
		printf "fd_first=%d\n", first_fd
		printf "fd_final=%d\n", last_fd
		printf "fd_final_growth=%d\n", last_fd - first_fd
		printf "fd_peak=%d\n", peak_fd
		printf "fd_peak_growth=%d\n", peak_fd - first_fd
		printf "threads_first=%d\n", first_threads
		printf "threads_final=%d\n", last_threads
		printf "threads_final_growth=%d\n", last_threads - first_threads
		printf "threads_peak=%d\n", peak_threads
	}' "${run_dir}/metrics.tsv" >"${evidence_dir}/metrics-analysis.txt" ||
	fail 'cannot analyze slurmd metrics'
rss_growth=$(/usr/bin/awk -F '=' '$1 == "rss_growth_kb" { print $2 }' \
	"${evidence_dir}/metrics-analysis.txt")
fd_growth=$(/usr/bin/awk -F '=' '$1 == "fd_final_growth" { print $2 }' \
	"${evidence_dir}/metrics-analysis.txt")
thread_growth=$(/usr/bin/awk -F '=' \
	'$1 == "threads_final_growth" { print $2 }' \
	"${evidence_dir}/metrics-analysis.txt")
[ "$rss_growth" -le 16384 ] || fail "slurmd RSS grew too much: ${rss_growth} KiB"
[ "$fd_growth" -le 2 ] || fail "slurmd final FD growth too large: $fd_growth"
[ "$thread_growth" -le 2 ] || fail "slurmd final thread growth too large: $thread_growth"

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
	fail 'slurmstepd remains after SMD-111'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-final.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-final.txt" \
	>"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'SMD-111 process remains'
/usr/bin/tail -n "+${start_log_line}" "$slurmd_log" \
	>"${run_dir}/slurmd-log-delta.txt"
/usr/bin/grep -Ei \
	'fatal:|pthread_(mutex|cond)|Invalid argument|Protocol not available|'\
'Unexpected missing socket|Socket no longer there|Too many open files|'\
'Bad file descriptor|timer(fd|_create).*failed|segmentation|abort' \
	"${run_dir}/slurmd-log-delta.txt" >"${run_dir}/unexpected-errors.txt" || true
[ ! -s "${run_dir}/unexpected-errors.txt" ] || fail 'unexpected slurmd runtime error'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" "$source_driver" \
	>"${run_dir}/inputs-after.sha256"
/usr/bin/diff -u "${run_dir}/inputs-before.sha256" \
	"${run_dir}/inputs-after.sha256" >"${run_dir}/inputs.diff" ||
	fail 'production config or test inputs changed'

total_jobs=$(/usr/bin/wc -l <"$active_jobs" | /usr/bin/tr -d ' ')
completed_count=$(/usr/bin/wc -l <"$success_jobs" | /usr/bin/tr -d ' ')
/usr/bin/printf '[metrics]\n'
/bin/cat "${evidence_dir}/metrics-analysis.txt"
/usr/bin/printf '[accounting-summary]\n'
/usr/bin/printf 'total_jobs=%s completed_jobs=%s cancelled_jobs=%s\n' \
	"$total_jobs" "$completed_count" "$cancel_count"

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s\n' \
	"SMD111_JOB_CHURN_COMPLETE total_jobs=${total_jobs}" \
	" completed_jobs=${completed_count} cancelled_jobs=${cancel_count}" \
	" slurmd_pid=${slurmd_pid} production_unchanged=PASS run_dir=${run_dir}"
