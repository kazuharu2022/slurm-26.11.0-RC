#!/bin/sh

set -u

if [ "${SMD407_UBUNTU_TLS_INACTIVE_INSTALL_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_UBUNTU_TLS_INACTIVE_INSTALL_CONFIRMED=YES after approving inactive Ubuntu TLS artifact installation' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
plugin_source=/tmp/slurm-smd407-ubuntu-isolated-resume-20260912T205742/artifacts/tls_s2n.so
s2n_source=/tmp/slurm-smd407-ubuntu-isolated-resume-20260912T205742/artifacts/s2n-prefix
cert_source=/tmp/slurm-smd407-certificate-stage-20260912T221817/ubuntu-bundle
plugin_hash=fac2507c6c5070c47c78959a005b2e861632c9ff837601353a178570d72808a1
libs2n_hash=7ca8f397d81e31b2dfe47229e72200115b24716b63f46a354c13b9e2a1ccfd70
plugin_target=${prefix}/lib/slurm/tls_s2n.so
s2n_target=${prefix}/lib/slurm-s2n-1.7.9
state_file=${prefix}/.smd407-ubuntu-tls-inactive.env
slurm_conf=${prefix}/etc/slurm.conf
slurmdbd_conf=${prefix}/etc/slurmdbd.conf
gres_conf=${prefix}/etc/gres.conf
slurm_key=${prefix}/etc/slurm.key
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-ubuntu-inactive-install-${run_stamp}
tmp_s2n=${prefix}/lib/.slurm-s2n-1.7.9.smd407-${run_stamp}
tmp_plugin=${prefix}/lib/slurm/.tls_s2n.so.smd407-${run_stamp}
installed_s2n=0
installed_plugin=0
installed_certs=
state_installed=0
success=0

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

rollback()
{
	[ "$state_installed" -eq 0 ] || rm -f "$state_file"
	rm -f "${state_file}.tmp"
	for name in $installed_certs; do
		rm -f "${prefix}/etc/${name}"
	done
	[ "$installed_plugin" -eq 0 ] || rm -f "$plugin_target"
	if [ "$installed_s2n" -eq 1 ] && [ -d "$s2n_target" ]; then
		rm -rf "$s2n_target"
	fi
	rm -rf "$tmp_s2n"
	rm -f "$tmp_plugin"
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ]; then
		rollback
		printf 'recovery: inactive files introduced by this attempt were removed; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Linux ] || fail 'this installer is for Ubuntu'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done
for required in "$plugin_source" "$s2n_source/lib/libs2n.so" \
	"$cert_source/manifest.sha256" "$slurm_conf" "$slurmdbd_conf" \
	"$gres_conf" "$slurm_key" "$slurmd" "$scontrol" "$squeue"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_name in awk chmod chown cmp cp file find grep install ldd mkdir mv \
	readelf rm sha256sum stat systemctl; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done
id slurm >/dev/null 2>&1 || fail 'missing SlurmUser=slurm account'
[ ! -e "$state_file" ] || fail "inactive install state already exists=$state_file"
for target in "$plugin_target" "$s2n_target" \
	"${prefix}/etc/ca_cert.pem" "${prefix}/etc/ctld_cert.pem" \
	"${prefix}/etc/ctld_cert_key.pem" "${prefix}/etc/dbd_cert.pem" \
	"${prefix}/etc/dbd_cert_key.pem" "${prefix}/etc/slurmd_cert.pem" \
	"${prefix}/etc/slurmd_cert_key.pem"; do
	[ ! -e "$target" ] || fail "refusing to overwrite existing target=$target"
done

umask 077
mkdir "$run_dir" || fail 'cannot create run directory'
printf 'mode=UBUNTU_TLS_INACTIVE_INSTALL run_dir=%s\n' "$run_dir"
export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
grep -q ' is UP$' "${run_dir}/controller.txt" || fail 'controller is not UP'
"$scontrol" show config >"${run_dir}/active-config-before.txt" || \
	fail 'cannot read active config'
grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' \
	"${run_dir}/active-config-before.txt" || fail 'active TLS is not tls/none'
"$scontrol" show node ubuntu >"${run_dir}/ubuntu-before.txt" || fail 'cannot read ubuntu node'
"$scontrol" show node PC-210 >"${run_dir}/mac-before.txt" || fail 'cannot read Mac node'
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-before.txt" || fail 'cannot read queue'
for node_file in "${run_dir}/ubuntu-before.txt" "${run_dir}/mac-before.txt"; do
	[ "$(node_field State "$node_file")" = IDLE ] || fail "node is not IDLE=$node_file"
	[ "$(node_field CPUAlloc "$node_file")" = 0 ] || fail "CPU allocation exists=$node_file"
	[ "$(node_field AllocMem "$node_file")" = 0 ] || fail "memory allocation exists=$node_file"
done
ubuntu_registered_gres=$(node_field Gres "${run_dir}/ubuntu-before.txt")
[ ! -s "${run_dir}/queue-before.txt" ] || fail 'target queue is not empty'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-before.txt" || fail 'cannot capture service identity'

[ "$(sha256sum "$plugin_source" | awk '{print $1}')" = "$plugin_hash" ] || \
	fail 'Ubuntu plugin artifact hash mismatch'
[ "$(sha256sum "$s2n_source/lib/libs2n.so" | awk '{print $1}')" = "$libs2n_hash" ] || \
	fail 'Ubuntu libs2n artifact hash mismatch'
(
	cd "$cert_source" || exit 1
	sha256sum -c manifest.sha256
) >"${run_dir}/certificate-manifest.out" \
	2>"${run_dir}/certificate-manifest.err" || fail 'Ubuntu certificate manifest mismatch'
file "$plugin_source" >"${run_dir}/plugin-source-file.txt" || fail 'cannot inspect plugin artifact'
grep -Eq 'ELF 64-bit LSB.*x86-64' "${run_dir}/plugin-source-file.txt" || \
	fail 'Ubuntu plugin architecture mismatch'
LD_LIBRARY_PATH="$s2n_source/lib" ldd "$plugin_source" \
	>"${run_dir}/plugin-source-ldd.txt" 2>&1 || fail 'artifact dependency resolution failed'
grep -q 'libs2n\.so\.1' "${run_dir}/plugin-source-ldd.txt" || \
	fail 'artifact does not depend on libs2n.so.1'
grep -q 'not found' "${run_dir}/plugin-source-ldd.txt" && \
	fail 'artifact has unresolved dependency'

trap cleanup EXIT HUP INT TERM
cp -a "$s2n_source" "$tmp_s2n" || fail 'cannot stage libs2n tree'
chown -R root:root "$tmp_s2n" || fail 'cannot set libs2n ownership'
find "$tmp_s2n" -type d -exec chmod 0755 {} \; || fail 'cannot set libs2n directory modes'
find "$tmp_s2n" -type f -exec chmod 0644 {} \; || fail 'cannot set libs2n file modes'
find "$tmp_s2n/lib" -type f -name 'libs2n.so*' -exec chmod 0755 {} \; || \
	fail 'cannot set libs2n library mode'
mv "$tmp_s2n" "$s2n_target" || fail 'cannot activate inactive libs2n tree'
installed_s2n=1

install -o root -g root -m 0755 "$plugin_source" "$tmp_plugin" || \
	fail 'cannot stage tls_s2n plugin'
mv "$tmp_plugin" "$plugin_target" || fail 'cannot install tls_s2n plugin'
installed_plugin=1

for name in ca_cert.pem ctld_cert.pem ctld_cert_key.pem dbd_cert.pem \
	dbd_cert_key.pem slurmd_cert.pem slurmd_cert_key.pem; do
	mode=0600
	owner=slurm
	group=slurm
	if [ "$name" = ca_cert.pem ]; then
		mode=0644
		owner=root
	fi
	install -o "$owner" -g "$group" -m "$mode" \
		"${cert_source}/${name}" "${prefix}/etc/${name}" || \
		fail "cannot install inactive certificate=$name"
	installed_certs="$installed_certs $name"
done

ldd "$plugin_target" >"${run_dir}/plugin-installed-ldd.txt" 2>&1 || \
	fail 'installed plugin dependency resolution failed'
grep -q "${s2n_target}/lib/libs2n.so.1" "${run_dir}/plugin-installed-ldd.txt" || \
	fail 'installed plugin does not resolve final libs2n path'

cp "$gres_conf" "${run_dir}/gres.conf" || fail 'cannot stage candidate gres.conf'
if grep -Eq '^[[:space:]]*(TLSType|TLSParameters)=' "$slurm_conf"; then
	fail 'production slurm.conf already has TLS keys'
fi
if grep -Eq '^[[:space:]]*(TLSType|TLSParameters)=' "$slurmdbd_conf"; then
	fail 'production slurmdbd.conf already has TLS keys'
fi
awk -v prefix="$prefix" '
{ print }
END {
	print "TLSType=tls/s2n"
	print "TLSParameters=ca_cert_file=" prefix "/etc/ca_cert.pem,ctld_cert_file=" prefix "/etc/ctld_cert.pem,ctld_cert_key_file=" prefix "/etc/ctld_cert_key.pem,slurmd_cert_file=" prefix "/etc/slurmd_cert.pem,slurmd_cert_key_file=" prefix "/etc/slurmd_cert_key.pem"
}
' "$slurm_conf" >"${run_dir}/slurm.conf" || fail 'cannot build candidate slurm.conf'
awk -v prefix="$prefix" '
{ print }
END {
	print "TLSType=tls/s2n"
	print "TLSParameters=ca_cert_file=" prefix "/etc/ca_cert.pem,dbd_cert_file=" prefix "/etc/dbd_cert.pem,dbd_cert_key_file=" prefix "/etc/dbd_cert_key.pem"
}
' "$slurmdbd_conf" >"${run_dir}/slurmdbd.conf" || fail 'cannot build candidate slurmdbd.conf'
chmod 0600 "${run_dir}/slurm.conf" "${run_dir}/slurmdbd.conf" || \
	fail 'cannot protect candidate configs'
SLURM_SACK_KEY="$slurm_key" "$slurmd" -G -f "${run_dir}/slurm.conf" \
	>"${run_dir}/candidate-G.out" 2>"${run_dir}/candidate-G.err" || \
	fail 'installed TLS candidate slurmd -G failed'
case "$ubuntu_registered_gres" in
	'(null)')
		candidate_gres=NOT_CONFIGURED
		;;
	'gpu:nvidia_geforce_rtx_3060_laptop_gpu:1')
		grep -Eq '(Gres Name=gpu Type=nvidia_geforce_rtx_3060_laptop_gpu Count=1|Found gpu:nvidia_geforce_rtx_3060_laptop_gpu:1)' \
			"${run_dir}/candidate-G.out" "${run_dir}/candidate-G.err" || \
			fail 'configured Ubuntu GPU GRES validation missing'
		candidate_gres=PASS
		;;
	*)
		fail "unsupported active Ubuntu GRES=$ubuntu_registered_gres"
		;;
esac

printf '%s\n' \
	"run_dir=$run_dir" \
	"phase=UBUNTU_INACTIVE_INSTALLED" \
	"plugin_hash=$plugin_hash" \
	"libs2n_hash=$libs2n_hash" >"${state_file}.tmp" || fail 'cannot create state file'
chmod 0600 "${state_file}.tmp" || fail 'cannot protect state file'
mv "${state_file}.tmp" "$state_file" || fail 'cannot install state file'
state_installed=1

"$scontrol" show config >"${run_dir}/active-config-after.txt" || fail 'cannot reread config'
grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' \
	"${run_dir}/active-config-after.txt" || fail 'active TLS changed unexpectedly'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-after.txt" || fail 'cannot recapture service identity'
cmp -s "${run_dir}/services-before.txt" "${run_dir}/services-after.txt" || \
	fail 'service identity changed during inactive install'
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-after.txt" || fail 'cannot reread queue'
[ ! -s "${run_dir}/queue-after.txt" ] || fail 'target queue changed during inactive install'

success=1
trap - EXIT HUP INT TERM
printf '%s\n' \
	"SMD407_UBUNTU_TLS_INACTIVE_INSTALL_COMPLETE plugin_hash=${plugin_hash} libs2n_hash=${libs2n_hash} certificates=7 candidate_G=PASS active_gres=${ubuntu_registered_gres} candidate_gres=${candidate_gres} active_tls=tls/none services_unchanged=PASS nodes=IDLE queue=EMPTY state=${state_file} run_dir=${run_dir}"
