#!/bin/sh

set -u

mode=${1:-}
backup_plugin=${2:-}
case "$mode" in
preflight|rollback) ;;
*) /usr/bin/printf 'usage: %s preflight|rollback /absolute/path/to/certgen_script.so.before\n' "$0" >&2; exit 64 ;;
esac
case "$backup_plugin" in
/*) ;;
*) /usr/bin/printf '%s\n' 'error: backup plugin path must be absolute' >&2; exit 64 ;;
esac
if [ "$mode" = rollback ] && \
	[ "${SMD407_CERTGEN_PRODUCTION_ROLLBACK_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD407_CERTGEN_PRODUCTION_ROLLBACK_CONFIRMED=YES after approving rollback' >&2
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
expected_bad_hash=aaa543b24d2b776b6493869d46bf56dda0afb3e27e1f0d5b0842b4555c1bafe3
expected_config_hash=9c7021e4c794fd9ec4e76af0b7cd5c574d1cd058b9ba9c60c849103f0a7577a2
service_target=system/org.schedmd.slurmd
pid_file=/var/run/slurmd.pid
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-mac-certgen-rollback-${mode}-${run_stamp}
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
	tmp_file=${target_file}.smd407-rollback.$$
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

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this rollback is for macOS'
[ "$(/bin/hostname -s)" = PC-210 ] || fail "unexpected host=$(/bin/hostname -s)"
for required in "$backup_plugin" "$plugin" "$slurm_conf" "$scontrol" "$squeue" \
	"$inactive_state" "$pid_file"; do
	[ -e "$required" ] || fail "missing $required"
done

/bin/mkdir "$run_dir" || fail 'cannot create run directory'
/bin/chmod 0755 "$run_dir" || fail 'cannot make run directory readable'
/usr/bin/file "$backup_plugin" >"${run_dir}/backup-file.txt" || fail 'cannot inspect backup plugin'
/usr/bin/grep -Eq 'Mach-O 64-bit bundle arm64' "${run_dir}/backup-file.txt" || \
	fail 'backup plugin architecture mismatch'
[ "$(file_hash "$backup_plugin")" = "$expected_old_hash" ] || fail 'backup plugin hash mismatch'
[ "$(file_hash "$plugin")" = "$expected_bad_hash" ] || fail 'current plugin is not the failed candidate'
[ "$(file_hash "$slurm_conf")" = "$expected_config_hash" ] || fail 'production config hash mismatch'
[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$plugin")" = root:wheel:755 ] || \
	fail 'production plugin metadata mismatch'
[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$backup_plugin")" = root:wheel:755 ] || \
	fail 'backup plugin metadata mismatch'
/usr/bin/grep -Fqx 'phase=MAC_INACTIVE_INSTALLED' "$inactive_state" || \
	fail 'unexpected inactive state phase'
if [ -e "$runtime_state" ]; then
	[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$runtime_state")" = root:wheel:600 ] || \
		fail 'retained runtime state metadata mismatch'
	/usr/bin/grep -Fqx 'phase=FAILED_LOCAL_TLS_NONE_RESTORED' "$runtime_state" || \
		fail 'unexpected retained runtime phase'
	runtime_state_hash=$(file_hash "$runtime_state")
fi
initial_pid=$(managed_slurmd_pid) || fail 'launchd slurmd identity mismatch'
verify_cluster before || fail 'cluster preflight failed'

if [ "$mode" = preflight ]; then
	/usr/bin/printf 'SMD407_MAC_CERTGEN_ROLLBACK_PREFLIGHT_PASS current=%s restore=%s slurmd_pid=%s tls=tls/none nodes=IDLE queue=EMPTY run_dir=%s\n' \
		"$expected_bad_hash" "$expected_old_hash" "$initial_pid" "$run_dir"
	exit 0
fi

forensic_copy="$(/usr/bin/dirname "$backup_plugin")/certgen_script.so.failed-candidate-${run_stamp}"
/bin/cp -p "$plugin" "$forensic_copy" || fail 'cannot preserve failed candidate'
[ "$(file_hash "$forensic_copy")" = "$expected_bad_hash" ] || fail 'failed candidate copy hash mismatch'
atomic_install "$backup_plugin" "$plugin" "$plugin" || fail 'cannot restore backup plugin'
[ "$(file_hash "$plugin")" = "$expected_old_hash" ] || fail 'restored plugin hash mismatch'
[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$plugin")" = root:wheel:755 ] || \
	fail 'restored plugin metadata mismatch'
[ "$(file_hash "$slurm_conf")" = "$expected_config_hash" ] || fail 'production config changed'
[ "$runtime_state_hash" = ABSENT ] || \
	[ "$(file_hash "$runtime_state")" = "$runtime_state_hash" ] || fail 'retained runtime state changed'
[ "$(managed_slurmd_pid)" = "$initial_pid" ] || fail 'slurmd PID changed without restart'
verify_cluster after || fail 'cluster post-rollback verification failed'
/usr/bin/shasum -a 256 "$plugin" "$backup_plugin" "$forensic_copy" \
	>"${run_dir}/plugin-hashes.txt" || fail 'cannot record plugin hashes'
/usr/bin/find "$run_dir" -type f -exec /bin/chmod a+r {} \; >/dev/null 2>&1 || true
/usr/bin/printf 'SMD407_MAC_CERTGEN_PRODUCTION_ROLLBACK_PASS failed=%s restored=%s forensic=%s slurmd_pid_unchanged=%s tls=tls/none retained_runtime_state=%s nodes=IDLE queue=EMPTY run_dir=%s\n' \
	"$expected_bad_hash" "$expected_old_hash" "$forensic_copy" "$initial_pid" \
	"$runtime_state_hash" "$run_dir"
