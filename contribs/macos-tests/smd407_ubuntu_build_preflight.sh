#!/bin/sh

set -u

if [ "${SMD407_UBUNTU_BUILD_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_UBUNTU_BUILD_PREFLIGHT_CONFIRMED=YES after confirming this read-only build preflight' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-ubuntu-build-preflight-${run_stamp}

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

hash_production()
{
	output=$1
	: >"$output" || return 1
	for path in \
		"$slurm_conf" \
		"${prefix}/etc/slurmdbd.conf" \
		"${prefix}/etc/gres.conf" \
		"$slurmd" \
		"${prefix}/sbin/slurmctld" \
		"${prefix}/sbin/slurmdbd"; do
		[ -f "$path" ] || continue
		sha256sum "$path" >>"$output" || return 1
	done
}

[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Linux ] || fail 'this preflight is for Ubuntu'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
for required in "$slurm_conf" "$slurmd" "$scontrol" "$squeue"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_name in awk cat cc dirname find grep make openssl sed sha256sum \
	sort stat systemctl tr wc; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done

umask 077
mkdir "$run_dir" || fail 'cannot create run directory'
printf 'mode=READ_ONLY_BUILD_PREFLIGHT run_dir=%s\n' "$run_dir"

hash_production "${run_dir}/production-before.sha256" || \
	fail 'cannot hash production inputs'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-before.txt" || fail 'cannot capture service identities'

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
grep -q ' is UP$' "${run_dir}/controller.txt" || fail 'controller is not UP'
"$scontrol" show node ubuntu >"${run_dir}/ubuntu-node.txt" || \
	fail 'Ubuntu node readback failed'
"$scontrol" show node PC-210 >"${run_dir}/mac-node.txt" || \
	fail 'Mac node readback failed'
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue.txt" || \
	fail 'queue readback failed'

{
	for command_name in uv python3 cmake gcc cc make git pkg-config; do
		printf '%s=' "$command_name"
		command -v "$command_name" 2>/dev/null || printf '%s\n' ABSENT
	done
} >"${run_dir}/tool-paths.txt"

{
	if command -v uv >/dev/null 2>&1; then uv --version; fi
	if command -v python3 >/dev/null 2>&1; then python3 --version; fi
	if command -v cmake >/dev/null 2>&1; then cmake --version | sed -n '1,2p'; fi
	cc --version | sed -n '1p'
	make --version | sed -n '1p'
	git --version
} >"${run_dir}/tool-versions.txt" 2>&1

openssl version -a >"${run_dir}/openssl.txt" 2>&1 || true
if command -v pkg-config >/dev/null 2>&1; then
	pkg-config --modversion openssl >"${run_dir}/openssl-pkg-config.out" \
		2>"${run_dir}/openssl-pkg-config.err" || true
	pkg-config --cflags --libs openssl >"${run_dir}/openssl-flags.out" \
		2>"${run_dir}/openssl-flags.err" || true
else
	printf '%s\n' 'pkg-config=ABSENT' >"${run_dir}/openssl-pkg-config.err"
	printf '%s\n' 'pkg-config=ABSENT' >"${run_dir}/openssl-flags.err"
fi

if command -v dpkg-query >/dev/null 2>&1; then
	dpkg-query -W -f='${binary:Package}|${Version}|${Architecture}|${Status}\n' \
		libssl-dev zlib1g-dev >"${run_dir}/development-packages.out" \
		2>"${run_dir}/development-packages.err" || true
else
	printf '%s\n' 'dpkg-query=ABSENT' >"${run_dir}/development-packages.err"
fi

: >"${run_dir}/development-files.txt"
for path in \
	/usr/include/openssl/ssl.h \
	/usr/include/openssl/crypto.h \
	/usr/include/zlib.h \
	/usr/lib/x86_64-linux-gnu/libssl.so \
	/usr/lib/x86_64-linux-gnu/libcrypto.so \
	/usr/lib/x86_64-linux-gnu/libz.so; do
	if [ -e "$path" ]; then
		stat -c '%U:%G:%a %s %N' "$path" >>"${run_dir}/development-files.txt"
	else
		printf 'ABSENT %s\n' "$path" >>"${run_dir}/development-files.txt"
	fi
done

cat >"${run_dir}/openssl-link-probe.c" <<'EOF'
#include <openssl/ssl.h>
#include <zlib.h>
int main(void)
{
	return OPENSSL_VERSION_NUMBER == 0 || zlibVersion() == 0;
}
EOF
if cc "${run_dir}/openssl-link-probe.c" -lssl -lcrypto -lz \
	-o "${run_dir}/openssl-link-probe" \
	>"${run_dir}/openssl-link-probe.out" \
	2>"${run_dir}/openssl-link-probe.err"; then
	"${run_dir}/openssl-link-probe" || fail 'OpenSSL/zlib link probe execution failed'
	link_probe=PASS
else
	link_probe=FAIL
fi

: >"${run_dir}/slurm-source-files.txt"
for search_root in /home/REDACTED_USER /root /usr/local/src /opt; do
	[ -d "$search_root" ] || continue
	find "$search_root" -maxdepth 7 -type f \
		-path '*/src/plugins/tls/s2n/tls_s2n.c' -print \
		2>/dev/null >>"${run_dir}/slurm-source-files.txt" || true
done
sort -u "${run_dir}/slurm-source-files.txt" \
	-o "${run_dir}/slurm-source-files.txt"

: >"${run_dir}/slurm-config-status-files.txt"
for search_root in /home/REDACTED_USER /root /usr/local/src /opt; do
	[ -d "$search_root" ] || continue
	find "$search_root" -maxdepth 7 -type f -name config.status -print \
		2>/dev/null | grep -E '/slurm[^/]*/|/slurm/' \
		>>"${run_dir}/slurm-config-status-files.txt" || true
done
sort -u "${run_dir}/slurm-config-status-files.txt" \
	-o "${run_dir}/slurm-config-status-files.txt"

: >"${run_dir}/slurm-configurations.txt"
while IFS= read -r status_file; do
	[ -n "$status_file" ] || continue
	printf '[%s]\n' "$status_file" >>"${run_dir}/slurm-configurations.txt"
	status_dir=$(dirname "$status_file")
	(
		cd "$status_dir" || exit 1
		/bin/sh ./config.status --config
	) >>"${run_dir}/slurm-configurations.txt" 2>&1 || true
done <"${run_dir}/slurm-config-status-files.txt"

source_count=$(wc -l <"${run_dir}/slurm-source-files.txt" | tr -d ' ')
config_count=$(wc -l <"${run_dir}/slurm-config-status-files.txt" | tr -d ' ')

hash_production "${run_dir}/production-after.sha256" || \
	fail 'cannot hash final production inputs'
cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-after.txt" || fail 'cannot capture final service identities'
cmp -s "${run_dir}/services-before.txt" "${run_dir}/services-after.txt" || \
	fail 'service identity changed'

printf '%s\n' \
	"openssl_development_link=$link_probe" \
	"slurm_source_candidates=$source_count config_status_candidates=$config_count" \
	"SMD407_UBUNTU_BUILD_PREFLIGHT_COMPLETE production_unchanged=PASS services_unchanged=PASS run_dir=$run_dir"
