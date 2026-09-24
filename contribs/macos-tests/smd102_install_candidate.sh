#!/bin/zsh

set -euo pipefail

if [[ "${SMD102_INSTALL_CONFIRMED:-}" != YES ]]; then
	print -u2 -- 'error: set SMD102_INSTALL_CONFIRMED=YES to install the SMD-102 candidate'
	exit 64
fi

if [[ -z "${SMD102_EXPECTED_SOURCE_SHA256:-}" ||
	-z "${SMD102_EXPECTED_CANDIDATE_SHA256:-}" ||
	-z "${SMD102_EXPECTED_PRODUCTION_SHA256:-}" ]]; then
	print -u2 -- 'error: expected source, candidate, and production SHA-256 values are required'
	exit 64
fi

readonly script_dir="${0:A:h}"
readonly source_root="${script_dir:h:h}"
readonly prefix=/opt/slurm/26.11.0
readonly candidate_input="${SMD102_CANDIDATE_PATH:-${source_root}/src/slurmd/slurmstepd/.libs/slurmstepd}"
readonly source_file_input="${SMD102_SOURCE_FILE_PATH:-${source_root}/src/slurmd/slurmstepd/slurmstepd.c}"
readonly candidate="${candidate_input:A}"
readonly source_file="${source_file_input:A}"
readonly production="${prefix}/sbin/slurmstepd"
readonly scontrol="${prefix}/bin/scontrol"
readonly squeue="${prefix}/bin/squeue"
readonly slurm_conf="${prefix}/etc/slurm.conf"
readonly pid_file=/var/run/slurmd.pid
readonly node_name=PC-210
readonly run_stamp="$(/bin/date '+%Y%m%dT%H%M%S')"
readonly run_dir="/tmp/slurm-smd102-install-${run_stamp}"
readonly backup_dir="${prefix}/.smd102-backup-${run_stamp}"
readonly install_tmp="${prefix}/sbin/.slurmstepd.smd102-${run_stamp}"

installed=0
success=0

fail()
{
	print -u2 -- "error: $*"
	exit 1
}

node_field()
{
	local field=$1
	local file=$2
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
	[[ "$installed" -eq 1 ]] || return 0
	[[ -f "${backup_dir}/slurmstepd" ]] || return 1
	/usr/bin/install -o root -g wheel -m 0755 \
		"${backup_dir}/slurmstepd" "$install_tmp" || return 1
	/bin/mv -f "$install_tmp" "$production" || return 1
	installed=0
	print -u2 -- "recovery: production slurmstepd restored from ${backup_dir}"
}

cleanup()
{
	local rc=$?
	trap - EXIT HUP INT TERM
	if [[ "$success" -ne 1 ]]; then
		restore_binary || print -u2 -- \
			"recovery_error: manually restore ${backup_dir}/slurmstepd"
	fi
	[[ -e "$install_tmp" ]] && /bin/rm -f "$install_tmp"
	exit "$rc"
}

[[ "$(/usr/bin/id -u)" -eq 0 ]] || fail 'run as root with sudo'
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail 'this installer is for macOS'

for required in "$candidate" "$source_file" "$production" "$scontrol" \
	"$squeue" "$slurm_conf" "$pid_file"; do
	[[ -f "$required" ]] || fail "missing ${required}"
done

for command in /usr/bin/awk /usr/bin/file /usr/bin/install /usr/bin/otool \
	/usr/bin/pgrep /usr/bin/shasum /usr/bin/stat /bin/cp /bin/date /bin/kill \
	/bin/mkdir /bin/mv /bin/rm; do
	[[ -x "$command" ]] || fail "required command is not executable: ${command}"
done

/bin/mkdir -m 0755 "$run_dir"
/usr/bin/file "$candidate" >"${run_dir}/candidate-file.txt"
/usr/bin/grep -Fq 'Mach-O 64-bit executable arm64' \
	"${run_dir}/candidate-file.txt" || fail 'candidate is not an arm64 Mach-O executable'
/usr/bin/otool -L "$candidate" >"${run_dir}/candidate-otool.txt"
/usr/bin/grep -Fq "${prefix}/lib/slurm/libslurmfull.dylib" \
	"${run_dir}/candidate-otool.txt" || fail 'candidate libslurmfull dependency mismatch'

source_hash="$(/usr/bin/shasum -a 256 "$source_file" | /usr/bin/awk '{ print $1 }')"
candidate_hash="$(/usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{ print $1 }')"
production_hash="$(/usr/bin/shasum -a 256 "$production" | /usr/bin/awk '{ print $1 }')"
[[ "$source_hash" == "$SMD102_EXPECTED_SOURCE_SHA256" ]] || \
	fail "source hash mismatch: ${source_hash}"
[[ "$candidate_hash" == "$SMD102_EXPECTED_CANDIDATE_SHA256" ]] || \
	fail "candidate hash mismatch: ${candidate_hash}"
[[ "$production_hash" == "$SMD102_EXPECTED_PRODUCTION_SHA256" ]] || \
	fail "production hash mismatch: ${production_hash}"
[[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$production")" == '0:0:755' ]] || \
	fail 'production ownership or mode mismatch'

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || \
	fail 'controller ping failed'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || \
	fail 'cannot read node state'
[[ "$(node_field State "${run_dir}/node-before.txt")" == IDLE ]] || \
	fail 'node is not IDLE'
[[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" == 0 ]] || \
	fail 'node CPUAlloc is not zero'
[[ "$(node_field AllocMem "${run_dir}/node-before.txt")" == 0 ]] || \
	fail 'node AllocMem is not zero'
[[ -z "$("$squeue" -h -w "$node_name")" ]] || fail 'node has active jobs'

if /usr/bin/pgrep -x slurmstepd >"${run_dir}/stepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before installation'
fi

slurmd_pid="$(</var/run/slurmd.pid)"
[[ "$slurmd_pid" == <-> ]] || fail "invalid slurmd pid=${slurmd_pid}"
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail 'slurmd is not running'

/bin/mkdir -m 0700 "$backup_dir"
/bin/cp -p "$production" "${backup_dir}/slurmstepd"
backup_hash="$(/usr/bin/shasum -a 256 "${backup_dir}/slurmstepd" | /usr/bin/awk '{ print $1 }')"
[[ "$backup_hash" == "$production_hash" ]] || fail 'backup hash mismatch'

trap cleanup EXIT HUP INT TERM
/usr/bin/install -o root -g wheel -m 0755 "$candidate" "$install_tmp"
installed=1
/bin/mv -f "$install_tmp" "$production"

installed_hash="$(/usr/bin/shasum -a 256 "$production" | /usr/bin/awk '{ print $1 }')"
[[ "$installed_hash" == "$candidate_hash" ]] || fail 'installed candidate hash mismatch'
[[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$production")" == '0:0:755' ]] || \
	fail 'installed ownership or mode mismatch'
[[ "$(</var/run/slurmd.pid)" == "$slurmd_pid" ]] || \
	fail 'slurmd PID changed during installation'

success=1
trap - EXIT HUP INT TERM
print -- "SMD102_INSTALL_COMPLETE backup=${backup_dir} source_hash=${source_hash} old_hash=${production_hash} new_hash=${candidate_hash} slurmd_pid=${slurmd_pid} run_dir=${run_dir}"
