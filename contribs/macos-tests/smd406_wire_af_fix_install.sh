#!/bin/sh

set -u

if [ "${SMD406_WIRE_AF_FIX_INSTALL_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD406_WIRE_AF_FIX_INSTALL_CONFIRMED=YES after approving the production library replacement' >&2
	exit 64
fi

source_root=/Users/REDACTED_USER/dev/slurm.26-05
source_file=${source_root}/src/common/slurm_protocol_socket.c
candidate=${source_root}/src/api/.libs/libslurmfull.dylib
prefix=/opt/slurm/26.11.0
production=${prefix}/lib/slurm/libslurmfull.dylib
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
sacct=${prefix}/bin/sacct
plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_target=system/org.schedmd.slurmd
pid_file=/var/run/slurmd.pid
node_name=PC-210
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd406-wire-af-install-${run_stamp}
backup_dir=${prefix}/.smd406-wire-af-backup-${run_stamp}
install_tmp=${production}.smd406-wire-af-${run_stamp}
installed=0
success=0
old_pid=
new_pid=
smoke_job=

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

launchd_pid()
{
	/bin/launchctl print "$service_target" 2>/dev/null |
		/usr/bin/awk '/pid =/ { print $3; exit }'
}

is_running()
{
	case "$1" in
	''|*[!0-9]*) return 1 ;;
	esac
	/bin/kill -0 "$1" >/dev/null 2>&1
}

wait_process_stop()
{
	pid=$1
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		is_running "$pid" || return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

restart_launchd()
{
	label=$1
	previous_pid=$(launchd_pid)
	/bin/launchctl bootout "$service_target" >"${run_dir}/${label}-bootout.out" \
		2>"${run_dir}/${label}-bootout.err" || return 1
	wait_process_stop "$previous_pid" || return 1
	/bin/launchctl enable "$service_target" >/dev/null 2>&1 || return 1
	/bin/launchctl bootstrap system "$plist" >"${run_dir}/${label}-bootstrap.out" \
		2>"${run_dir}/${label}-bootstrap.err" || return 1
	return 0
}

wait_node_idle()
{
	previous_pid=$1
	attempt=0
	while [ "$attempt" -lt 240 ]; do
		"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" \
			2>"${run_dir}/node-after.err" || true
		state=$(node_field State "${run_dir}/node-after.txt")
		pid=$(launchd_pid)
		if [ "$state" = IDLE ] && [ -n "$pid" ] && \
			[ "$pid" != "$previous_pid" ] && is_running "$pid"; then
			new_pid=$pid
			/usr/bin/printf 'node_restarted old_pid=%s new_pid=%s wait_seconds=%s\n' \
				"$previous_pid" "$new_pid" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }'
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 120 ]; do
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

wait_accounting()
{
	job_id=$1
	file=${run_dir}/smoke-accounting.txt
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		"$sacct" -j "$job_id" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList \
			>"$file" 2>"${run_dir}/smoke-accounting.err" || true
		if /usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" &&
		$5 == "PC-210" { job_ok = 1 }
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

restore_library()
{
	[ "$installed" -eq 1 ] || return 0
	[ -f "${backup_dir}/libslurmfull.dylib" ] || return 1
	owner=$(/usr/bin/stat -f '%Su' "${backup_dir}/libslurmfull.dylib") || return 1
	group=$(/usr/bin/stat -f '%Sg' "${backup_dir}/libslurmfull.dylib") || return 1
	mode=$(/usr/bin/stat -f '%Lp' "${backup_dir}/libslurmfull.dylib") || return 1
	/usr/bin/install -o "$owner" -g "$group" -m "$mode" \
		"${backup_dir}/libslurmfull.dylib" "$install_tmp" || return 1
	/bin/mv -f "$install_tmp" "$production" || return 1
	restart_launchd recovery-restore || return 1
	installed=0
	/usr/bin/printf 'recovery: production library restored from %s\n' \
		"$backup_dir" >&2
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ]; then
		restore_library || /usr/bin/printf '%s\n' \
			"recovery_error: manually restore ${backup_dir}/libslurmfull.dylib" >&2
	fi
	[ ! -e "$install_tmp" ] || /bin/rm -f "$install_tmp"
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this installer is for macOS'
for required in "$source_file" "$candidate" "$production" "$slurm_conf" \
	"$scontrol" "$squeue" "$sbatch" "$sacct" "$plist" "$pid_file"; do
	[ -e "$required" ] || fail "missing $required"
done
for command in /usr/bin/awk /usr/bin/file /usr/bin/install /usr/bin/otool \
	/usr/bin/shasum /usr/bin/stat /usr/bin/sudo /usr/sbin/chown /bin/cat \
	/bin/chmod /bin/cp /bin/date /bin/kill /bin/launchctl /bin/mkdir /bin/mv \
	/bin/rm /bin/sleep /bin/test; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

candidate_mtime=$(/usr/bin/stat -f '%m' "$candidate")
source_mtime=$(/usr/bin/stat -f '%m' "$source_file")
[ "$candidate_mtime" -ge "$source_mtime" ] || \
	fail 'candidate library is older than slurm_protocol_socket.c; rebuild src/api first'

umask 077
/bin/mkdir "$run_dir" || fail 'cannot create run directory'
/bin/chmod 0711 "$run_dir" || fail 'cannot make run directory traversable'
/usr/bin/file "$candidate" >"${run_dir}/candidate-file.txt" || \
	fail 'cannot inspect candidate architecture'
/usr/bin/grep -Fq 'Mach-O 64-bit dynamically linked shared library arm64' \
	"${run_dir}/candidate-file.txt" || fail 'candidate is not an arm64 Mach-O dylib'
/usr/bin/otool -L "$candidate" >"${run_dir}/candidate-otool.txt" || \
	fail 'cannot inspect candidate dependencies'
/usr/bin/nm -m "$candidate" >"${run_dir}/candidate-nm.txt" || \
	fail 'cannot inspect candidate symbols'
for symbol in _slurm_pack_addr _slurm_unpack_addr_no_alloc; do
	/usr/bin/grep -Fq "external ${symbol}" "${run_dir}/candidate-nm.txt" || \
		fail "candidate lacks symbol=$symbol"
done

output_dir=${run_dir}/job-output
/bin/mkdir "$output_dir" || fail 'cannot create smoke output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || \
	fail 'cannot chown smoke output directory'
/bin/chmod 0700 "$output_dir" || fail 'cannot protect smoke output directory'
smoke_script=${run_dir}/smoke.sh
/usr/bin/printf '%s\n' '#!/bin/sh' \
	'printf "job_id=%s node=%s uid=%s gid=%s\n" "$SLURM_JOB_ID" "$(/bin/hostname)" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)"' \
	>"$smoke_script" || fail 'cannot write smoke payload'
/bin/chmod 0755 "$smoke_script" || fail 'cannot make smoke payload executable'
/usr/bin/sudo -u "$test_user" -H /bin/test -r "$smoke_script" || \
	fail 'testuser cannot read smoke payload'
/usr/bin/sudo -u "$test_user" -H /bin/test -w "$output_dir" || \
	fail 'testuser cannot write smoke output directory'

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || \
	fail 'controller ping failed'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || \
	fail 'cannot read node state'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || \
	fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || \
	fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || \
	fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'node has active jobs'

old_pid=$(launchd_pid)
pid_file_value=$(/bin/cat "$pid_file")
[ -n "$old_pid" ] && [ "$old_pid" = "$pid_file_value" ] && is_running "$old_pid" || \
	fail 'launchd and pidfile slurmd identity mismatch'

/usr/bin/shasum -a 256 "$source_file" "$production" "$candidate" \
	>"${run_dir}/before.sha256" || fail 'cannot hash source and libraries'
old_hash=$(/usr/bin/shasum -a 256 "$production" | /usr/bin/awk '{ print $1 }')
candidate_hash=$(/usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{ print $1 }')
[ "$old_hash" != "$candidate_hash" ] || fail 'candidate is already installed; no replacement needed'

trap cleanup EXIT HUP INT TERM
/bin/mkdir -m 0700 "$backup_dir" || fail 'cannot create backup directory'
/bin/cp -p "$production" "${backup_dir}/libslurmfull.dylib" || \
	fail 'cannot back up production library'
backup_hash=$(/usr/bin/shasum -a 256 "${backup_dir}/libslurmfull.dylib" |
	/usr/bin/awk '{ print $1 }')
[ "$backup_hash" = "$old_hash" ] || fail 'backup hash mismatch'

owner=$(/usr/bin/stat -f '%Su' "$production") || fail 'cannot read production owner'
group=$(/usr/bin/stat -f '%Sg' "$production") || fail 'cannot read production group'
mode=$(/usr/bin/stat -f '%Lp' "$production") || fail 'cannot read production mode'
/usr/bin/install -o "$owner" -g "$group" -m "$mode" "$candidate" "$install_tmp" || \
	fail 'cannot stage candidate library'
/bin/mv -f "$install_tmp" "$production" || fail 'cannot install candidate atomically'
installed=1
[ "$(/usr/bin/shasum -a 256 "$production" | /usr/bin/awk '{ print $1 }')" = \
	"$candidate_hash" ] || fail 'installed library hash mismatch'

restart_launchd wire-af-fix || fail 'cannot restart launchd slurmd'
wait_node_idle "$old_pid" || fail 'node did not return to IDLE after library replacement'

smoke_job=$(/usr/bin/sudo -u "$test_user" -H /usr/bin/env SLURM_CONF="$slurm_conf" \
	"$sbatch" --parsable --partition=debug --nodelist="$node_name" \
	--nodes=1 --ntasks=1 --cpus-per-task=1 --mem=64M --time=00:01:00 \
	--chdir=/tmp --output="${output_dir}/smoke-%j.out" \
	--error="${output_dir}/smoke-%j.err" "$smoke_script") || \
	fail 'smoke submission failed'
/usr/bin/printf 'submitted smoke_job=%s\n' "$smoke_job"
wait_job_gone "$smoke_job" || fail 'smoke job remained in queue'
wait_accounting "$smoke_job" || fail 'smoke accounting mismatch'
/usr/bin/awk -v job="$smoke_job" -v uid="$test_uid" -v gid="$test_gid" '
$1 == "job_id=" job && $2 ~ /^node=PC-210([.]local)?$/ &&
$3 == "uid=" uid && $4 == "gid=" gid { ok = 1 }
END { exit !ok }
' "${output_dir}/smoke-${smoke_job}.out" || fail 'smoke output mismatch'

/usr/bin/shasum -a 256 "$source_file" "$production" "$candidate" \
	>"${run_dir}/after.sha256" || fail 'cannot hash installed result'
success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD406_WIRE_AF_FIX_INSTALL_COMPLETE old_hash=%s new_hash=%s old_pid=%s new_pid=%s smoke_job=%s backup=%s run_dir=%s\n' \
	"$old_hash" "$candidate_hash" "$old_pid" "$new_pid" "$smoke_job" \
	"$backup_dir" "$run_dir"
