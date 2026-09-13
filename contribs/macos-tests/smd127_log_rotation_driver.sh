#!/bin/sh

set -u

if [ "${SMD127_LOG_ROTATION_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD127_LOG_ROTATION_CONFIRMED=YES after confirming PC-210 is idle' >&2
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
# macOSでは/varが/private/varへのsymlinkで、lsofは物理pathを表示する。
# file操作用pathとFD照合用pathを分離し、文字列差によるfalse negativeを防ぐ。
slurmd_log_fd_path=/private${slurmd_log}
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd127-${run_stamp}
output_dir=${run_dir}/output
payload=${run_dir}/rotation-payload.sh
rotated_log=${slurmd_log}.smd127-${run_stamp}
rotated_log_fd_path=${slurmd_log_fd_path}.smd127-${run_stamp}
test_job=
slurmd_pid=
log_uid=
log_gid=
log_mode=
old_inode=
rotation_started=0
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
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' \
				"$job_id" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_job_ready()
{
	job_id=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if [ -f "$file" ] && /usr/bin/grep -Fq \
			"rotation_ready job_id=${job_id}" "$file"; then
			return 0
		fi
		state=$(queue_state "$job_id")
		case "$state" in
		RUNNING|COMPLETING) ;;
		PENDING|'') ;;
		*) return 1 ;;
		esac
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

accounting_complete_batch()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { job_ok = 1 }
		$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" { batch_ok = 1 }
		END { exit !(job_ok && batch_ok) }
	' "$file"
}

wait_accounting()
{
	job_id=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		accounting_complete_batch "$job_id" "$file" && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

capture_lsof()
{
	file=$1
	/usr/sbin/lsof -nP -p "$slurmd_pid" >"$file" 2>"${file%.txt}.err"
}

fd_path_count()
{
	file=$1
	pathname=$2
	/usr/bin/awk -v pathname="$pathname" '$NF == pathname { count++ } END { print count + 0 }' "$file"
}

descriptor_count()
{
	file=$1
	/usr/bin/awk 'NR > 1 && $4 ~ /^[0-9]+[rwu]*$/ { count++ } END { print count + 0 }' "$file"
}

wait_log_reopen()
{
	attempt=0
	while [ "$attempt" -lt 30 ]; do
		capture_lsof "${run_dir}/lsof-reopen-${attempt}.txt" || return 1
		active_count=$(fd_path_count "${run_dir}/lsof-reopen-${attempt}.txt" "$slurmd_log_fd_path")
		rotated_count=$(fd_path_count "${run_dir}/lsof-reopen-${attempt}.txt" "$rotated_log_fd_path")
		if [ "$active_count" -eq 1 ] && [ "$rotated_count" -eq 0 ]; then
			/bin/cp "${run_dir}/lsof-reopen-${attempt}.txt" \
				"${run_dir}/lsof-after-reopen.txt"
			/usr/bin/printf '%s\n' "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

ensure_active_log()
{
	[ "$rotation_started" -eq 1 ] || return 0
	if [ ! -e "$slurmd_log" ]; then
		/usr/bin/touch "$slurmd_log" || return 1
		[ -n "$log_uid" ] && [ -n "$log_gid" ] && \
			/usr/sbin/chown "$log_uid:$log_gid" "$slurmd_log"
		[ -n "$log_mode" ] && /bin/chmod "$log_mode" "$slurmd_log"
	fi
	if [ -n "$slurmd_pid" ] && /bin/kill -0 "$slurmd_pid" >/dev/null 2>&1; then
		/bin/kill -USR2 "$slurmd_pid" >/dev/null 2>&1 || return 1
	fi
	return 0
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$test_job"
	if ! ensure_active_log; then
		/usr/bin/printf 'fatal recovery: could not ensure active slurmd log=%s\n' \
			"$slurmd_log" >&2
		rc=1
	fi
	if [ "$success" -ne 1 ]; then
		if [ "$rotation_started" -eq 1 ]; then
			/usr/bin/printf 'recovery: rotated log is preserved at %s; inspect run_dir=%s\n' \
				"$rotated_log" "$run_dir" >&2
		else
			/usr/bin/printf 'recovery: production log was not renamed; inspect run_dir=%s\n' \
				"$run_dir" >&2
		fi
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$scontrol" "$squeue" "$sbatch" \
	"$scancel" "$sacct" "$pid_file" "$slurmd_log"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for command in /usr/bin/awk /usr/bin/grep /usr/bin/id /usr/bin/stat \
	/usr/bin/sudo /usr/bin/touch /usr/bin/tr /usr/bin/wc \
	/usr/sbin/chown /usr/sbin/lsof \
	/bin/cat /bin/chmod /bin/cp /bin/date /bin/kill /bin/mkdir /bin/mv \
	/bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'
[ ! -e "$rotated_log" ] || fail "rotation target already exists=$rotated_log"

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
/bin/cat >"$payload" <<'EOF'
#!/bin/sh
/usr/bin/printf 'rotation_ready job_id=%s pid=%s epoch=%s\n' \
	"${SLURM_JOB_ID:-unset}" "$$" "$(/bin/date +%s)"
i=1
while [ "$i" -le 15 ]; do
	/usr/bin/printf 'heartbeat=%s epoch=%s\n' "$i" "$(/bin/date +%s)"
	/bin/sleep 1
	i=$((i + 1))
done
/usr/bin/printf 'rotation_complete job_id=%s epoch=%s\n' \
	"${SLURM_JOB_ID:-unset}" "$(/bin/date +%s)"
exit 0
EOF
/bin/chmod 0555 "$payload" || fail 'cannot set payload mode'
/usr/sbin/chown 0:0 "$payload" || fail 'cannot set payload owner'
/usr/bin/printf 'run_dir=%s rotated_log=%s active_fd_path=%s rotated_fd_path=%s\n' \
	"$run_dir" "$rotated_log" "$slurmd_log_fd_path" "$rotated_log_fd_path"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'

slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail "slurmd pid=$slurmd_pid is not running"
log_uid=$(/usr/bin/stat -f '%u' "$slurmd_log") || fail 'cannot read log uid'
log_gid=$(/usr/bin/stat -f '%g' "$slurmd_log") || fail 'cannot read log gid'
log_mode=$(/usr/bin/stat -f '%Lp' "$slurmd_log") || fail 'cannot read log mode'
old_inode=$(/usr/bin/stat -f '%i' "$slurmd_log") || fail 'cannot read log inode'
old_size=$(/usr/bin/stat -f '%z' "$slurmd_log") || fail 'cannot read log size'
capture_lsof "${run_dir}/lsof-before.txt" || fail 'cannot capture initial slurmd descriptors'
[ "$(fd_path_count "${run_dir}/lsof-before.txt" "$slurmd_log_fd_path")" -eq 1 ] || \
	fail 'slurmd does not have exactly one active log descriptor before rotation'
fd_before=$(descriptor_count "${run_dir}/lsof-before.txt")

test_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=128M --time=00:01:00 --chdir=/tmp \
		--job-name=smd127-logrotate --output="${output_dir}/job-%j.out" \
		--error="${output_dir}/job-%j.err" "$payload"
) || fail 'rotation test job submission failed'
test_job=${test_job%%;*}
case "$test_job" in
''|*[!0-9]*) fail "invalid test job id=$test_job" ;;
esac
/usr/bin/printf 'submitted test_job=%s\n' "$test_job"
wait_job_ready "$test_job" "${output_dir}/job-${test_job}.out" || \
	fail 'rotation job did not become ready'
/usr/bin/printf 'job_ready job_id=%s\n' "$test_job"

/bin/mv "$slurmd_log" "$rotated_log" || fail 'cannot rename active slurmd log'
rotation_started=1
/usr/bin/touch "$slurmd_log" || fail 'cannot create replacement slurmd log'
/usr/sbin/chown "$log_uid:$log_gid" "$slurmd_log" || fail 'cannot restore log ownership'
/bin/chmod "$log_mode" "$slurmd_log" || fail 'cannot restore log mode'
new_inode=$(/usr/bin/stat -f '%i' "$slurmd_log") || fail 'cannot read new log inode'
[ "$new_inode" != "$old_inode" ] || fail 'replacement log reused old inode'
[ "$(/usr/bin/stat -f '%i' "$rotated_log")" = "$old_inode" ] || \
	fail 'rotated log did not preserve old inode'
capture_lsof "${run_dir}/lsof-after-rename.txt" || fail 'cannot capture descriptors after rename'
[ "$(fd_path_count "${run_dir}/lsof-after-rename.txt" "$rotated_log_fd_path")" -eq 1 ] || \
	fail 'slurmd descriptor did not follow renamed log before reopen'

/bin/kill -USR2 "$slurmd_pid" || fail 'cannot signal slurmd with SIGUSR2'
reopen_wait=$(wait_log_reopen) || fail 'slurmd did not reopen replacement log'
/usr/bin/printf 'log_reopened pid=%s wait_seconds=%s old_inode=%s new_inode=%s\n' \
	"$slurmd_pid" "$reopen_wait" "$old_inode" "$new_inode"

wait_job_gone "$test_job" || fail 'rotation job remained in queue'
wait_accounting "$test_job" "${run_dir}/test-sacct.txt" || \
	fail 'rotation job accounting did not reach COMPLETED 0:0'
/usr/bin/grep -Fq "rotation_complete job_id=${test_job}" \
	"${output_dir}/job-${test_job}.out" || fail 'payload did not complete after rotation'
[ ! -s "${output_dir}/job-${test_job}.err" ] || fail 'rotation job stderr is not empty'

/usr/bin/grep -Fq "Launching batch JobId=${test_job}" "$rotated_log" || \
	fail 'rotated log lacks pre-rotation job launch'
/usr/bin/grep -Fq 'Caught SIGUSR2. Triggering logging update.' "$rotated_log" || \
	fail 'rotated log lacks SIGUSR2 boundary record'
/usr/bin/grep -Fq "[${test_job}.batch] done with step" "$slurmd_log" || \
	fail 'replacement log lacks post-rotation step completion'

capture_lsof "${run_dir}/lsof-final.txt" || fail 'cannot capture final slurmd descriptors'
[ "$(fd_path_count "${run_dir}/lsof-final.txt" "$slurmd_log_fd_path")" -eq 1 ] || \
	fail 'slurmd does not have exactly one active log descriptor after rotation'
[ "$(fd_path_count "${run_dir}/lsof-final.txt" "$rotated_log_fd_path")" -eq 0 ] || \
	fail 'slurmd retains rotated log descriptor'
fd_final=$(descriptor_count "${run_dir}/lsof-final.txt")

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final node queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed during rotation'
[ "$(/usr/bin/stat -f '%u' "$slurmd_log")" = "$log_uid" ] || fail 'new log uid changed'
[ "$(/usr/bin/stat -f '%g' "$slurmd_log")" = "$log_gid" ] || fail 'new log gid changed'
[ "$(/usr/bin/stat -f '%Lp' "$slurmd_log")" = "$log_mode" ] || fail 'new log mode changed'

/bin/chmod 0755 "$output_dir" || fail 'cannot make evidence directory readable'
/bin/chmod 0644 "${output_dir}/job-${test_job}.out" \
	"${output_dir}/job-${test_job}.err" || fail 'cannot make job evidence readable'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD127_LOG_ROTATION_COMPLETE job_id=%s slurmd_pid=%s fd_before=%s fd_final=%s old_size=%s rotated_log=%s run_dir=%s\n' \
	"$test_job" "$slurmd_pid" "$fd_before" "$fd_final" "$old_size" \
	"$rotated_log" "$run_dir"
