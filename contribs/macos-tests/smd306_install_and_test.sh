#!/bin/sh

set -u

if [ "${SMD306_INSTALL_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD306_INSTALL_CONFIRMED=YES to replace production slurmstepd' >&2
	exit 64
fi

source_root=/Users/REDACTED_USER/dev/slurm.26-05
candidate=${source_root}/src/slurmd/slurmstepd/.libs/slurmstepd
source_req=${source_root}/src/slurmd/slurmstepd/req.c
stress_driver=${source_root}/contribs/macos-tests/smd306_proc_absence_driver.sh
prefix=/opt/slurm/26.11.0
production=${prefix}/sbin/slurmstepd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
slurm_conf=${prefix}/etc/slurm.conf
pid_file=/var/run/slurmd.pid
node_name=PC-210
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd306-install-${run_stamp}
backup_dir=${prefix}/.smd306-backup-${run_stamp}
install_tmp=${prefix}/sbin/.slurmstepd.smd306-${run_stamp}
installed=0
already_installed=0
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

restore_binary()
{
	[ "$installed" -eq 1 ] || return 0
	[ -f "${backup_dir}/slurmstepd" ] || return 1
	/usr/bin/install -o root -g wheel -m 0755 \
		"${backup_dir}/slurmstepd" "$install_tmp" || return 1
	/bin/mv -f "$install_tmp" "$production" || return 1
	installed=0
	/usr/bin/printf 'recovery: production slurmstepd restored from %s\n' \
		"$backup_dir" >&2
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ]; then
		restore_binary || \
			/usr/bin/printf '%s\n' \
			"recovery_error: manually restore ${backup_dir}/slurmstepd" >&2
	fi
	[ -e "$install_tmp" ] && /bin/rm -f "$install_tmp"
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this installer is for macOS'
for required in "$candidate" "$source_req" "$stress_driver" "$production" \
	"$scontrol" "$squeue" "$slurm_conf" "$pid_file"; do
	[ -f "$required" ] || fail "missing $required"
done
for command in /usr/bin/awk /usr/bin/file /usr/bin/install /usr/bin/otool \
	/usr/bin/shasum /usr/bin/stat /bin/chmod /bin/cp /bin/date /bin/kill \
	/bin/mkdir /bin/mv /bin/ps /bin/rm /bin/sh; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

candidate_mtime=$(/usr/bin/stat -f '%m' "$candidate")
source_mtime=$(/usr/bin/stat -f '%m' "$source_req")
[ "$candidate_mtime" -ge "$source_mtime" ] || \
	fail 'candidate is older than req.c; rebuild slurmstepd first'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/usr/bin/file "$candidate" >"${run_dir}/candidate-file.txt"
/usr/bin/grep -Fq 'Mach-O 64-bit executable arm64' \
	"${run_dir}/candidate-file.txt" || fail 'candidate is not an arm64 Mach-O executable'
/usr/bin/otool -L "$candidate" >"${run_dir}/candidate-otool.txt" || \
	fail 'cannot inspect candidate dependencies'
/usr/bin/grep -Fq "${prefix}/lib/slurm/libslurmfull.dylib" \
	"${run_dir}/candidate-otool.txt" || fail 'candidate libslurmfull dependency mismatch'

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
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/stepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before installation'
fi
slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail 'slurmd is not running'

/usr/bin/shasum -a 256 "$production" "$candidate" "$source_req" \
	>"${run_dir}/binary-before.sha256"
old_hash=$(/usr/bin/shasum -a 256 "$production" | /usr/bin/awk '{ print $1 }')
candidate_hash=$(/usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{ print $1 }')

trap cleanup EXIT HUP INT TERM
if [ "$old_hash" = "$candidate_hash" ]; then
	already_installed=1
	backup_dir=NOT_CREATED_ALREADY_INSTALLED
	/usr/bin/printf 'production_install=SKIPPED already_installed=YES hash=%s\n' \
		"$candidate_hash"
else
	/bin/mkdir -m 0700 "$backup_dir" || fail 'cannot create backup directory'
	/bin/cp -p "$production" "${backup_dir}/slurmstepd" || \
		fail 'cannot back up production slurmstepd'
	/usr/bin/shasum -a 256 "${backup_dir}/slurmstepd" \
		>"${run_dir}/backup.sha256"
	backup_hash=$(/usr/bin/shasum -a 256 "${backup_dir}/slurmstepd" |
		/usr/bin/awk '{ print $1 }')
	[ "$backup_hash" = "$old_hash" ] || fail 'backup hash mismatch'

	/usr/bin/install -o root -g wheel -m 0755 "$candidate" "$install_tmp" || \
		fail 'cannot stage candidate in production directory'
	/bin/mv -f "$install_tmp" "$production" || \
		fail 'cannot install candidate atomically'
	installed=1
	/usr/bin/printf '%s\n' \
		"production_install=PASS old_hash=$old_hash new_hash=$candidate_hash backup=$backup_dir"
fi
[ "$(/usr/bin/shasum -a 256 "$production" | /usr/bin/awk '{ print $1 }')" = \
	"$candidate_hash" ] || fail 'installed candidate hash mismatch'
[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$production")" = '0:0:755' ] || \
	fail 'installed candidate ownership or mode mismatch'

SMD306_PROC_ABSENCE_CONFIRMED=YES /bin/sh "$stress_driver" \
	>"${run_dir}/stress.stdout" 2>"${run_dir}/stress.stderr" || {
	/bin/cat "${run_dir}/stress.stdout"
	/bin/cat "${run_dir}/stress.stderr" >&2
	fail 'SMD-306 stress driver failed'
}
/bin/cat "${run_dir}/stress.stdout"
[ ! -s "${run_dir}/stress.stderr" ] || fail 'stress driver wrote stderr'

[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || \
	fail 'slurmd PID changed during install/test'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/stepd-final.txt" 2>/dev/null; then
	fail 'slurmstepd remains after stress test'
fi
/usr/bin/shasum -a 256 "$production" "$candidate" "$source_req" \
	>"${run_dir}/binary-after.sha256"
[ "$(/usr/bin/shasum -a 256 "$production" | /usr/bin/awk '{ print $1 }')" = \
	"$candidate_hash" ] || fail 'production binary changed after test'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s%s\n' \
	'SMD306_INSTALL_AND_TEST_COMPLETE' \
	" slurmd_pid=$slurmd_pid old_hash=$old_hash new_hash=$candidate_hash" \
	" backup=$backup_dir already_installed=$already_installed production_installed=PASS" \
	" run_dir=$run_dir"
