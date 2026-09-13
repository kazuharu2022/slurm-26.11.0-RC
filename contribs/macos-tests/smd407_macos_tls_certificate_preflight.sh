#!/bin/sh

set -u

if [ "${SMD407_MAC_TLS_CERTIFICATE_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_MAC_TLS_CERTIFICATE_PREFLIGHT_CONFIRMED=YES after approving isolated Mac certificate archive verification' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
archive=${SMD407_MAC_CERT_ARCHIVE:-/tmp/smd407-mac-bundle.tar}
expected_archive_hash=${SMD407_MAC_CERT_ARCHIVE_SHA256:-}
openssl=/opt/homebrew/opt/openssl@3/bin/openssl
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-mac-certificate-preflight-${run_stamp}
extract_dir=${run_dir}/extract
bundle=${extract_dir}/mac-bundle

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

hash_production()
{
	output=$1
	: >"$output" || return 1
	for path in \
		"${prefix}/etc/slurm.conf" \
		"${prefix}/etc/gres.conf" \
		"${prefix}/sbin/slurmd" \
		"${prefix}/lib/slurm/libslurmfull.dylib" \
		"${prefix}/lib/slurm/tls_none.so" \
		"${prefix}/lib/slurm/tls_s2n.so"; do
		[ -f "$path" ] || continue
		/usr/bin/shasum -a 256 "$path" >>"$output" || return 1
	done
}

[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Darwin ] || fail 'this preflight is for macOS'
[ "$(hostname -s)" = PC-210 ] || fail "unexpected host=$(hostname -s)"
[ -n "$expected_archive_hash" ] || fail 'missing SMD407_MAC_CERT_ARCHIVE_SHA256'
[ -f "$archive" ] || fail "missing certificate archive=$archive"
for required in "$openssl" "$slurm_conf" "$scontrol" "$squeue"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_path in \
	/bin/cat /bin/launchctl /bin/mkdir /bin/ps /usr/bin/awk /usr/bin/cmp \
	/usr/bin/find /usr/bin/grep /usr/bin/shasum /usr/bin/stat /usr/bin/tar \
	/usr/bin/wc; do
	[ -x "$command_path" ] || fail "missing command=$command_path"
done

umask 077
/bin/mkdir "$run_dir" "$extract_dir" || fail 'cannot create preflight directory'
printf 'mode=READ_ONLY_MAC_CERTIFICATE_PREFLIGHT run_dir=%s archive=%s\n' \
	"$run_dir" "$archive"

hash_production "${run_dir}/production-before.sha256" || \
	fail 'cannot hash production inputs'
[ -f /var/run/slurmd.pid ] || fail 'missing slurmd pid file'
initial_slurmd_pid=$(/bin/cat /var/run/slurmd.pid)
/bin/ps -p "$initial_slurmd_pid" -o pid=,ppid=,state=,command= \
	>"${run_dir}/slurmd-process-before.txt" || fail 'slurmd process is not alive'
/usr/bin/grep -q '/opt/slurm/26.11.0/sbin/slurmd' \
	"${run_dir}/slurmd-process-before.txt" || fail 'unexpected slurmd process'
/bin/launchctl procinfo "$initial_slurmd_pid" \
	>"${run_dir}/slurmd-procinfo-before.txt" 2>&1 || \
	fail 'cannot read slurmd launchd identity'
/usr/bin/grep -Fq 'system/org.schedmd.slurmd = {' \
	"${run_dir}/slurmd-procinfo-before.txt" || \
	fail 'slurmd is not associated with launchd service'
actual_archive_hash=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
printf 'expected=%s\nactual=%s\n' "$expected_archive_hash" "$actual_archive_hash" \
	>"${run_dir}/archive-hash.txt"
[ "$actual_archive_hash" = "$expected_archive_hash" ] || \
	fail 'certificate archive hash mismatch'

/usr/bin/tar -tf "$archive" >"${run_dir}/archive-members.txt" || \
	fail 'cannot list certificate archive'
member_count=$(/usr/bin/grep -Ec '.' "${run_dir}/archive-members.txt")
[ "$member_count" -eq 5 ] || fail "unexpected archive member count=$member_count"
while IFS= read -r member; do
	case "$member" in
	mac-bundle/|mac-bundle/ca_cert.pem|mac-bundle/slurmd_cert.pem|mac-bundle/slurmd_cert_key.pem|mac-bundle/manifest.sha256)
		;;
	*'/../'*|'../'*|/*)
		fail "unsafe archive member=$member"
		;;
	*)
		fail "unexpected archive member=$member"
		;;
	esac
done <"${run_dir}/archive-members.txt"

/usr/bin/tar -xf "$archive" -C "$extract_dir" || \
	fail 'cannot extract certificate archive'
for required in ca_cert.pem slurmd_cert.pem slurmd_cert_key.pem manifest.sha256; do
	[ -f "${bundle}/${required}" ] || fail "missing bundle member=$required"
done
[ "$(/usr/bin/find "$bundle" -type f | /usr/bin/wc -l | /usr/bin/awk '{print $1}')" -eq 4 ] || \
	fail 'unexpected extracted file count'

while read -r expected file; do
	case "$file" in
	ca_cert.pem|slurmd_cert.pem|slurmd_cert_key.pem)
		;;
	*)
		fail "unexpected manifest member=$file"
		;;
	esac
	actual=$(/usr/bin/shasum -a 256 "${bundle}/${file}" | /usr/bin/awk '{print $1}')
	[ "$actual" = "$expected" ] || fail "manifest mismatch for $file"
done <"${bundle}/manifest.sha256"
[ "$(/usr/bin/grep -Ec '.' "${bundle}/manifest.sha256")" -eq 3 ] || \
	fail 'manifest entry count mismatch'

[ "$(/usr/bin/stat -f '%Lp' "${bundle}/ca_cert.pem")" = 644 ] || \
	fail 'CA certificate mode mismatch'
for file in slurmd_cert.pem slurmd_cert_key.pem manifest.sha256; do
	[ "$(/usr/bin/stat -f '%Lp' "${bundle}/${file}")" = 600 ] || \
		fail "protected file mode mismatch=$file"
done

"$openssl" verify -purpose sslserver -CAfile "${bundle}/ca_cert.pem" \
	"${bundle}/slurmd_cert.pem" >"${run_dir}/verify-server.out" \
	2>"${run_dir}/verify-server.err" || fail 'server certificate verification failed'
"$openssl" verify -purpose sslclient -CAfile "${bundle}/ca_cert.pem" \
	"${bundle}/slurmd_cert.pem" >"${run_dir}/verify-client.out" \
	2>"${run_dir}/verify-client.err" || fail 'client certificate verification failed'
"$openssl" x509 -checkend 604800 -noout -in "${bundle}/slurmd_cert.pem" \
	>"${run_dir}/checkend.out" 2>"${run_dir}/checkend.err" || \
	fail 'certificate expires within seven days'
"$openssl" x509 -in "${bundle}/slurmd_cert.pem" -noout \
	-ext subjectAltName >"${run_dir}/san.txt" || fail 'cannot inspect SAN'
for expected in 'DNS:PC-210' 'DNS:PC-210.local' 'IP Address:192.168.10.128'; do
	/usr/bin/grep -Fq "$expected" "${run_dir}/san.txt" || \
		fail "SAN missing $expected"
done
"$openssl" x509 -in "${bundle}/slurmd_cert.pem" -noout \
	-ext extendedKeyUsage >"${run_dir}/eku.txt" || fail 'cannot inspect EKU'
/usr/bin/grep -Fq 'TLS Web Server Authentication' "${run_dir}/eku.txt" || \
	fail 'serverAuth EKU missing'
/usr/bin/grep -Fq 'TLS Web Client Authentication' "${run_dir}/eku.txt" || \
	fail 'clientAuth EKU missing'

"$openssl" x509 -in "${bundle}/slurmd_cert.pem" -pubkey -noout \
	>"${run_dir}/cert-pub.pem" || fail 'cannot read certificate public key'
"$openssl" pkey -pubin -in "${run_dir}/cert-pub.pem" -outform DER \
	-out "${run_dir}/cert-pub.der" || fail 'cannot encode certificate public key'
"$openssl" pkey -in "${bundle}/slurmd_cert_key.pem" -pubout -outform DER \
	-out "${run_dir}/key-pub.der" || fail 'cannot encode private-key public key'
/usr/bin/cmp -s "${run_dir}/cert-pub.der" "${run_dir}/key-pub.der" || \
	fail 'certificate and key mismatch'

"$openssl" x509 -in "${bundle}/ca_cert.pem" -noout \
	-subject -issuer -serial -dates -fingerprint -sha256 \
	>"${run_dir}/ca-metadata.txt" || fail 'cannot inspect CA metadata'
"$openssl" x509 -in "${bundle}/slurmd_cert.pem" -noout \
	-subject -issuer -serial -dates -fingerprint -sha256 \
	>"${run_dir}/slurmd-metadata.txt" || fail 'cannot inspect slurmd metadata'

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller.txt" || fail 'controller is not UP'
"$scontrol" show node PC-210 >"${run_dir}/node.txt" || fail 'node readback failed'
"$squeue" -h -w PC-210 >"${run_dir}/queue.txt" || fail 'queue readback failed'
[ "$(node_field State "${run_dir}/node.txt")" = IDLE ] || fail 'PC-210 is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node.txt")" = 0 ] || \
	fail 'PC-210 CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node.txt")" = 0 ] || \
	fail 'PC-210 AllocMem is not zero'
[ ! -s "${run_dir}/queue.txt" ] || fail 'PC-210 queue is not empty'

[ -f /var/run/slurmd.pid ] || fail 'missing slurmd pid file'
slurmd_pid=$(/bin/cat /var/run/slurmd.pid)
[ "$slurmd_pid" = "$initial_slurmd_pid" ] || fail 'slurmd PID changed'
/bin/ps -p "$slurmd_pid" -o pid=,ppid=,state=,command= \
	>"${run_dir}/slurmd-process.txt" || fail 'slurmd process is not alive'
/usr/bin/grep -q '/opt/slurm/26.11.0/sbin/slurmd' \
	"${run_dir}/slurmd-process.txt" || fail 'unexpected slurmd process'

hash_production "${run_dir}/production-after.sha256" || \
	fail 'cannot hash final production inputs'
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production inputs changed'

printf '%s\n' \
	"SMD407_MAC_TLS_CERTIFICATE_PREFLIGHT_COMPLETE archive_hash=${actual_archive_hash} members=4 manifest=PASS chain=PASS purposes=serverAuth,clientAuth key_pair=PASS sans=PASS expiry=PASS modes=PASS slurmd_pid=${slurmd_pid} production_unchanged=PASS node=IDLE queue=EMPTY run_dir=${run_dir}"
