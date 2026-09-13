#!/bin/sh

set -u

mode=${1:-root}

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

if [ "$mode" = worker ]; then
	[ "$#" -eq 2 ] || fail 'invalid worker arguments'
	run_dir=$2
	openssl=/usr/bin/openssl
	ca_private=${run_dir}/ca-private
	ubuntu_bundle=${run_dir}/ubuntu-bundle
	mac_bundle=${run_dir}/mac-bundle
	rotation_bundle=${run_dir}/rotation-mac-bundle
	negative_bundle=${run_dir}/negative-mac-bundle
	work=${run_dir}/work
	stamp=$(date '+%Y%m%dT%H%M%S')

	[ "${SMD407_TLS_CERTIFICATE_STAGE_CONFIRMED:-}" = YES ] || \
		fail 'worker confirmation missing'
	[ "$(id -u)" -ne 0 ] || fail 'worker must not run as root'
	[ -x "$openssl" ] || fail "missing openssl=$openssl"

	umask 077
	mkdir "$ca_private" "$ubuntu_bundle" "$mac_bundle" \
		"$rotation_bundle" "$negative_bundle" "$work" || \
		fail 'cannot create certificate staging directories'

	"$openssl" genpkey -algorithm RSA \
		-pkeyopt rsa_keygen_bits:3072 \
		-out "${ca_private}/ca_cert_key.pem" \
		>"${run_dir}/ca-key.out" 2>"${run_dir}/ca-key.err" || \
		fail 'test CA key generation failed'
	"$openssl" req -new -x509 -sha384 -days 90 \
		-key "${ca_private}/ca_cert_key.pem" \
		-set_serial 1000 \
		-subj "/O=SMD407 isolated validation/CN=SMD407 Test Root ${stamp}" \
		-addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
		-addext 'keyUsage=critical,keyCertSign,cRLSign' \
		-addext 'subjectKeyIdentifier=hash' \
		-out "${ca_private}/ca_cert.pem" \
		>"${run_dir}/ca-cert.out" 2>"${run_dir}/ca-cert.err" || \
		fail 'test CA certificate generation failed'

	"$openssl" genpkey -algorithm RSA \
		-pkeyopt rsa_keygen_bits:3072 \
		-out "${ca_private}/rogue_ca_cert_key.pem" \
		>"${run_dir}/rogue-ca-key.out" 2>"${run_dir}/rogue-ca-key.err" || \
		fail 'rogue CA key generation failed'
	"$openssl" req -new -x509 -sha384 -days 90 \
		-key "${ca_private}/rogue_ca_cert_key.pem" \
		-set_serial 2000 \
		-subj "/O=SMD407 isolated validation/CN=SMD407 Rogue Root ${stamp}" \
		-addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
		-addext 'keyUsage=critical,keyCertSign,cRLSign' \
		-addext 'subjectKeyIdentifier=hash' \
		-out "${ca_private}/rogue_ca_cert.pem" \
		>"${run_dir}/rogue-ca-cert.out" 2>"${run_dir}/rogue-ca-cert.err" || \
		fail 'rogue CA certificate generation failed'

	make_leaf()
	{
		name=$1
		serial=$2
		common_name=$3
		san=$4
		ca_cert=$5
		ca_key=$6
		key=${work}/${name}_cert_key.pem
		csr=${work}/${name}.csr.pem
		cert=${work}/${name}_cert.pem
		ext=${work}/${name}.ext

		printf '%s\n' \
			'basicConstraints=critical,CA:FALSE' \
			'keyUsage=critical,digitalSignature,keyEncipherment' \
			'extendedKeyUsage=serverAuth,clientAuth' \
			"subjectAltName=${san}" \
			'subjectKeyIdentifier=hash' \
			'authorityKeyIdentifier=keyid,issuer' >"$ext" || \
			fail "cannot create extension file for $name"
		"$openssl" genpkey -algorithm RSA \
			-pkeyopt rsa_keygen_bits:3072 -out "$key" \
			>"${run_dir}/${name}-key.out" \
			2>"${run_dir}/${name}-key.err" || \
			fail "key generation failed for $name"
		"$openssl" req -new -sha384 -key "$key" -out "$csr" \
			-subj "/O=SMD407 isolated validation/CN=${common_name}" \
			>"${run_dir}/${name}-csr.out" \
			2>"${run_dir}/${name}-csr.err" || \
			fail "CSR generation failed for $name"
		"$openssl" x509 -req -sha384 -days 30 \
			-in "$csr" -CA "$ca_cert" -CAkey "$ca_key" \
			-set_serial "$serial" -extfile "$ext" -out "$cert" \
			>"${run_dir}/${name}-sign.out" \
			2>"${run_dir}/${name}-sign.err" || \
			fail "certificate signing failed for $name"
		chmod 0600 "$key" "$cert" || fail "cannot protect $name certificate pair"
	}

	make_leaf ctld 1101 ubuntu2504-slurmctld \
		'DNS:ubuntu2504,DNS:ubuntu,IP:192.168.10.180' \
		"${ca_private}/ca_cert.pem" "${ca_private}/ca_cert_key.pem"
	make_leaf dbd 1102 ubuntu2504-slurmdbd \
		'DNS:ubuntu2504,DNS:ubuntu,IP:192.168.10.180' \
		"${ca_private}/ca_cert.pem" "${ca_private}/ca_cert_key.pem"
	make_leaf ubuntu-slurmd 1103 ubuntu-slurmd \
		'DNS:ubuntu,DNS:ubuntu2504,IP:192.168.10.180' \
		"${ca_private}/ca_cert.pem" "${ca_private}/ca_cert_key.pem"
	make_leaf mac-slurmd 1104 PC-210-slurmd \
		'DNS:PC-210,DNS:PC-210.local,IP:192.168.10.128' \
		"${ca_private}/ca_cert.pem" "${ca_private}/ca_cert_key.pem"
	make_leaf mac-slurmd-rotation 1204 PC-210-slurmd-rotation \
		'DNS:PC-210,DNS:PC-210.local,IP:192.168.10.128' \
		"${ca_private}/ca_cert.pem" "${ca_private}/ca_cert_key.pem"
	make_leaf mac-slurmd-rogue 2104 PC-210-slurmd-rogue \
		'DNS:PC-210,DNS:PC-210.local,IP:192.168.10.128' \
		"${ca_private}/rogue_ca_cert.pem" \
		"${ca_private}/rogue_ca_cert_key.pem"

	cp "${ca_private}/ca_cert.pem" "${ubuntu_bundle}/ca_cert.pem"
	cp "${work}/ctld_cert.pem" "${ubuntu_bundle}/ctld_cert.pem"
	cp "${work}/ctld_cert_key.pem" "${ubuntu_bundle}/ctld_cert_key.pem"
	cp "${work}/dbd_cert.pem" "${ubuntu_bundle}/dbd_cert.pem"
	cp "${work}/dbd_cert_key.pem" "${ubuntu_bundle}/dbd_cert_key.pem"
	cp "${work}/ubuntu-slurmd_cert.pem" "${ubuntu_bundle}/slurmd_cert.pem"
	cp "${work}/ubuntu-slurmd_cert_key.pem" "${ubuntu_bundle}/slurmd_cert_key.pem"
	cp "${ca_private}/ca_cert.pem" "${mac_bundle}/ca_cert.pem"
	cp "${work}/mac-slurmd_cert.pem" "${mac_bundle}/slurmd_cert.pem"
	cp "${work}/mac-slurmd_cert_key.pem" "${mac_bundle}/slurmd_cert_key.pem"
	cp "${ca_private}/ca_cert.pem" "${rotation_bundle}/ca_cert.pem"
	cp "${work}/mac-slurmd-rotation_cert.pem" "${rotation_bundle}/slurmd_cert.pem"
	cp "${work}/mac-slurmd-rotation_cert_key.pem" \
		"${rotation_bundle}/slurmd_cert_key.pem"
	cp "${ca_private}/rogue_ca_cert.pem" "${negative_bundle}/ca_cert.pem"
	cp "${work}/mac-slurmd-rogue_cert.pem" "${negative_bundle}/slurmd_cert.pem"
	cp "${work}/mac-slurmd-rogue_cert_key.pem" \
		"${negative_bundle}/slurmd_cert_key.pem"

	for bundle in "$ubuntu_bundle" "$mac_bundle" "$rotation_bundle" \
		"$negative_bundle"; do
		chmod 0644 "${bundle}/ca_cert.pem" || fail 'cannot set CA mode'
		find "$bundle" -type f ! -name ca_cert.pem -exec chmod 0600 {} \; || \
			fail 'cannot set daemon certificate mode'
	done
	chmod 0600 "${ca_private}/ca_cert_key.pem" \
		"${ca_private}/rogue_ca_cert_key.pem" || \
		fail 'cannot protect CA private keys'

	verify_pair()
	{
		label=$1
		bundle=$2
		cert=${bundle}/${label}_cert.pem
		key=${bundle}/${label}_cert_key.pem
		[ -f "$cert" ] || fail "missing certificate=$cert"
		[ -f "$key" ] || fail "missing key=$key"
		"$openssl" verify -purpose sslserver -CAfile "${bundle}/ca_cert.pem" \
			"$cert" >>"${run_dir}/verify-server.out" \
			2>>"${run_dir}/verify-server.err" || \
			fail "server chain verification failed for $label"
		"$openssl" verify -purpose sslclient -CAfile "${bundle}/ca_cert.pem" \
			"$cert" >>"${run_dir}/verify-client.out" \
			2>>"${run_dir}/verify-client.err" || \
			fail "client chain verification failed for $label"
		"$openssl" x509 -checkend 604800 -noout -in "$cert" \
			>>"${run_dir}/checkend.out" 2>>"${run_dir}/checkend.err" || \
			fail "certificate expires within seven days for $label"
		"$openssl" x509 -in "$cert" -pubkey -noout \
			>"${work}/${label}.cert-pub.pem" || \
			fail "cannot read certificate public key for $label"
		"$openssl" pkey -pubin -in "${work}/${label}.cert-pub.pem" \
			-outform DER -out "${work}/${label}.cert-pub.der" || \
			fail "cannot encode certificate public key for $label"
		"$openssl" pkey -in "$key" -pubout -outform DER \
			-out "${work}/${label}.key-pub.der" || \
			fail "cannot encode private-key public key for $label"
		[ -s "${work}/${label}.cert-pub.der" ] || \
			fail "empty certificate public key for $label"
		[ -s "${work}/${label}.key-pub.der" ] || \
			fail "empty private-key public key for $label"
		sha256sum "${work}/${label}.cert-pub.der" |
			awk '{print $1}' >"${work}/${label}.cert-pub.sha256" || \
			fail "cannot hash certificate public key for $label"
		sha256sum "${work}/${label}.key-pub.der" |
			awk '{print $1}' >"${work}/${label}.key-pub.sha256" || \
			fail "cannot hash private-key public key for $label"
		cmp -s "${work}/${label}.cert-pub.sha256" \
			"${work}/${label}.key-pub.sha256" || \
			fail "certificate and key mismatch for $label"
	}

	verify_pair ctld "$ubuntu_bundle"
	verify_pair dbd "$ubuntu_bundle"
	verify_pair slurmd "$ubuntu_bundle"
	verify_pair slurmd "$mac_bundle"
	verify_pair slurmd "$rotation_bundle"
	verify_pair slurmd "$negative_bundle"

	"$openssl" x509 -in "${mac_bundle}/slurmd_cert.pem" -noout \
		-ext subjectAltName >"${run_dir}/mac-san.txt" || fail 'cannot inspect Mac SAN'
	for expected in 'DNS:PC-210' 'DNS:PC-210.local' 'IP Address:192.168.10.128'; do
		grep -Fq "$expected" "${run_dir}/mac-san.txt" || \
			fail "Mac SAN missing $expected"
	done
	"$openssl" x509 -in "${ubuntu_bundle}/slurmd_cert.pem" -noout \
		-ext subjectAltName >"${run_dir}/ubuntu-san.txt" || \
		fail 'cannot inspect Ubuntu SAN'
	for expected in 'DNS:ubuntu' 'DNS:ubuntu2504' 'IP Address:192.168.10.180'; do
		grep -Fq "$expected" "${run_dir}/ubuntu-san.txt" || \
			fail "Ubuntu SAN missing $expected"
	done

	if "$openssl" verify -CAfile "${ubuntu_bundle}/ca_cert.pem" \
		"${negative_bundle}/slurmd_cert.pem" \
		>"${run_dir}/rogue-against-trusted.out" \
		2>"${run_dir}/rogue-against-trusted.err"; then
		fail 'rogue certificate unexpectedly chains to trusted CA'
	fi
	cmp -s "${mac_bundle}/slurmd_cert.pem" \
		"${rotation_bundle}/slurmd_cert.pem" && \
		fail 'rotation certificate is byte-identical to initial certificate'

	(
		cd "$ubuntu_bundle" || exit 1
		sha256sum ca_cert.pem ctld_cert.pem ctld_cert_key.pem \
			dbd_cert.pem dbd_cert_key.pem slurmd_cert.pem \
			slurmd_cert_key.pem >manifest.sha256
	) || fail 'cannot create Ubuntu bundle manifest'
	for bundle in "$mac_bundle" "$rotation_bundle" "$negative_bundle"; do
		(
			cd "$bundle" || exit 1
			sha256sum ca_cert.pem slurmd_cert.pem slurmd_cert_key.pem \
				>manifest.sha256
		) || fail "cannot create manifest for $bundle"
	done

	for cert in \
		"${ubuntu_bundle}/ctld_cert.pem" \
		"${ubuntu_bundle}/dbd_cert.pem" \
		"${ubuntu_bundle}/slurmd_cert.pem" \
		"${mac_bundle}/slurmd_cert.pem" \
		"${rotation_bundle}/slurmd_cert.pem" \
		"${negative_bundle}/slurmd_cert.pem"; do
		printf '[%s]\n' "$cert"
		"$openssl" x509 -in "$cert" -noout \
			-subject -issuer -serial -dates -fingerprint -sha256
		"$openssl" x509 -in "$cert" -noout -ext subjectAltName
		"$openssl" x509 -in "$cert" -noout -ext extendedKeyUsage
	done >"${run_dir}/certificate-metadata.txt" || \
		fail 'cannot capture certificate metadata'

	stat -c '%U:%G:%a %n' \
		"${ubuntu_bundle}/ca_cert.pem" \
		"${ubuntu_bundle}/ctld_cert.pem" \
		"${ubuntu_bundle}/ctld_cert_key.pem" \
		"${ubuntu_bundle}/dbd_cert.pem" \
		"${ubuntu_bundle}/dbd_cert_key.pem" \
		"${ubuntu_bundle}/slurmd_cert.pem" \
		"${ubuntu_bundle}/slurmd_cert_key.pem" \
		"${mac_bundle}/ca_cert.pem" \
		"${mac_bundle}/slurmd_cert.pem" \
		"${mac_bundle}/slurmd_cert_key.pem" \
		"${ca_private}/ca_cert_key.pem" \
		>"${run_dir}/certificate-permissions.txt" || \
		fail 'cannot capture certificate permissions'

	(
		cd "$run_dir" || exit 1
		tar -cf mac-bundle.tar mac-bundle
	) || fail 'cannot create Mac certificate bundle archive'
	sha256sum "${run_dir}/mac-bundle.tar" \
		>"${run_dir}/mac-bundle.tar.sha256" || fail 'cannot hash Mac archive'

	printf '%s\n' \
		'SMD407_TLS_CERTIFICATE_STAGE_WORKER_COMPLETE chain=PASS server_purpose=PASS client_purpose=PASS key_pairs=PASS sans=PASS expiry=PASS rogue_ca=REJECTED rotation=DIFFERENT'
	exit 0
fi

if [ "${SMD407_TLS_CERTIFICATE_STAGE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_TLS_CERTIFICATE_STAGE_CONFIRMED=YES after approving isolated test certificate generation on Ubuntu' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
stage_user=REDACTED_USER
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-certificate-stage-${run_stamp}

hash_production()
{
	output=$1
	: >"$output" || return 1
	for path in \
		"${prefix}/etc/slurm.conf" \
		"${prefix}/etc/slurmdbd.conf" \
		"${prefix}/etc/gres.conf" \
		"${prefix}/sbin/slurmd" \
		"${prefix}/sbin/slurmctld" \
		"${prefix}/sbin/slurmdbd" \
		"${prefix}/lib/slurm/tls_none.so" \
		"${prefix}/lib/slurm/tls_s2n.so"; do
		[ -f "$path" ] || continue
		sha256sum "$path" >>"$output" || return 1
	done
}

[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Linux ] || fail 'this certificate stage is for Ubuntu'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
id "$stage_user" >/dev/null 2>&1 || fail "missing stage user=$stage_user"
for required in "$slurm_conf" "$scontrol" "$squeue" /usr/bin/openssl; do
	[ -e "$required" ] || fail "missing $required"
done
for command_name in awk cmp diff find grep sha256sum stat systemctl tar; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done

umask 077
mkdir "$run_dir" || fail 'cannot create run directory'
chown "$stage_user" "$run_dir" || fail 'cannot assign run directory to stage user'
printf 'mode=ISOLATED_TEST_CERTIFICATE_STAGE run_dir=%s stage_user=%s\n' \
	"$run_dir" "$stage_user"
hash_production "${run_dir}/production-before.sha256" || \
	fail 'cannot hash production inputs'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-before.txt" || fail 'cannot capture service identities'

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || \
	fail 'controller ping failed'
grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node ubuntu >"${run_dir}/ubuntu-before.txt" || \
	fail 'cannot read Ubuntu node'
"$scontrol" show node PC-210 >"${run_dir}/mac-before.txt" || \
	fail 'cannot read Mac node'
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-before.txt" || \
	fail 'cannot read queue'
[ "$(node_field State "${run_dir}/ubuntu-before.txt")" = IDLE ] || \
	fail 'ubuntu is not IDLE'
[ "$(node_field State "${run_dir}/mac-before.txt")" = IDLE ] || \
	fail 'PC-210 is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/ubuntu-before.txt")" = 0 ] || \
	fail 'ubuntu CPUAlloc is not zero'
[ "$(node_field CPUAlloc "${run_dir}/mac-before.txt")" = 0 ] || \
	fail 'PC-210 CPUAlloc is not zero'
[ ! -s "${run_dir}/queue-before.txt" ] || fail 'target nodes have queued jobs'

chown "$stage_user" "${run_dir}"/*
(
	cd /tmp || exit 1
	sudo -u "$stage_user" -H env \
		SMD407_TLS_CERTIFICATE_STAGE_CONFIRMED=YES \
		/bin/sh "$0" worker "$run_dir"
) || fail 'isolated certificate worker failed'

hash_production "${run_dir}/production-after.sha256" || \
	fail 'cannot hash production inputs after staging'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-after.txt" || fail 'cannot capture final service identities'
cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production inputs changed'
cmp -s "${run_dir}/services-before.txt" "${run_dir}/services-after.txt" || \
	fail 'service identities changed'
"$scontrol" show node ubuntu >"${run_dir}/ubuntu-after.txt" || \
	fail 'cannot read final Ubuntu node'
"$scontrol" show node PC-210 >"${run_dir}/mac-after.txt" || \
	fail 'cannot read final Mac node'
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-after.txt" || \
	fail 'cannot read final queue'
[ "$(node_field State "${run_dir}/ubuntu-after.txt")" = IDLE ] || \
	fail 'ubuntu final state is not IDLE'
[ "$(node_field State "${run_dir}/mac-after.txt")" = IDLE ] || \
	fail 'PC-210 final state is not IDLE'
[ ! -s "${run_dir}/queue-after.txt" ] || fail 'target nodes have final queued jobs'

mac_archive_hash=$(awk '{print $1}' "${run_dir}/mac-bundle.tar.sha256")
printf '%s\n' \
	"SMD407_TLS_CERTIFICATE_STAGE_COMPLETE mac_archive=${run_dir}/mac-bundle.tar mac_archive_hash=${mac_archive_hash} ca_private=UBUNTU_ONLY chain=PASS purposes=serverAuth,clientAuth sans=PASS rogue_ca=REJECTED rotation=STAGED production_unchanged=PASS services_unchanged=PASS nodes=IDLE queue=EMPTY run_dir=${run_dir}"
