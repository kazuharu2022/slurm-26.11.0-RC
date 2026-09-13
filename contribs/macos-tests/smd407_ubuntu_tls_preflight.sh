#!/bin/sh

set -u

if [ "${SMD407_TLS_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_TLS_PREFLIGHT_CONFIRMED=YES after confirming a read-only TLS preflight' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmdbd_conf=${prefix}/etc/slurmdbd.conf
gres_conf=${prefix}/etc/gres.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
plugin_dir=${prefix}/lib/slurm
node_name=ubuntu
peer_node=PC-210
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-ubuntu-preflight-${run_stamp}

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

hash_inputs()
{
	output=$1
	: >"$output" || return 1
	for path in \
		"$slurm_conf" \
		"$slurmdbd_conf" \
		"$gres_conf" \
		"$slurmd" \
		"${prefix}/sbin/slurmctld" \
		"${prefix}/sbin/slurmdbd" \
		"${plugin_dir}/tls_none.so" \
		"${plugin_dir}/tls_s2n.so" \
		"${plugin_dir}/certgen_script.so" \
		"${plugin_dir}/certmgr_script.so"; do
		[ -f "$path" ] || continue
		sha256sum "$path" >>"$output" || return 1
	done
}

[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Linux ] || fail 'this preflight is for Ubuntu'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
for required in "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
	"$scontrol" "$squeue" "$plugin_dir"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_name in awk cmp file grep ldd openssl sha256sum stat systemctl; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done

umask 077
mkdir "$run_dir" || fail 'cannot create run directory'
printf 'mode=READ_ONLY_PRODUCTION run_dir=%s\n' "$run_dir"
hash_inputs "${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-before.txt" || fail 'cannot capture service identities'

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
grep -q ' is UP$' "${run_dir}/controller.txt" || fail 'controller is not UP'
"$scontrol" show config >"${run_dir}/controller-config.txt" || \
	fail 'controller config readback failed'
"$scontrol" show node "$node_name" >"${run_dir}/ubuntu-node.txt" || \
	fail 'Ubuntu node readback failed'
"$scontrol" show node "$peer_node" >"${run_dir}/mac-node.txt" || \
	fail 'Mac node readback failed'
"$squeue" -h -w "$node_name,$peer_node" >"${run_dir}/queue.txt" || \
	fail 'queue readback failed'

grep -E \
	'^[[:space:]]*(AuthAltTypes|AuthType|CertgenParameters|CertgenType|CertmgrParameters|CertmgrType|CommunicationParameters|TLSParameters|TLSType)=' \
	"$slurm_conf" >"${run_dir}/slurm-tls-config.txt" || true
grep -E \
	'^[[:space:]]*(AuthAltTypes|AuthType|CommunicationParameters|TLSParameters|TLSType)=' \
	"$slurmdbd_conf" >"${run_dir}/slurmdbd-tls-config.txt" || true
grep -E \
	'^(AuthAltTypes|AuthType|CertgenParameters|CertgenType|CertmgrParameters|CertmgrType|CommunicationParameters|TLSParameters|TLSType)' \
	"${run_dir}/controller-config.txt" >"${run_dir}/controller-tls-config.txt" || true

: >"${run_dir}/installed-plugins.txt"
: >"${run_dir}/installed-plugin-file.txt"
: >"${run_dir}/installed-plugin-links.txt"
installed_s2n=NO
for plugin in "$plugin_dir"/tls_*.so "$plugin_dir"/certgen_*.so \
	"$plugin_dir"/certmgr_*.so; do
	[ -f "$plugin" ] || continue
	printf '%s\n' "$plugin" >>"${run_dir}/installed-plugins.txt"
	file "$plugin" >>"${run_dir}/installed-plugin-file.txt" 2>&1 || true
	printf '%s\n' "[$plugin]" >>"${run_dir}/installed-plugin-links.txt"
	ldd "$plugin" >>"${run_dir}/installed-plugin-links.txt" 2>&1 || true
	case "$plugin" in
	*/tls_s2n.so) installed_s2n=YES ;;
	esac
done

if command -v pkg-config >/dev/null 2>&1; then
	pkg-config --modversion s2n >"${run_dir}/s2n-pkg-config.out" \
		2>"${run_dir}/s2n-pkg-config.err" || true
else
	printf '%s\n' 'pkg-config=ABSENT' >"${run_dir}/s2n-pkg-config.err"
fi
if command -v dpkg-query >/dev/null 2>&1; then
	dpkg-query -W -f='${binary:Package}|${Version}|${Architecture}|${Status}\n' \
		'libs2n*' 's2n*' >"${run_dir}/s2n-packages.out" \
		2>"${run_dir}/s2n-packages.err" || true
else
	printf '%s\n' 'dpkg-query=ABSENT' >"${run_dir}/s2n-packages.err"
fi
openssl version -a >"${run_dir}/openssl.txt" 2>&1 || true

: >"${run_dir}/s2n-libraries.txt"
for path in /usr/lib/x86_64-linux-gnu/libs2n.so* /usr/local/lib/libs2n.so* \
	/usr/local/lib64/libs2n.so*; do
	[ -e "$path" ] || continue
	stat -c '%U:%G:%a %s %N' "$path" >>"${run_dir}/s2n-libraries.txt" 2>&1 || true
done

: >"${run_dir}/certificate-metadata.txt"
for path in \
	"${prefix}/etc/ca_cert.pem" \
	"${prefix}/etc/ctld_cert.pem" \
	"${prefix}/etc/ctld_cert_key.pem" \
	"${prefix}/etc/dbd_cert.pem" \
	"${prefix}/etc/dbd_cert_key.pem" \
	"${prefix}/etc/slurmd_cert.pem" \
	"${prefix}/etc/slurmd_cert_key.pem"; do
	if [ -e "$path" ]; then
		stat -c '%U:%G:%a %s %n' "$path" >>"${run_dir}/certificate-metadata.txt" 2>&1 || true
	else
		printf 'ABSENT %s\n' "$path" >>"${run_dir}/certificate-metadata.txt"
	fi
done

hash_inputs "${run_dir}/production-after.sha256" || fail 'cannot hash final production inputs'
cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed during preflight'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-after.txt" || fail 'cannot capture final service identities'
cmp -s "${run_dir}/services-before.txt" "${run_dir}/services-after.txt" || \
	fail 'service identity changed during preflight'

node_state=$(node_field State "${run_dir}/ubuntu-node.txt")
if [ "$installed_s2n" = YES ]; then
	classification=UBUNTU_TLS_S2N_INSTALLED
else
	classification=MISSING_UBUNTU_TLS_S2N_PLUGIN
fi

printf '%s\n' \
	"ubuntu_tls_s2n_installed=$installed_s2n" \
	"runtime_state=$node_state queue_bytes=$(wc -c <"${run_dir}/queue.txt" | tr -d ' ')" \
	"SMD407_UBUNTU_TLS_PREFLIGHT_COMPLETE classification=$classification production_unchanged=PASS services_unchanged=PASS run_dir=$run_dir"
