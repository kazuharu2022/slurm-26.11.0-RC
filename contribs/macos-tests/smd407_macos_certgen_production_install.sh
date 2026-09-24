#!/bin/sh

set -u

mode=${1:-}
candidate=${2:-}
case "$mode" in
preflight|install) ;;
*) /usr/bin/printf 'usage: %s preflight|install /absolute/path/to/certgen_script.so\n' "$0" >&2; exit 64 ;;
esac
case "$candidate" in
/*) ;;
*) /usr/bin/printf '%s\n' 'error: candidate path must be absolute' >&2; exit 64 ;;
esac
if [ "$mode" = install ] && [ "${SMD407_CERTGEN_PRODUCTION_INSTALL_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD407_CERTGEN_PRODUCTION_INSTALL_CONFIRMED=YES after approving the production plugin install' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
plugin=${prefix}/lib/slurm/certgen_script.so
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
inactive_state=${prefix}/.smd407-mac-tls-inactive.env
runtime_state=${prefix}/.smd407-mac-tls-runtime.env
expected_old_hash=d329f6d4f5a14c3e6f7410033112333f8fb45b808b78d1f575d8254b2dfe50a1
expected_new_hash=aa36683403a51dcf9baba1190e0ee3ed2b8f81c4c4972229ce924e05bae25ce4
expected_config_hash=9c7021e4c794fd9ec4e76af0b7cd5c574d1cd058b9ba9c60c849103f0a7577a2
service_target=system/org.schedmd.slurmd
pid_file=/var/run/slurmd.pid
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-mac-certgen-install-${mode}-${run_stamp}
backup_dir=${prefix}/.smd407-certgen-backup-${run_stamp}
mutation=0
success=0
runtime_state_hash=ABSENT

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
}

file_hash()
{
	/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
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

managed_slurmd_pid()
{
	[ -f "$pid_file" ] || return 1
	pid=$(/bin/cat "$pid_file")
	case "$pid" in ''|*[!0-9]*) return 1 ;; esac
	/bin/kill -0 "$pid" >/dev/null 2>&1 || return 1
	/bin/launchctl procinfo "$pid" 2>/dev/null | \
		/usr/bin/grep -Fq "$service_target = {" || return 1
	/usr/bin/printf '%s\n' "$pid"
}

atomic_install()
{
	source_file=$1
	target_file=$2
	reference_file=$3
	tmp_file=${target_file}.smd407-certgen.$$
	owner=$(/usr/bin/stat -f '%Su' "$reference_file") || return 1
	group=$(/usr/bin/stat -f '%Sg' "$reference_file") || return 1
	file_mode=$(/usr/bin/stat -f '%Lp' "$reference_file") || return 1
	if ! /usr/bin/install -o "$owner" -g "$group" -m "$file_mode" \
		"$source_file" "$tmp_file"; then
		/bin/rm -f "$tmp_file"
		return 1
	fi
	if ! /bin/mv -f "$tmp_file" "$target_file"; then
		/bin/rm -f "$tmp_file"
		return 1
	fi
}

verify_cluster()
{
	label=$1
	"$scontrol" ping >"${run_dir}/${label}-controller.txt" 2>&1 || return 1
	"$scontrol" show config >"${run_dir}/${label}-config.txt" 2>&1 || return 1
	/usr/bin/grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' \
		"${run_dir}/${label}-config.txt" || return 1
	for node in ubuntu PC-210; do
		"$scontrol" show node "$node" >"${run_dir}/${label}-${node}.txt" 2>&1 || return 1
		[ "$(node_field State "${run_dir}/${label}-${node}.txt")" = IDLE ] || return 1
		[ "$(node_field CPUAlloc "${run_dir}/${label}-${node}.txt")" = 0 ] || return 1
		[ "$(node_field AllocMem "${run_dir}/${label}-${node}.txt")" = 0 ] || return 1
	done
	"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/${label}-queue.txt" 2>&1 || return 1
	[ ! -s "${run_dir}/${label}-queue.txt" ]
}

cleanup_on_exit()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$mutation" -eq 1 ] && \
		[ -f "${backup_dir}/certgen_script.so.before" ]; then
		if atomic_install "${backup_dir}/certgen_script.so.before" "$plugin" \
			"${backup_dir}/certgen_script.so.before" && \
			[ "$(file_hash "$plugin")" = "$expected_old_hash" ]; then
			/usr/bin/printf 'recovery: original Mac certgen plugin restored backup=%s\n' \
				"$backup_dir" >&2
		else
			/usr/bin/printf 'fatal recovery: Mac certgen plugin restore failed backup=%s\n' \
				"$backup_dir" >&2
		fi
	fi
	/usr/bin/find "$run_dir" -type f -exec /bin/chmod a+r {} \; >/dev/null 2>&1 || true
	exit "$rc"
}

trap cleanup_on_exit EXIT HUP INT TERM

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this installer is for macOS'
[ "$(/bin/hostname -s)" = PC-210 ] || fail "unexpected host=$(/bin/hostname -s)"
for required in "$candidate" "$plugin" "$slurm_conf" "$scontrol" "$squeue" \
	"$inactive_state" "$pid_file"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_path in /bin/cat /bin/chmod /bin/cp /bin/date /bin/hostname \
	/bin/kill /bin/launchctl /bin/mkdir /bin/mv /bin/rm /usr/bin/awk \
	/usr/bin/file /usr/bin/find /usr/bin/grep /usr/bin/id /usr/bin/install \
	/usr/bin/shasum /usr/bin/stat /usr/bin/uname; do
	[ -x "$command_path" ] || fail "missing command=$command_path"
done

/bin/mkdir "$run_dir" || fail 'cannot create run directory'
/bin/chmod 0755 "$run_dir" || fail 'cannot make run directory readable'
/usr/bin/file "$candidate" >"${run_dir}/candidate-file.txt" || fail 'cannot inspect candidate'
/usr/bin/grep -Eq 'Mach-O 64-bit bundle arm64' "${run_dir}/candidate-file.txt" || \
	fail 'candidate architecture mismatch'
[ "$(file_hash "$candidate")" = "$expected_new_hash" ] || fail 'candidate hash mismatch'
[ "$(file_hash "$plugin")" = "$expected_old_hash" ] || fail 'production plugin hash mismatch'
[ "$(file_hash "$slurm_conf")" = "$expected_config_hash" ] || fail 'production config hash mismatch'
[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$plugin")" = root:wheel:755 ] || \
	fail 'production plugin metadata mismatch'
[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$inactive_state")" = root:wheel:600 ] || \
	fail 'inactive state metadata mismatch'
/usr/bin/grep -Fqx 'phase=MAC_INACTIVE_INSTALLED' "$inactive_state" || \
	fail 'unexpected inactive state phase'
if [ -e "$runtime_state" ]; then
	[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$runtime_state")" = root:wheel:600 ] || \
		fail 'retained runtime state metadata mismatch'
	/usr/bin/grep -Fqx 'phase=FAILED_LOCAL_TLS_NONE_RESTORED' "$runtime_state" || \
		fail 'unexpected retained runtime phase'
	retained_run_dir=$(/usr/bin/awk -F= '$1 == "runtime_run_dir" { print $2; exit }' "$runtime_state")
	case "$retained_run_dir" in
	/tmp/slurm-smd407-mac-tls-runtime-run-*) ;;
	*) fail 'invalid retained runtime run directory' ;;
	esac
	runtime_state_hash=$(file_hash "$runtime_state")
fi
initial_pid=$(managed_slurmd_pid) || fail 'launchd slurmd identity mismatch'
verify_cluster before || fail 'cluster preflight failed'

if [ "$mode" = preflight ]; then
	success=1
	/usr/bin/printf 'SMD407_MAC_CERTGEN_INSTALL_PREFLIGHT_PASS old=%s candidate=%s slurmd_pid=%s tls=tls/none nodes=IDLE queue=EMPTY run_dir=%s\n' \
		"$expected_old_hash" "$expected_new_hash" "$initial_pid" "$run_dir"
	exit 0
fi

/bin/mkdir "$backup_dir" || fail 'cannot create backup directory'
/bin/chmod 0700 "$backup_dir" || fail 'cannot protect backup directory'
/bin/cp -p "$plugin" "${backup_dir}/certgen_script.so.before" || fail 'cannot back up plugin'
/usr/bin/shasum -a 256 "${backup_dir}/certgen_script.so.before" \
	>"${backup_dir}/before.sha256" || fail 'cannot hash backup'
[ "$(file_hash "${backup_dir}/certgen_script.so.before")" = "$expected_old_hash" ] || \
	fail 'backup hash mismatch'
atomic_install "$candidate" "$plugin" "$plugin" || fail 'cannot install candidate plugin'
mutation=1
[ "$(file_hash "$plugin")" = "$expected_new_hash" ] || fail 'installed candidate hash mismatch'
[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$plugin")" = root:wheel:755 ] || \
	fail 'installed candidate metadata mismatch'
[ "$(file_hash "$slurm_conf")" = "$expected_config_hash" ] || fail 'production config changed'
[ "$runtime_state_hash" = ABSENT ] || \
	[ "$(file_hash "$runtime_state")" = "$runtime_state_hash" ] || fail 'retained runtime state changed'
[ "$(managed_slurmd_pid)" = "$initial_pid" ] || fail 'slurmd PID changed without restart'
verify_cluster after || fail 'cluster post-install verification failed'
{
	/usr/bin/printf 'host=PC-210\n'
	/usr/bin/printf 'old_hash=%s\n' "$expected_old_hash"
	/usr/bin/printf 'new_hash=%s\n' "$expected_new_hash"
	/usr/bin/printf 'slurmd_pid=%s\n' "$initial_pid"
	/usr/bin/printf 'backup_dir=%s\n' "$backup_dir"
} >"${backup_dir}/install-state.env" || fail 'cannot write install state'
/bin/chmod 0600 "${backup_dir}/before.sha256" "${backup_dir}/install-state.env" || \
	fail 'cannot protect backup metadata'
success=1
/usr/bin/printf 'SMD407_MAC_CERTGEN_PRODUCTION_INSTALL_PASS old=%s new=%s backup=%s slurmd_pid_unchanged=%s tls=tls/none retained_runtime_state=%s nodes=IDLE queue=EMPTY run_dir=%s\n' \
	"$expected_old_hash" "$expected_new_hash" "$backup_dir" "$initial_pid" \
	"$runtime_state_hash" "$run_dir"
