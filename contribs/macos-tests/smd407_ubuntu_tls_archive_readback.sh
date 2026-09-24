#!/bin/sh

set -u

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmdbd_conf=${prefix}/etc/slurmdbd.conf
gres_conf=${prefix}/etc/gres.conf
slurmd=${prefix}/sbin/slurmd
certgen_plugin=${prefix}/lib/slurm/certgen_script.so
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sacct=${prefix}/bin/sacct
sacctmgr=${prefix}/bin/sacctmgr
stage_archive=${prefix}/.smd407-tls-archive-20260923T150440
final_archive=${prefix}/.smd407-tls-archive-20260923T151505
smoke_output=/tmp/slurm-smd407-final-tls-none-smoke-20260923T151505
plugin_hash=fac2507c6c5070c47c78959a005b2e861632c9ff837601353a178570d72808a1
libs2n_hash=7ca8f397d81e31b2dfe47229e72200115b24716b63f46a354c13b9e2a1ccfd70
certgen_hash=3539895a90a3bff3770ab2b301460a6e3d140dd9e1fb4209b28783529347ff14
slurm_conf_hash=56ab879e4ae3a845950e15d2665f33543c5108ecae9b2008ef886b600eff169f
slurmdbd_conf_hash=698cfd0d6b4bce6c1a68b4f25f999506de7a29ff4c368ba13e42e1b872ad3f29
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-ubuntu-tls-archive-readback-${run_stamp}

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
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

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(uname -s)" = Linux ] || fail 'expected Linux'
[ "$(hostname -s)" = ubuntu2504 ] || fail 'unexpected host'
mkdir "$run_dir" || fail 'cannot create run directory'

for absent in \
	"${prefix}/lib/slurm/tls_s2n.so" \
	"${prefix}/lib/slurm-s2n-1.7.9" \
	"${prefix}/etc/ca_cert.pem" \
	"${prefix}/etc/ctld_cert.pem" \
	"${prefix}/etc/ctld_cert_key.pem" \
	"${prefix}/etc/dbd_cert.pem" \
	"${prefix}/etc/dbd_cert_key.pem" \
	"${prefix}/etc/slurmd_cert.pem" \
	"${prefix}/etc/slurmd_cert_key.pem" \
	"${prefix}/.smd407-ubuntu-tls-inactive.env" \
	"${prefix}/.smd407-ubuntu-tls-runtime.env"; do
	[ ! -e "$absent" ] || fail "active path remains=$absent"
done

for archive in "$stage_archive" "$final_archive"; do
	[ -d "$archive" ] || fail "archive missing=$archive"
	[ "$(stat -c '%U:%G:%a' "$archive")" = root:root:700 ] || \
		fail "archive metadata mismatch=$archive"
done
[ "$(sha256sum "${final_archive}/artifacts/tls_s2n.so" | awk '{print $1}')" = \
	"$plugin_hash" ] || fail 'archived plugin hash mismatch'
[ "$(sha256sum "${final_archive}/artifacts/slurm-s2n-1.7.9/lib/libs2n.so" | \
	awk '{print $1}')" = "$libs2n_hash" ] || fail 'archived libs2n hash mismatch'
[ "$(sha256sum "$certgen_plugin" | awk '{print $1}')" = "$certgen_hash" ] || \
	fail 'production certgen hash mismatch'
[ "$(sha256sum "$slurm_conf" | awk '{print $1}')" = "$slurm_conf_hash" ] || \
	fail 'production slurm.conf hash mismatch'
[ "$(sha256sum "$slurmdbd_conf" | awk '{print $1}')" = "$slurmdbd_conf_hash" ] || \
	fail 'production slurmdbd.conf hash mismatch'

export SLURM_CONF="$slurm_conf"
"$scontrol" show config >"${run_dir}/active-config.txt" || fail 'cannot read active config'
grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' \
	"${run_dir}/active-config.txt" || fail 'active TLS is not tls/none'
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
"$sacctmgr" ping >"${run_dir}/database.txt" 2>&1 || fail 'database ping failed'
for service in slurmdbd slurmctld slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "service=$service is not active"
done
pids="$(systemctl show -p MainPID --value slurmdbd),$(systemctl show -p MainPID --value slurmctld),$(systemctl show -p MainPID --value slurmd)"
[ "$pids" = 189104,189140,189203 ] || fail "service PID set changed=$pids"
for node in ubuntu PC-210; do
	"$scontrol" show node "$node" >"${run_dir}/${node}.txt" || fail "cannot read node=$node"
	[ "$(node_field State "${run_dir}/${node}.txt")" = IDLE ] || fail "node=$node is not IDLE"
	[ "$(node_field CPUAlloc "${run_dir}/${node}.txt")" = 0 ] || fail "node=$node CPUAlloc is not zero"
	[ "$(node_field AllocMem "${run_dir}/${node}.txt")" = 0 ] || fail "node=$node AllocMem is not zero"
done
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue.txt" || fail 'cannot read queue'
[ ! -s "${run_dir}/queue.txt" ] || fail 'queue is not empty'
"$sacct" -j 638,639 -n -P --format=JobIDRaw,State,ExitCode,NodeList \
	>"${run_dir}/accounting.txt" || fail 'cannot read accounting'
awk -F '|' '
$1 == "638" && $2 == "COMPLETED" && $3 == "0:0" && $4 == "PC-210" { j638 = 1 }
$1 == "638.batch" && $2 == "COMPLETED" && $3 == "0:0" && $4 == "PC-210" { b638 = 1 }
$1 == "639" && $2 == "COMPLETED" && $3 == "0:0" && $4 == "PC-210,ubuntu" { j639 = 1 }
$1 == "639.0" && $2 == "COMPLETED" && $3 == "0:0" && $4 == "PC-210,ubuntu" { s639 = 1 }
END { exit !(j638 && b638 && j639 && s639) }
' "${run_dir}/accounting.txt" || fail 'final accounting mismatch'
awk -F '|' '
{
	sub(/^[0-9]+:[[:space:]]*/, "", $1)
	if ($1 != 639) next
	if ($2 == 0 && $3 == "arm64") arm = 1
	if ($2 == 1 && $3 == "x86_64") x86 = 1
}
END { exit !(arm && x86) }
' "${smoke_output}/mixed.out" || fail 'Job 639 rank output mismatch'
[ ! -s "${smoke_output}/mixed.err" ] || fail 'Job 639 stderr is not empty'

sha256sum "${final_archive}/archive.env" "${final_archive}/source.sha256" \
	"${final_archive}/archive.sha256" >"${run_dir}/archive-manifest-hashes.txt" || \
	fail 'cannot hash archive manifests'
printf 'SMD407_UBUNTU_TLS_ARCHIVE_READBACK_COMPLETE active_artifacts=ABSENT archives=ROOT_ONLY_HASHED certgen=UNCHANGED configs=UNCHANGED tls=tls/none services=ACTIVE service_pids=%s jobs=638,639 accounting=COMPLETED_0_0 nodes=IDLE_NO_ALLOCATION queue=EMPTY run_dir=%s\n' \
	"$pids" "$run_dir"
