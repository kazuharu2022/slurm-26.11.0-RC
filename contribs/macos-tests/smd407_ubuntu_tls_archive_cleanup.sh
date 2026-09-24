#!/bin/sh

set -u

mode=${1:-}
case "$mode" in
preflight|stage|archive) ;;
*) printf 'usage: %s preflight|stage|archive\n' "$0" >&2; exit 64 ;;
esac
if [ "$mode" = stage ] && [ "${SMD407_TLS_ARCHIVE_STAGE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_TLS_ARCHIVE_STAGE_CONFIRMED=YES after approving non-destructive root-only archival' >&2
	exit 64
fi
if [ "$mode" = archive ] && { \
	[ "${SMD407_TLS_ARCHIVE_CLEANUP_CONFIRMED:-}" != YES ] || \
	[ "${SMD407_MAC_TLS_ARCHIVED:-}" != YES ]; }; then
	printf '%s\n' \
		'error: set SMD407_TLS_ARCHIVE_CLEANUP_CONFIRMED=YES and SMD407_MAC_TLS_ARCHIVED=YES after the Mac archive marker' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmdbd_conf=${prefix}/etc/slurmdbd.conf
gres_conf=${prefix}/etc/gres.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
sacctmgr=${prefix}/bin/sacctmgr
plugin=${prefix}/lib/slurm/tls_s2n.so
certgen_plugin=${prefix}/lib/slurm/certgen_script.so
s2n_prefix=${prefix}/lib/slurm-s2n-1.7.9
ca=${prefix}/etc/ca_cert.pem
ctld_cert=${prefix}/etc/ctld_cert.pem
ctld_key=${prefix}/etc/ctld_cert_key.pem
dbd_cert=${prefix}/etc/dbd_cert.pem
dbd_key=${prefix}/etc/dbd_cert_key.pem
slurmd_cert=${prefix}/etc/slurmd_cert.pem
slurmd_key=${prefix}/etc/slurmd_cert_key.pem
inactive_state=${prefix}/.smd407-ubuntu-tls-inactive.env
runtime_state=${prefix}/.smd407-ubuntu-tls-runtime.env
test_user=testuser
test_uid=3001
test_gid=3001
plugin_hash=fac2507c6c5070c47c78959a005b2e861632c9ff837601353a178570d72808a1
certgen_plugin_hash=3539895a90a3bff3770ab2b301460a6e3d140dd9e1fb4209b28783529347ff14
libs2n_hash=7ca8f397d81e31b2dfe47229e72200115b24716b63f46a354c13b9e2a1ccfd70
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-ubuntu-tls-archive-${mode}-${run_stamp}
archive_dir=${prefix}/.smd407-tls-archive-${run_stamp}
archive_artifacts=${archive_dir}/artifacts
archive_certificates=${archive_dir}/certificates
archive_states=${archive_dir}/states
smoke_output=/tmp/slurm-smd407-final-tls-none-smoke-${run_stamp}
success=0
archive_copied=0
active_removed=0
active_job=
final_job=
initial_pids=

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

state_value()
{
	key=$1
	file=$2
	awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "$file"
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

wait_node_idle()
{
	label=$1
	node=$2
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$scontrol" show node "$node" >"${run_dir}/${label}-${node}.txt" 2>/dev/null || true
		state=$(node_field State "${run_dir}/${label}-${node}.txt")
		[ "$state" = IDLE ] && return 0
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_mixed_accounting()
{
	job=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$sacct" -j "$job" -n -P --format=JobIDRaw,State,ExitCode,NodeList \
			>"$file" 2>/dev/null || true
		if awk -F '|' -v job="$job" '
		$1 == job && $2 == "COMPLETED" && $3 == "0:0" && $4 == "PC-210,ubuntu" { job_ok = 1 }
		$1 == job ".0" && $2 == "COMPLETED" && $3 == "0:0" && $4 == "PC-210,ubuntu" { step_ok = 1 }
		END { exit !(job_ok && step_ok) }
		' "$file"; then
			return 0
		fi
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

restore_from_archive()
{
	[ "$archive_copied" -eq 1 ] || return 0
	[ -e "$plugin" ] || cp -p "${archive_artifacts}/tls_s2n.so" "$plugin" || return 1
	[ -e "$s2n_prefix" ] || cp -pR "${archive_artifacts}/slurm-s2n-1.7.9" \
		"${prefix}/lib/" || return 1
	for certificate in "$ca" "$ctld_cert" "$ctld_key" "$dbd_cert" "$dbd_key" \
		"$slurmd_cert" "$slurmd_key"; do
		certificate_name=${certificate##*/}
		[ -e "$certificate" ] || cp -p "${archive_certificates}/${certificate_name}" \
			"$certificate" || return 1
	done
	[ -e "$inactive_state" ] || cp -p "${archive_states}/${inactive_state##*/}" \
		"$inactive_state" || return 1
	return 0
}

cleanup_on_exit()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ -n "$active_job" ]; then
		"$scancel" "$active_job" >/dev/null 2>&1 || true
	fi
	if [ "$success" -ne 1 ] && [ "$active_removed" -eq 1 ]; then
		if restore_from_archive; then
			printf 'recovery: active Ubuntu TLS artifacts restored from archive=%s\n' \
				"$archive_dir" >&2
		else
			printf 'fatal recovery: inspect archive=%s and run_dir=%s\n' \
				"$archive_dir" "$run_dir" >&2
		fi
	fi
	exit "$rc"
}

trap cleanup_on_exit EXIT HUP INT TERM

[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Linux ] || fail 'this driver is for Ubuntu'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
for command_name in awk chmod chown cmp cp date env grep id mkdir rm sha256sum \
	sleep stat sudo systemctl; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done
for required in "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
	"$scontrol" "$squeue" "$srun" "$scancel" "$sacct" "$sacctmgr" "$plugin" \
	"$certgen_plugin" "$s2n_prefix/lib/libs2n.so" "$ca" "$ctld_cert" "$ctld_key" \
	"$dbd_cert" "$dbd_key" "$slurmd_cert" "$slurmd_key" "$inactive_state"; do
	[ -e "$required" ] || fail "missing required input=$required"
done
[ ! -e "$runtime_state" ] || fail 'Ubuntu runtime state still exists'
[ "$(id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'
[ "$(stat -c '%U:%G:%a' "$inactive_state")" = root:root:600 ] || \
	fail 'inactive state metadata mismatch'
[ "$(state_value phase "$inactive_state")" = UBUNTU_INACTIVE_INSTALLED ] || \
	fail 'inactive state phase mismatch'
[ "$(sha256sum "$plugin" | awk '{print $1}')" = "$plugin_hash" ] || \
	fail 'TLS plugin hash mismatch'
[ "$(sha256sum "$certgen_plugin" | awk '{print $1}')" = "$certgen_plugin_hash" ] || \
	fail 'certgen plugin hash mismatch'
[ "$(sha256sum "$s2n_prefix/lib/libs2n.so" | awk '{print $1}')" = "$libs2n_hash" ] || \
	fail 'libs2n hash mismatch'

umask 077
mkdir "$run_dir" || fail 'cannot create run directory'
export SLURM_CONF="$slurm_conf"
"$scontrol" show config >"${run_dir}/active-config-before.txt" || fail 'cannot read config'
grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' \
	"${run_dir}/active-config-before.txt" || fail 'active TLS is not tls/none'
"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
"$sacctmgr" ping >"${run_dir}/database-before.txt" 2>&1 || fail 'database ping failed'
for service in slurmdbd slurmctld slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "service=$service is not active"
done
initial_pids="$(systemctl show -p MainPID --value slurmdbd),$(systemctl show -p MainPID --value slurmctld),$(systemctl show -p MainPID --value slurmd)"
for node in ubuntu PC-210; do wait_node_idle before "$node" || fail "node=$node is not IDLE"; done
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-before.txt" || fail 'cannot read queue'
[ ! -s "${run_dir}/queue-before.txt" ] || fail 'queue is not empty'
sha256sum "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" "$certgen_plugin" \
	>"${run_dir}/protected-before.sha256" || fail 'cannot hash protected production files'
printf 'SMD407_UBUNTU_TLS_ARCHIVE_PREFLIGHT_COMPLETE tls=tls/none services=ACTIVE service_pids=%s nodes=IDLE queue=EMPTY mode=%s run_dir=%s\n' \
	"$initial_pids" "$mode" "$run_dir"

if [ "$mode" = preflight ]; then
	success=1
	exit 0
fi

[ ! -e "$archive_dir" ] || fail "archive already exists=$archive_dir"
mkdir "$archive_dir" "$archive_artifacts" "$archive_certificates" \
	"$archive_states" || fail 'cannot create archive directories'
chmod 0700 "$archive_dir" "$archive_artifacts" "$archive_certificates" \
	"$archive_states" || fail 'cannot protect archive directories'
chown -R root:root "$archive_dir" || fail 'cannot set archive ownership'
cp -p "$plugin" "${archive_artifacts}/tls_s2n.so" || fail 'cannot archive TLS plugin'
cp -pR "$s2n_prefix" "$archive_artifacts/" || fail 'cannot archive s2n prefix'
cp -p "$ca" "$ctld_cert" "$ctld_key" "$dbd_cert" "$dbd_key" \
	"$slurmd_cert" "$slurmd_key" "$archive_certificates/" || \
	fail 'cannot archive certificates'
cp -p "$inactive_state" "$archive_states/" || fail 'cannot archive inactive state'
{
	printf 'archive_created=%s\n' "$run_stamp"
	printf 'classification=TLS_RUNTIME_PASS_ACTIVE_ARTIFACTS_RETIRED\n'
	printf 'source_prefix=%s\n' "$prefix"
} >"${archive_dir}/archive.env" || fail 'cannot write archive marker'
chmod 0600 "${archive_dir}/archive.env" || fail 'cannot protect archive marker'
sha256sum "$plugin" "$s2n_prefix/lib/libs2n.so" "$ca" "$ctld_cert" "$ctld_key" \
	"$dbd_cert" "$dbd_key" "$slurmd_cert" "$slurmd_key" "$inactive_state" \
	>"${archive_dir}/source.sha256" || fail 'cannot write source hash manifest'
sha256sum "${archive_artifacts}/tls_s2n.so" \
	"${archive_artifacts}/slurm-s2n-1.7.9/lib/libs2n.so" \
	"${archive_certificates}/ca_cert.pem" "${archive_certificates}/ctld_cert.pem" \
	"${archive_certificates}/ctld_cert_key.pem" "${archive_certificates}/dbd_cert.pem" \
	"${archive_certificates}/dbd_cert_key.pem" "${archive_certificates}/slurmd_cert.pem" \
	"${archive_certificates}/slurmd_cert_key.pem" "${archive_states}/${inactive_state##*/}" \
	>"${archive_dir}/archive.sha256" || fail 'cannot write archive hash manifest'
archive_copied=1
cmp -s "$plugin" "${archive_artifacts}/tls_s2n.so" || fail 'archived TLS plugin bytes mismatch'
cmp -s "$s2n_prefix/lib/libs2n.so" \
	"${archive_artifacts}/slurm-s2n-1.7.9/lib/libs2n.so" || \
	fail 'archived libs2n bytes mismatch'
for source_file in "$ca" "$ctld_cert" "$ctld_key" "$dbd_cert" "$dbd_key" \
	"$slurmd_cert" "$slurmd_key"; do
	source_name=${source_file##*/}
	cmp -s "$source_file" "${archive_certificates}/${source_name}" || \
		fail "archived certificate bytes mismatch=$source_name"
done
cmp -s "$inactive_state" "${archive_states}/${inactive_state##*/}" || \
	fail 'archived inactive state bytes mismatch'
[ "$(sha256sum "${archive_artifacts}/tls_s2n.so" | awk '{print $1}')" = \
	"$plugin_hash" ] || fail 'archived TLS plugin hash mismatch'
[ "$(sha256sum "${archive_artifacts}/slurm-s2n-1.7.9/lib/libs2n.so" | \
	awk '{print $1}')" = "$libs2n_hash" ] || fail 'archived libs2n hash mismatch'

if [ "$mode" = stage ]; then
	success=1
	printf 'SMD407_UBUNTU_TLS_ARCHIVE_STAGED active_artifacts=UNCHANGED certificates=COPIED state=COPIED hashes=PASS archive=%s run_dir=%s\n' \
		"$archive_dir" "$run_dir"
	exit 0
fi

rm -f "$plugin" "$ca" "$ctld_cert" "$ctld_key" "$dbd_cert" "$dbd_key" \
	"$slurmd_cert" "$slurmd_key" "$inactive_state"
rm -rf "$s2n_prefix"
active_removed=1
for removed in "$plugin" "$s2n_prefix" "$ca" "$ctld_cert" "$ctld_key" \
	"$dbd_cert" "$dbd_key" "$slurmd_cert" "$slurmd_key" "$inactive_state"; do
	[ ! -e "$removed" ] || fail "active cleanup target remains=$removed"
done

mkdir "$smoke_output" || fail 'cannot create final smoke output directory'
chown "$test_uid:$test_gid" "$smoke_output" || fail 'cannot chown final smoke output'
chmod 0700 "$smoke_output" || fail 'cannot protect final smoke output'
cd /tmp || fail 'cannot enter /tmp'
sudo -u "$test_user" -H env SLURM_CONF="$slurm_conf" \
	"$srun" --job-name=smd407-final-tls-none --partition=smd402 --nodes=2 --ntasks=2 \
	--ntasks-per-node=1 --cpus-per-task=1 --mem=64M --time=00:01:00 --chdir=/tmp --label \
	/bin/sh -c 'printf "%s|%s|%s\n" "$SLURM_JOB_ID" "$SLURM_PROCID" "$(/usr/bin/uname -m)"' \
	>"${smoke_output}/mixed.out" 2>"${smoke_output}/mixed.err" || \
	fail 'final TLS-none mixed smoke failed'
final_job=$(awk -F '|' 'NR == 1 { sub(/^[0-9]+:[[:space:]]*/, "", $1); print $1; exit }' \
	"${smoke_output}/mixed.out")
case "$final_job" in ''|*[!0-9]*) fail "invalid final smoke job id=$final_job" ;; esac
active_job=$final_job
awk -F '|' -v job="$final_job" '
{
	sub(/^[0-9]+:[[:space:]]*/, "", $1)
	if ($1 != job) next
	if ($2 == 0 && $3 == "arm64") arm = 1
	if ($2 == 1 && $3 == "x86_64") x86 = 1
}
END { exit !(arm && x86) }
' "${smoke_output}/mixed.out" || fail 'final mixed smoke rank output mismatch'
[ ! -s "${smoke_output}/mixed.err" ] || fail 'final mixed smoke stderr is not empty'
wait_mixed_accounting "$final_job" "${run_dir}/final-accounting.txt" || \
	fail 'final mixed smoke accounting mismatch'
active_job=

"$scontrol" show config >"${run_dir}/active-config-after.txt" || fail 'cannot read final config'
grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' \
	"${run_dir}/active-config-after.txt" || fail 'final active TLS is not tls/none'
"$scontrol" ping >"${run_dir}/controller-after.txt" 2>&1 || fail 'final controller ping failed'
"$sacctmgr" ping >"${run_dir}/database-after.txt" 2>&1 || fail 'final database ping failed'
for service in slurmdbd slurmctld slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "final service=$service is not active"
done
final_pids="$(systemctl show -p MainPID --value slurmdbd),$(systemctl show -p MainPID --value slurmctld),$(systemctl show -p MainPID --value slurmd)"
[ "$final_pids" = "$initial_pids" ] || fail 'Ubuntu service PIDs changed during archive cleanup'
for node in ubuntu PC-210; do wait_node_idle after "$node" || fail "final node=$node is not IDLE"; done
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-after.txt" || fail 'cannot read final queue'
[ ! -s "${run_dir}/queue-after.txt" ] || fail 'final queue is not empty'
sha256sum "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" "$certgen_plugin" \
	>"${run_dir}/protected-after.sha256" || fail 'cannot hash final protected production files'
cmp -s "${run_dir}/protected-before.sha256" "${run_dir}/protected-after.sha256" || \
	fail 'protected production files changed'

success=1
printf 'SMD407_UBUNTU_TLS_ARCHIVE_COMPLETE tls=tls/none active_artifacts=ABSENT certificates=ARCHIVED_RETIRED state=ARCHIVED services=ACTIVE service_pids=%s final_smoke_job=%s accounting=COMPLETED_0_0 ranks=ARM64_X86_64 nodes=IDLE queue=EMPTY archive=%s run_dir=%s\n' \
	"$initial_pids" "$final_job" "$archive_dir" "$run_dir"
