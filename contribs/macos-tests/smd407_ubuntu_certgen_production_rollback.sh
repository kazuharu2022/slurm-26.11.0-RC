#!/bin/sh

set -u

mode=${1:-}
backup_plugin=${2:-}
case "$mode" in
preflight|rollback) ;;
*) printf 'usage: %s preflight|rollback /absolute/path/to/certgen_script.so.before\n' "$0" >&2; exit 64 ;;
esac
case "$backup_plugin" in
/*) ;;
*) printf '%s\n' 'error: backup plugin path must be absolute' >&2; exit 64 ;;
esac
if [ "$mode" = rollback ] && \
	[ "${SMD407_CERTGEN_PRODUCTION_ROLLBACK_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_CERTGEN_PRODUCTION_ROLLBACK_CONFIRMED=YES after approving rollback' >&2
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
expected_bad_hash=373b43142b029d828d752263209d8610393d97fad2c75e1752f306f960d9af45
expected_slurm_conf_hash=56ab879e4ae3a845950e15d2665f33543c5108ecae9b2008ef886b600eff169f
expected_slurmdbd_conf_hash=698cfd0d6b4bce6c1a68b4f25f999506de7a29ff4c368ba13e42e1b872ad3f29
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-ubuntu-certgen-rollback-${mode}-${run_stamp}

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
	tmp_file=${target_file}.smd407-rollback.$$
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

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(uname -s)" = Linux ] || fail 'this rollback is for Linux'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
for required in "$backup_plugin" "$plugin" "$slurm_conf" "$slurmdbd_conf" \
	"$scontrol" "$squeue" "$inactive_state"; do
	[ -e "$required" ] || fail "missing $required"
done

mkdir "$run_dir" || fail 'cannot create run directory'
chmod 0755 "$run_dir" || fail 'cannot make run directory readable'
file "$backup_plugin" >"${run_dir}/backup-file.txt" || fail 'cannot inspect backup plugin'
grep -Eq 'ELF 64-bit LSB shared object, x86-64' "${run_dir}/backup-file.txt" || \
	fail 'backup plugin architecture mismatch'
[ "$(file_hash "$backup_plugin")" = "$expected_old_hash" ] || fail 'backup plugin hash mismatch'
[ "$(file_hash "$plugin")" = "$expected_bad_hash" ] || fail 'current plugin is not the failed candidate'
[ "$(file_hash "$slurm_conf")" = "$expected_slurm_conf_hash" ] || fail 'slurm.conf hash mismatch'
[ "$(file_hash "$slurmdbd_conf")" = "$expected_slurmdbd_conf_hash" ] || \
	fail 'slurmdbd.conf hash mismatch'
[ "$(stat -c '%U:%G:%a' "$plugin")" = slurm:slurm:755 ] || \
	fail 'production plugin metadata mismatch'
[ "$(stat -c '%U:%G:%a' "$backup_plugin")" = slurm:slurm:755 ] || \
	fail 'backup plugin metadata mismatch'
grep -Fqx 'phase=UBUNTU_INACTIVE_INSTALLED' "$inactive_state" || \
	fail 'unexpected inactive state phase'
[ ! -e "${prefix}/.smd407-ubuntu-tls-runtime.env" ] || fail 'Ubuntu TLS runtime state still exists'
systemctl is-active slurmdbd slurmctld slurmd >"${run_dir}/services-before.txt" || \
	fail 'production service is not active'
systemctl show -p MainPID slurmdbd slurmctld slurmd >"${run_dir}/pids-before.txt" || \
	fail 'cannot read production PIDs'
verify_cluster before || fail 'cluster preflight failed'

if [ "$mode" = preflight ]; then
	printf 'SMD407_UBUNTU_CERTGEN_ROLLBACK_PREFLIGHT_PASS current=%s restore=%s tls=tls/none services=ACTIVE nodes=IDLE queue=EMPTY run_dir=%s\n' \
		"$expected_bad_hash" "$expected_old_hash" "$run_dir"
	exit 0
fi

forensic_copy="$(dirname "$backup_plugin")/certgen_script.so.failed-candidate-${run_stamp}"
cp -p "$plugin" "$forensic_copy" || fail 'cannot preserve failed candidate'
[ "$(file_hash "$forensic_copy")" = "$expected_bad_hash" ] || fail 'failed candidate copy hash mismatch'
atomic_install "$backup_plugin" "$plugin" "$plugin" || fail 'cannot restore backup plugin'
[ "$(file_hash "$plugin")" = "$expected_old_hash" ] || fail 'restored plugin hash mismatch'
[ "$(stat -c '%U:%G:%a' "$plugin")" = slurm:slurm:755 ] || \
	fail 'restored plugin metadata mismatch'
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
verify_cluster after || fail 'cluster post-rollback verification failed'
sha256sum "$plugin" "$backup_plugin" "$forensic_copy" >"${run_dir}/plugin-hashes.txt" || \
	fail 'cannot record plugin hashes'
find "$run_dir" -type f -exec chmod a+r {} \; >/dev/null 2>&1 || true
printf 'SMD407_UBUNTU_CERTGEN_PRODUCTION_ROLLBACK_PASS failed=%s restored=%s forensic=%s services_pids_unchanged=PASS tls=tls/none nodes=IDLE queue=EMPTY run_dir=%s\n' \
	"$expected_bad_hash" "$expected_old_hash" "$forensic_copy" "$run_dir"
