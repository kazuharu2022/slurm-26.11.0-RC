#!/bin/sh

set -u

mode=${1:-}
candidate=${2:-}
case "$mode" in
preflight|install) ;;
*) printf 'usage: %s preflight|install /absolute/path/to/certgen_script.so\n' "$0" >&2; exit 64 ;;
esac
case "$candidate" in
/*) ;;
*) printf '%s\n' 'error: candidate path must be absolute' >&2; exit 64 ;;
esac
if [ "$mode" = install ] && [ "${SMD407_CERTGEN_PRODUCTION_INSTALL_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_CERTGEN_PRODUCTION_INSTALL_CONFIRMED=YES after approving the production plugin install' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
plugin=${prefix}/lib/slurm/certgen_script.so
slurm_conf=${prefix}/etc/slurm.conf
slurmdbd_conf=${prefix}/etc/slurmdbd.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
inactive_state=${prefix}/.smd407-ubuntu-tls-inactive.env
expected_old_hash=55a755c4fd2bcc58a28f31188a0ac10fe2fb0345a4bbd8ea86ea31da2290c56b
expected_new_hash=3539895a90a3bff3770ab2b301460a6e3d140dd9e1fb4209b28783529347ff14
expected_slurm_conf_hash=56ab879e4ae3a845950e15d2665f33543c5108ecae9b2008ef886b600eff169f
expected_slurmdbd_conf_hash=698cfd0d6b4bce6c1a68b4f25f999506de7a29ff4c368ba13e42e1b872ad3f29
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-ubuntu-certgen-install-${mode}-${run_stamp}
backup_dir=${prefix}/.smd407-certgen-backup-${run_stamp}
mutation=0
success=0

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

file_hash()
{
	sha256sum "$1" | awk '{print $1}'
}

node_field()
{
	field=$1
	file=$2
	awk -v key="${field}=" '
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

atomic_install()
{
	source_file=$1
	target_file=$2
	reference_file=$3
	tmp_file=${target_file}.smd407-certgen.$$
	uid=$(stat -c '%u' "$reference_file") || return 1
	gid=$(stat -c '%g' "$reference_file") || return 1
	file_mode=$(stat -c '%a' "$reference_file") || return 1
	if ! install -o "$uid" -g "$gid" -m "$file_mode" \
		"$source_file" "$tmp_file"; then
		rm -f "$tmp_file"
		return 1
	fi
	if ! mv -f "$tmp_file" "$target_file"; then
		rm -f "$tmp_file"
		return 1
	fi
}

verify_cluster()
{
	label=$1
	"$scontrol" ping >"${run_dir}/${label}-controller.txt" 2>&1 || return 1
	"$scontrol" show config >"${run_dir}/${label}-config.txt" 2>&1 || return 1
	grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' \
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
			printf 'recovery: original Ubuntu certgen plugin restored backup=%s\n' \
				"$backup_dir" >&2
		else
			printf 'fatal recovery: Ubuntu certgen plugin restore failed backup=%s\n' \
				"$backup_dir" >&2
		fi
	fi
	find "$run_dir" -type f -exec chmod a+r {} \; >/dev/null 2>&1 || true
	exit "$rc"
}

trap cleanup_on_exit EXIT HUP INT TERM

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(uname -s)" = Linux ] || fail 'this installer is for Linux'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
for required in "$candidate" "$plugin" "$slurm_conf" "$slurmdbd_conf" \
	"$scontrol" "$squeue" "$inactive_state"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_name in awk chmod cmp cp date file find grep hostname id install mkdir \
	mv rm sha256sum stat systemctl uname; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done

mkdir "$run_dir" || fail 'cannot create run directory'
chmod 0755 "$run_dir" || fail 'cannot make run directory readable'
file "$candidate" >"${run_dir}/candidate-file.txt" || fail 'cannot inspect candidate'
grep -Eq 'ELF 64-bit LSB shared object, x86-64' "${run_dir}/candidate-file.txt" || \
	fail 'candidate architecture mismatch'
[ "$(file_hash "$candidate")" = "$expected_new_hash" ] || fail 'candidate hash mismatch'
[ "$(file_hash "$plugin")" = "$expected_old_hash" ] || fail 'production plugin hash mismatch'
[ "$(file_hash "$slurm_conf")" = "$expected_slurm_conf_hash" ] || fail 'slurm.conf hash mismatch'
[ "$(file_hash "$slurmdbd_conf")" = "$expected_slurmdbd_conf_hash" ] || \
	fail 'slurmdbd.conf hash mismatch'
[ "$(stat -c '%U:%G:%a' "$plugin")" = slurm:slurm:755 ] || \
	fail 'production plugin metadata mismatch'
[ "$(stat -c '%U:%G:%a' "$inactive_state")" = root:root:600 ] || \
	fail 'inactive state metadata mismatch'
grep -Fqx 'phase=UBUNTU_INACTIVE_INSTALLED' "$inactive_state" || \
	fail 'unexpected inactive state phase'
[ ! -e "${prefix}/.smd407-ubuntu-tls-runtime.env" ] || fail 'Ubuntu TLS runtime state already exists'
systemctl is-active slurmdbd slurmctld slurmd >"${run_dir}/services-before.txt" || \
	fail 'production service is not active'
systemctl show -p MainPID slurmdbd slurmctld slurmd >"${run_dir}/pids-before.txt" || \
	fail 'cannot read production PIDs'
verify_cluster before || fail 'cluster preflight failed'

if [ "$mode" = preflight ]; then
	success=1
	printf 'SMD407_UBUNTU_CERTGEN_INSTALL_PREFLIGHT_PASS old=%s candidate=%s tls=tls/none services=ACTIVE nodes=IDLE queue=EMPTY run_dir=%s\n' \
		"$expected_old_hash" "$expected_new_hash" "$run_dir"
	exit 0
fi

mkdir "$backup_dir" || fail 'cannot create backup directory'
chmod 0700 "$backup_dir" || fail 'cannot protect backup directory'
cp -p "$plugin" "${backup_dir}/certgen_script.so.before" || fail 'cannot back up plugin'
sha256sum "${backup_dir}/certgen_script.so.before" >"${backup_dir}/before.sha256" || \
	fail 'cannot hash backup'
[ "$(file_hash "${backup_dir}/certgen_script.so.before")" = "$expected_old_hash" ] || \
	fail 'backup hash mismatch'
atomic_install "$candidate" "$plugin" "$plugin" || fail 'cannot install candidate plugin'
mutation=1
[ "$(file_hash "$plugin")" = "$expected_new_hash" ] || fail 'installed candidate hash mismatch'
[ "$(stat -c '%U:%G:%a' "$plugin")" = slurm:slurm:755 ] || \
	fail 'installed candidate metadata mismatch'
[ "$(file_hash "$slurm_conf")" = "$expected_slurm_conf_hash" ] || fail 'slurm.conf changed'
[ "$(file_hash "$slurmdbd_conf")" = "$expected_slurmdbd_conf_hash" ] || \
	fail 'slurmdbd.conf changed'
systemctl is-active slurmdbd slurmctld slurmd >"${run_dir}/services-after.txt" || \
	fail 'production service stopped'
cmp -s "${run_dir}/services-before.txt" "${run_dir}/services-after.txt" || \
	fail 'production service state changed'
systemctl show -p MainPID slurmdbd slurmctld slurmd >"${run_dir}/pids-after.txt" || \
	fail 'cannot reread production PIDs'
cmp -s "${run_dir}/pids-before.txt" "${run_dir}/pids-after.txt" || \
	fail 'production PID changed without restart'
verify_cluster after || fail 'cluster post-install verification failed'
{
	printf 'host=ubuntu2504\n'
	printf 'old_hash=%s\n' "$expected_old_hash"
	printf 'new_hash=%s\n' "$expected_new_hash"
	printf 'backup_dir=%s\n' "$backup_dir"
} >"${backup_dir}/install-state.env" || fail 'cannot write install state'
chmod 0600 "${backup_dir}/before.sha256" "${backup_dir}/install-state.env" || \
	fail 'cannot protect backup metadata'
success=1
printf 'SMD407_UBUNTU_CERTGEN_PRODUCTION_INSTALL_PASS old=%s new=%s backup=%s services_pids_unchanged=PASS tls=tls/none nodes=IDLE queue=EMPTY run_dir=%s\n' \
	"$expected_old_hash" "$expected_new_hash" "$backup_dir" "$run_dir"
