#!/bin/sh

set -u

if [ "${SMD407_S2N_CTEST_DIAG_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_S2N_CTEST_DIAG_CONFIRMED=YES after approving this read-only diagnosis' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
attempt_dir=${SMD407_SOURCE_RUN_DIR:-/tmp/slurm-smd407-ubuntu-isolated-build-20260912T184659}
commit=d25ca63bef1bc12daf2c92ffe2ad86a1689c6997
s2n_source=${attempt_dir}/s2n-tls-${commit}
s2n_build=${attempt_dir}/s2n-build
leaf=${s2n_source}/tests/pems/rsa_pss_2048_sha256_leaf_cert.pem
test_source=${s2n_source}/tests/unit/s2n_self_talk_certificates_test.c
validator_source=${s2n_source}/tls/s2n_x509_validator.c
test_binary=${s2n_build}/bin/s2n_self_talk_certificates_test
last_test_log=${s2n_build}/Testing/Temporary/LastTest.log
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
slurm_conf=${prefix}/etc/slurm.conf
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-ubuntu-ctest-diagnose-${run_stamp}

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
[ "$(uname -s)" = Linux ] || fail 'this diagnosis is for Ubuntu'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
for required in \
	"$leaf" \
	"$test_source" \
	"$validator_source" \
	"$test_binary" \
	"$last_test_log" \
	"$slurm_conf" \
	"$scontrol" \
	"$squeue"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_name in awk cat cmp date grep ldd nl openssl readelf sed sha256sum \
	systemctl wc; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done

umask 077
mkdir "$run_dir" || fail 'cannot create run directory'
printf 'mode=READ_ONLY_CTEST_DIAGNOSIS run_dir=%s source_run_dir=%s\n' \
	"$run_dir" "$attempt_dir"

hash_production "${run_dir}/production-before.sha256" || \
	fail 'cannot hash production inputs'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-before.txt" || fail 'cannot capture service identities'

date --iso-8601=seconds >"${run_dir}/date.txt"
openssl version -a >"${run_dir}/openssl-version.txt" 2>&1
openssl list -providers -verbose >"${run_dir}/openssl-providers.txt" 2>&1 || true
if [ -r /proc/sys/crypto/fips_enabled ]; then
	cat /proc/sys/crypto/fips_enabled >"${run_dir}/kernel-fips.txt"
else
	printf '%s\n' ABSENT >"${run_dir}/kernel-fips.txt"
fi

sha256sum "$test_source" "$validator_source" "$leaf" "$test_binary" \
	>"${run_dir}/input-hashes.txt" || fail 'cannot hash diagnostic inputs'
grep -c 'BEGIN CERTIFICATE' "$leaf" >"${run_dir}/leaf-pem-count.txt"
openssl x509 -in "$leaf" -noout \
	-subject -issuer -serial -dates -fingerprint -sha256 \
	>"${run_dir}/leaf-summary.txt" 2>"${run_dir}/leaf-summary.err" || \
	fail 'cannot inspect leaf certificate'
openssl x509 -in "$leaf" -noout -text \
	>"${run_dir}/leaf-text.txt" 2>"${run_dir}/leaf-text.err" || \
	fail 'cannot decode leaf certificate'
openssl x509 -in "$leaf" -noout -purpose \
	>"${run_dir}/leaf-purpose.txt" 2>"${run_dir}/leaf-purpose.err" || true

if openssl verify -verbose -show_chain -purpose sslserver \
	-partial_chain -trusted "$leaf" "$leaf" \
	>"${run_dir}/verify-trusted.out" 2>"${run_dir}/verify-trusted.err"; then
	verify_trusted_rc=0
else
	verify_trusted_rc=$?
fi

if openssl verify -verbose -show_chain -purpose sslserver \
	-partial_chain -CAfile "$leaf" "$leaf" \
	>"${run_dir}/verify-cafile.out" 2>"${run_dir}/verify-cafile.err"; then
	verify_cafile_rc=0
else
	verify_cafile_rc=$?
fi

printf 'verify_trusted_rc=%s\nverify_cafile_rc=%s\n' \
	"$verify_trusted_rc" "$verify_cafile_rc" >"${run_dir}/verify-return-codes.txt"

nl -ba "$test_source" | sed -n '45,145p' >"${run_dir}/test-source-context.txt"
nl -ba "$validator_source" | sed -n '850,900p' \
	>"${run_dir}/validator-source-context.txt"
grep -n -A 18 -B 6 \
	'Handshake failed version=34 cert=../pems/rsa_pss_2048_sha256_leaf_cert.pem' \
	"$last_test_log" >"${run_dir}/failure-context.txt" || \
	fail 'cannot find recorded failure context'

ldd "$test_binary" >"${run_dir}/test-binary-ldd.txt" 2>&1 || \
	fail 'cannot resolve test binary dependencies'
readelf -d "$test_binary" >"${run_dir}/test-binary-dynamic.txt" 2>&1 || \
	fail 'cannot inspect test binary dynamic section'

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
grep -q ' is UP$' "${run_dir}/controller.txt" || fail 'controller is not UP'
"$scontrol" show node ubuntu >"${run_dir}/ubuntu-node.txt" || fail 'Ubuntu node readback failed'
"$scontrol" show node PC-210 >"${run_dir}/mac-node.txt" || fail 'Mac node readback failed'
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue.txt" || fail 'queue readback failed'
grep -q 'State=IDLE' "${run_dir}/ubuntu-node.txt" || fail 'Ubuntu node is not IDLE'
grep -q 'State=IDLE' "${run_dir}/mac-node.txt" || fail 'Mac node is not IDLE'
[ ! -s "${run_dir}/queue.txt" ] || fail 'queue is not empty'

hash_production "${run_dir}/production-after.sha256" || \
	fail 'cannot hash final production inputs'
cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-after.txt" || fail 'cannot capture final service identities'
cmp -s "${run_dir}/services-before.txt" "${run_dir}/services-after.txt" || \
	fail 'service identity changed'

if [ "$verify_trusted_rc" -eq 0 ] && [ "$verify_cafile_rc" -eq 0 ]; then
	classification=CLI_PARTIAL_CHAIN_PASS_TEST_CONTEXT_DIFFERENCE
else
	classification=CLI_PARTIAL_CHAIN_FAILURE_REPRODUCED
fi

printf '%s\n' '[leaf]'
cat "${run_dir}/leaf-summary.txt"
printf '%s\n' '[verify-trusted]'
cat "${run_dir}/verify-trusted.out" "${run_dir}/verify-trusted.err"
printf '%s\n' '[verify-cafile]'
cat "${run_dir}/verify-cafile.out" "${run_dir}/verify-cafile.err"
printf '%s\n' '[crypto-dependency]'
grep -E 'lib(s2n|ssl|crypto)' "${run_dir}/test-binary-ldd.txt" || true
printf '%s\n' \
	"openssl_verify trusted_rc=$verify_trusted_rc cafile_rc=$verify_cafile_rc" \
	"SMD407_UBUNTU_CTEST_DIAG_COMPLETE classification=$classification production_unchanged=PASS services_unchanged=PASS nodes=IDLE queue=EMPTY run_dir=$run_dir"
