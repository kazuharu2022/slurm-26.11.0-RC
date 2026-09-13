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
	[ "$#" -eq 5 ] || fail 'invalid worker arguments'
	run_dir=$2
	attempt_dir=$3
	proper_ca_patch=$4
	x509_probe_patch=$5
	commit=d25ca63bef1bc12daf2c92ffe2ad86a1689c6997
	tar_hash=061a772e9da0e17d89b4c5ad71aaa333a70aa19c303bf70c792c862d90f13029
	proper_ca_patch_hash=73075cbc0d8eb6c08b221bbd1f38d9b9c6b7d331c25d36bb4c1ca6da76b17ee3
	x509_probe_patch_hash=40b91c2bfbbcdde16ef313b02d41773d877b90560e04f92e8b92f726c0577ad3
	original_test_hash=7513ce7c3d87cb8aa65587a9d00d6cd7e48ff80c2aee5a6d0c7c10425d01f3a4
	patched_test_hash=8921dcff9faecee58fd7a131a4550333c4678bfe88b03343201dbadfdc5dcd2b
	original_validator_hash=6aeb8675e6099fa0f6efacb256cde57e24acdc5c60929828155b6e5a0f66408b
	patched_validator_hash=c6474dafdc7046ef631112c96c091ee956b121040e7200f56da534e40bf89d6e
	ca_hash=dc33004948bb7dcc5d43d8301e5de02cadc9f821cb9cdd4a013848fcabd7e004
	leaf_hash=4569cd4314a4749ffa03c6291cdbf36c6618daf89bb2532d6df15b8df068729d
	cmake=${attempt_dir}/cmake-env/bin/cmake
	ctest=${attempt_dir}/cmake-env/bin/ctest
	s2n_tar=${attempt_dir}/s2n-tls-${commit}.tar.gz
	s2n_source=${run_dir}/s2n-tls-${commit}
	s2n_build=${run_dir}/s2n-build
	test_source=${s2n_source}/tests/unit/s2n_self_talk_certificates_test.c
	validator_source=${s2n_source}/tls/s2n_x509_validator.c
	ca=${s2n_source}/tests/pems/rsa_pss_2048_sha256_CA_cert.pem
	leaf=${s2n_source}/tests/pems/rsa_pss_2048_sha256_leaf_cert.pem
	jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1)

	[ "${SMD407_X509_ERROR_DIAG_CONFIRMED:-}" = YES ] || \
		fail 'worker confirmation missing'
	[ "$(id -u)" -ne 0 ] || fail 'worker must not run as root'
	[ -x "$cmake" ] || fail "missing isolated cmake=$cmake"
	[ -x "$ctest" ] || fail "missing isolated ctest=$ctest"
	[ -f "$s2n_tar" ] || fail "missing prior tarball=$s2n_tar"

	printf '%s  %s\n' "$tar_hash" "$s2n_tar" |
		sha256sum -c - >"${run_dir}/s2n-tar.verify" 2>&1 || \
		fail 'prior s2n-tls tarball hash mismatch'
	printf '%s  %s\n' "$proper_ca_patch_hash" "$proper_ca_patch" |
		sha256sum -c - >"${run_dir}/proper-ca-patch.verify" 2>&1 || \
		fail 'proper-CA patch hash mismatch'
	printf '%s  %s\n' "$x509_probe_patch_hash" "$x509_probe_patch" |
		sha256sum -c - >"${run_dir}/x509-probe-patch.verify" 2>&1 || \
		fail 'X509 probe patch hash mismatch'

	umask 022
	printf 'worker_user=%s uid=%s gid=%s jobs=%s\n' \
		"$(id -un)" "$(id -u)" "$(id -g)" "$jobs"

	tar -xzf "$s2n_tar" -C "$run_dir" || fail 'cannot extract s2n-tls source'
	[ -d "$s2n_source" ] || fail "missing extracted source=$s2n_source"

	printf '%s  %s\n' "$original_test_hash" "$test_source" |
		sha256sum -c - >"${run_dir}/original-test.verify" 2>&1 || \
		fail 'original test source hash mismatch'
	printf '%s  %s\n' "$original_validator_hash" "$validator_source" |
		sha256sum -c - >"${run_dir}/original-validator.verify" 2>&1 || \
		fail 'original validator source hash mismatch'
	printf '%s  %s\n' "$ca_hash" "$ca" |
		sha256sum -c - >"${run_dir}/ca.verify" 2>&1 || fail 'CA fixture hash mismatch'
	printf '%s  %s\n' "$leaf_hash" "$leaf" |
		sha256sum -c - >"${run_dir}/leaf.verify" 2>&1 || fail 'leaf fixture hash mismatch'

	cp "$test_source" "${run_dir}/test-source.before" || \
		fail 'cannot preserve original test source'
	cp "$validator_source" "${run_dir}/validator-source.before" || \
		fail 'cannot preserve original validator source'

	patch -d "$s2n_source" -p1 --forward --batch <"$proper_ca_patch" \
		>"${run_dir}/proper-ca-patch.out" 2>"${run_dir}/proper-ca-patch.err" || \
		fail 'cannot apply proper-CA patch'
	patch -d "$s2n_source" -p1 --forward --batch <"$x509_probe_patch" \
		>"${run_dir}/x509-probe-patch.out" 2>"${run_dir}/x509-probe-patch.err" || \
		fail 'cannot apply X509 probe patch'

	printf '%s  %s\n' "$patched_test_hash" "$test_source" |
		sha256sum -c - >"${run_dir}/patched-test.verify" 2>&1 || \
		fail 'patched test source hash mismatch'
	printf '%s  %s\n' "$patched_validator_hash" "$validator_source" |
		sha256sum -c - >"${run_dir}/patched-validator.verify" 2>&1 || \
		fail 'patched validator source hash mismatch'

	diff -u "${run_dir}/test-source.before" "$test_source" \
		>"${run_dir}/test-source.diff" || test_diff_rc=$?
	[ "${test_diff_rc:-0}" -eq 1 ] || fail 'unexpected test source diff result'
	diff -u "${run_dir}/validator-source.before" "$validator_source" \
		>"${run_dir}/validator-source.diff" || validator_diff_rc=$?
	[ "${validator_diff_rc:-0}" -eq 1 ] || fail 'unexpected validator source diff result'

	openssl verify -verbose -show_chain -purpose sslserver \
		-CAfile "$ca" "$leaf" >"${run_dir}/proper-ca-verify.out" \
		2>"${run_dir}/proper-ca-verify.err" || fail 'proper CA-chain verification failed'

	S2N_DONT_MLOCK=1 "$cmake" \
		-S "$s2n_source" \
		-B "$s2n_build" \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_SHARED_LIBS=ON \
		-DCMAKE_PREFIX_PATH=/usr \
		>"${run_dir}/s2n-cmake.out" 2>"${run_dir}/s2n-cmake.err" || \
		fail 's2n-tls cmake configure failed'

	S2N_DONT_MLOCK=1 "$cmake" --build "$s2n_build" \
		--target s2n_self_talk_certificates_test --parallel "$jobs" \
		>"${run_dir}/s2n-target-build.out" 2>"${run_dir}/s2n-target-build.err" || \
		fail 'instrumented target build failed'

	test_binary=${s2n_build}/bin/s2n_self_talk_certificates_test
	[ -x "$test_binary" ] || fail "missing test binary=$test_binary"
	file "$test_binary" >"${run_dir}/test-binary.file" || \
		fail 'cannot inspect test binary'
	ldd "$test_binary" >"${run_dir}/test-binary.ldd" 2>&1 || \
		fail 'cannot inspect test binary dependencies'
	grep -Eq 'ELF 64-bit LSB.*x86-64' "${run_dir}/test-binary.file" || \
		fail 'test binary architecture mismatch'
	if grep -q 'not found' "${run_dir}/test-binary.ldd"; then
		fail 'test binary has unresolved dependency'
	fi
	grep -F "$s2n_build/lib/" "${run_dir}/test-binary.ldd" |
		grep -q 'libs2n\.so' || fail 'test binary does not resolve isolated libs2n'

	ctest_rc=0
	S2N_DONT_MLOCK=1 S2N_PRINT_STACKTRACE=1 CTEST_PARALLEL_LEVEL=1 "$ctest" \
		--test-dir "$s2n_build" \
		-R '^s2n_self_talk_certificates_test$' \
		--output-on-failure \
		>"${run_dir}/x509-probe-ctest.out" 2>"${run_dir}/x509-probe-ctest.err" || \
		ctest_rc=$?
	printf 'ctest_rc=%s\n' "$ctest_rc" >"${run_dir}/x509-probe-ctest.rc"
	[ "$ctest_rc" -ne 0 ] || fail 'instrumented test unexpectedly passed'
	grep -q '0% tests passed, 1 tests failed out of 1' \
		"${run_dir}/x509-probe-ctest.out" || fail 'instrumented CTest summary mismatch'
	grep -q 'Handshake failed version=34 cert=../pems/rsa_pss_2048_sha256_leaf_cert.pem' \
		"${run_dir}/x509-probe-ctest.out" || fail 'failure signature changed'
	grep -q 'SMD407_X509_VERIFY_ERROR code=' \
		"${run_dir}/x509-probe-ctest.out" || fail 'raw X509 error marker not captured'

	diagnostic_line=$(awk '/SMD407_X509_VERIFY_ERROR code=/ {print; exit}' \
		"${run_dir}/x509-probe-ctest.out")
	printf '%s\n' \
		"targeted_test=EXPECTED_FAILURE ctest_rc=$ctest_rc" \
		"x509_diagnostic=$diagnostic_line" \
		"SMD407_X509_ERROR_DIAG_WORKER_COMPLETE run_dir=$run_dir"
	exit 0
fi

if [ "${SMD407_X509_ERROR_DIAG_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_X509_ERROR_DIAG_CONFIRMED=YES after approving the isolated X509 error instrumentation' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
attempt_dir=${SMD407_SOURCE_RUN_DIR:-/tmp/slurm-smd407-ubuntu-isolated-build-20260912T184659}
failure_dir=${SMD407_FAILURE_RUN_DIR:-/tmp/slurm-smd407-ubuntu-isolated-resume-20260912T194134}
proper_ca_patch=${SMD407_PROPER_CA_PATCH:-/tmp/smd407_s2n_proper_ca_test.patch}
x509_probe_patch=${SMD407_X509_PROBE_PATCH:-/tmp/smd407_s2n_x509_error_probe.patch}
proper_ca_patch_hash=73075cbc0d8eb6c08b221bbd1f38d9b9c6b7d331c25d36bb4c1ca6da76b17ee3
x509_probe_patch_hash=40b91c2bfbbcdde16ef313b02d41773d877b90560e04f92e8b92f726c0577ad3
build_user=REDACTED_USER
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-ubuntu-x509-diagnose-${run_stamp}

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
[ "$(uname -s)" = Linux ] || fail 'this driver is for Ubuntu'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
id "$build_user" >/dev/null 2>&1 || fail "missing build user=$build_user"

for required in \
	"$slurm_conf" \
	"$scontrol" \
	"$squeue" \
	"$proper_ca_patch" \
	"$x509_probe_patch" \
	"${attempt_dir}/cmake-env/bin/cmake" \
	"${attempt_dir}/cmake-env/bin/ctest" \
	"${attempt_dir}/s2n-tls-d25ca63bef1bc12daf2c92ffe2ad86a1689c6997.tar.gz" \
	"${failure_dir}/proper-ca-ctest.out" \
	"${failure_dir}/s2n-build/Testing/Temporary/LastTestsFailed.log"; do
	[ -e "$required" ] || fail "missing $required"
done

for command_name in awk cat chown cmp cp date diff file getconf grep hostname id \
	ldd mkdir openssl patch sha256sum sudo systemctl tar uname; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done

for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done

printf '%s  %s\n' "$proper_ca_patch_hash" "$proper_ca_patch" |
	sha256sum -c - >/dev/null 2>&1 || fail 'proper-CA patch hash mismatch'
printf '%s  %s\n' "$x509_probe_patch_hash" "$x509_probe_patch" |
	sha256sum -c - >/dev/null 2>&1 || fail 'X509 probe patch hash mismatch'
[ "$(cat "${failure_dir}/s2n-build/Testing/Temporary/LastTestsFailed.log")" = \
	'192:s2n_self_talk_certificates_test' ] || fail 'prior failed-test set changed'
grep -q '0% tests passed, 1 tests failed out of 1' \
	"${failure_dir}/proper-ca-ctest.out" || fail 'prior targeted CTest summary changed'
grep -q 'Handshake failed version=34 cert=../pems/rsa_pss_2048_sha256_leaf_cert.pem' \
	"${failure_dir}/proper-ca-ctest.out" || fail 'prior failure signature changed'

export SLURM_CONF="$slurm_conf"
controller_output=$("$scontrol" ping 2>&1) || fail 'controller ping failed'
printf '%s\n' "$controller_output" | grep -q ' is UP$' || fail 'controller is not UP'
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'Slurm queue is not empty'

for node_name in ubuntu PC-210; do
	node_output=$("$scontrol" show node "$node_name") || fail "cannot read node=$node_name"
	node_state=$(printf '%s\n' "$node_output" | awk '
	{
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^State=/) {
				sub(/^State=/, "", $i)
				print $i
				exit
			}
		}
	}')
	[ "$node_state" = IDLE ] || fail "node=$node_name is not IDLE: $node_state"
	printf '%s\n' "$node_output" | grep -q 'CPUAlloc=0' || \
		fail "node=$node_name CPU allocation is not zero"
	printf '%s\n' "$node_output" | grep -q 'AllocMem=0' || \
		fail "node=$node_name memory allocation is not zero"
done

umask 077
mkdir "$run_dir" || fail 'cannot create run directory'
printf 'mode=ISOLATED_X509_ERROR_DIAGNOSIS run_dir=%s source_run_dir=%s failure_run_dir=%s build_user=%s\n' \
	"$run_dir" "$attempt_dir" "$failure_dir" "$build_user"

hash_production "${run_dir}/production-before.sha256" || \
	fail 'cannot hash production inputs'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-before.txt" || fail 'cannot capture service identities'
cp "$proper_ca_patch" "${run_dir}/smd407_s2n_proper_ca_test.patch" || \
	fail 'cannot copy proper-CA patch'
cp "$x509_probe_patch" "${run_dir}/smd407_s2n_x509_error_probe.patch" || \
	fail 'cannot copy X509 probe patch'

build_group=$(id -gn "$build_user")
chown -R "${build_user}:${build_group}" "$run_dir" || \
	fail 'cannot transfer isolated workspace to build user'

sudo -u "$build_user" -H env \
	SMD407_X509_ERROR_DIAG_CONFIRMED=YES \
	/bin/sh "$0" worker "$run_dir" "$attempt_dir" \
	"${run_dir}/smd407_s2n_proper_ca_test.patch" \
	"${run_dir}/smd407_s2n_x509_error_probe.patch" || \
	fail 'isolated X509 diagnostic worker failed'

hash_production "${run_dir}/production-after.sha256" || \
	fail 'cannot hash final production inputs'
cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-after.txt" || fail 'cannot capture final service identities'
cmp -s "${run_dir}/services-before.txt" "${run_dir}/services-after.txt" || \
	fail 'service identity changed'
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'queue is not empty after diagnosis'

"$scontrol" show node ubuntu >"${run_dir}/ubuntu-node-final.txt" || \
	fail 'cannot capture final Ubuntu node state'
"$scontrol" show node PC-210 >"${run_dir}/mac-node-final.txt" || \
	fail 'cannot capture final Mac node state'
for node_file in "${run_dir}/ubuntu-node-final.txt" "${run_dir}/mac-node-final.txt"; do
	[ "$(node_field State "$node_file")" = IDLE ] || fail "node is not IDLE: $node_file"
	[ "$(node_field CPUAlloc "$node_file")" = 0 ] || fail "CPU allocation is not zero: $node_file"
	[ "$(node_field AllocMem "$node_file")" = 0 ] || fail "memory allocation is not zero: $node_file"
done

diagnostic_line=$(awk '/SMD407_X509_VERIFY_ERROR code=/ {print; exit}' \
	"${run_dir}/x509-probe-ctest.out")
printf '%s\n' \
	"SMD407_X509_ERROR_DIAG_COMPLETE $diagnostic_line" \
	"production_unchanged=PASS services_unchanged=PASS nodes=IDLE queue=EMPTY" \
	"official_ctest=283/284 targeted_proper_ca=0/1 preserved=YES run_dir=$run_dir"
