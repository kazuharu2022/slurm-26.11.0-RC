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
	hermetic_patch=$5
	commit=d25ca63bef1bc12daf2c92ffe2ad86a1689c6997
	tar_hash=061a772e9da0e17d89b4c5ad71aaa333a70aa19c303bf70c792c862d90f13029
	proper_ca_patch_hash=73075cbc0d8eb6c08b221bbd1f38d9b9c6b7d331c25d36bb4c1ca6da76b17ee3
	hermetic_patch_hash=d0be4079436fc8afbb662609d220ec58110f5b19a20ca41c06172922161381cb
	original_test_hash=7513ce7c3d87cb8aa65587a9d00d6cd7e48ff80c2aee5a6d0c7c10425d01f3a4
	patched_test_hash=4abea977da8432558b56b2a8827bc79ebc58a758f128a1ef87e105fb107c2927
	ca_pem_hash=dc33004948bb7dcc5d43d8301e5de02cadc9f821cb9cdd4a013848fcabd7e004
	leaf_pem_hash=4569cd4314a4749ffa03c6291cdbf36c6618daf89bb2532d6df15b8df068729d
	ca_der_hash=f51d638243e7879b64b5840515690301e4878c9f31cbd61be10d08c32530b624
	built_system_ca_der_hash=8e3cda7b1aabdb0f64ae99291ea30b1329622c1810b42b0ab16c5acfe4a7b534
	cmake=${attempt_dir}/cmake-env/bin/cmake
	ctest=${attempt_dir}/cmake-env/bin/ctest
	s2n_tar=${attempt_dir}/s2n-tls-${commit}.tar.gz
	s2n_source=${run_dir}/s2n-tls-${commit}
	s2n_build=${run_dir}/s2n-build
	test_source=${s2n_source}/tests/unit/s2n_self_talk_certificates_test.c
	ca=${s2n_source}/tests/pems/rsa_pss_2048_sha256_CA_cert.pem
	leaf=${s2n_source}/tests/pems/rsa_pss_2048_sha256_leaf_cert.pem
	jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1)

	[ "${SMD407_HERMETIC_TRUST_REVALIDATION_CONFIRMED:-}" = YES ] || \
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
	printf '%s  %s\n' "$hermetic_patch_hash" "$hermetic_patch" |
		sha256sum -c - >"${run_dir}/hermetic-patch.verify" 2>&1 || \
		fail 'hermetic trust patch hash mismatch'

	umask 022
	printf 'worker_user=%s uid=%s gid=%s jobs=%s\n' \
		"$(id -un)" "$(id -u)" "$(id -g)" "$jobs"

	tar -xzf "$s2n_tar" -C "$run_dir" || fail 'cannot extract s2n-tls source'
	[ -d "$s2n_source" ] || fail "missing extracted source=$s2n_source"
	printf '%s  %s\n' "$original_test_hash" "$test_source" |
		sha256sum -c - >"${run_dir}/original-test.verify" 2>&1 || \
		fail 'original test source hash mismatch'
	printf '%s  %s\n' "$ca_pem_hash" "$ca" |
		sha256sum -c - >"${run_dir}/ca-pem.verify" 2>&1 || \
		fail 'CA fixture PEM hash mismatch'
	printf '%s  %s\n' "$leaf_pem_hash" "$leaf" |
		sha256sum -c - >"${run_dir}/leaf-pem.verify" 2>&1 || \
		fail 'leaf fixture PEM hash mismatch'

	openssl x509 -in "$ca" -outform DER -out "${run_dir}/proper-ca.der" || \
		fail 'cannot convert proper CA fixture to DER'
	printf '%s  %s\n' "$ca_der_hash" "${run_dir}/proper-ca.der" |
		sha256sum -c - >"${run_dir}/proper-ca-der.verify" 2>&1 || \
		fail 'proper CA fixture DER hash mismatch'

	openssl verify -verbose -show_chain -purpose sslserver \
		-no-CApath -no-CAstore -CAfile "$ca" "$leaf" \
		>"${run_dir}/proper-only-verify.out" \
		2>"${run_dir}/proper-only-verify.err" || \
		fail 'proper-only CA-chain verification failed'

	system_verify_rc=0
	openssl verify -verbose -show_chain -purpose sslserver \
		-no-CAfile -no-CAstore -CApath /etc/ssl/certs "$leaf" \
		>"${run_dir}/system-only-verify.out" \
		2>"${run_dir}/system-only-verify.err" || system_verify_rc=$?
	[ "$system_verify_rc" -ne 0 ] || fail 'system-only verification unexpectedly passed'
	cat "${run_dir}/system-only-verify.out" "${run_dir}/system-only-verify.err" |
		grep -q 'certificate signature failure' || \
		fail 'system-only failure signature changed'
	printf 'system_only_verify_rc=%s\n' "$system_verify_rc" \
		>"${run_dir}/system-only-verify.rc"

	cp "$test_source" "${run_dir}/test-source.before" || \
		fail 'cannot preserve original test source'
	patch -d "$s2n_source" -p1 --forward --batch <"$proper_ca_patch" \
		>"${run_dir}/proper-ca-patch.out" 2>"${run_dir}/proper-ca-patch.err" || \
		fail 'cannot apply proper-CA patch'
	patch -d "$s2n_source" -p1 --forward --batch <"$hermetic_patch" \
		>"${run_dir}/hermetic-patch.out" 2>"${run_dir}/hermetic-patch.err" || \
		fail 'cannot apply hermetic trust patch'
	printf '%s  %s\n' "$patched_test_hash" "$test_source" |
		sha256sum -c - >"${run_dir}/patched-test.verify" 2>&1 || \
		fail 'patched test source hash mismatch'

	diff_rc=0
	diff -u "${run_dir}/test-source.before" "$test_source" \
		>"${run_dir}/test-source.diff" || diff_rc=$?
	[ "$diff_rc" -eq 1 ] || fail 'unexpected test source diff result'
	[ "$(grep -c 's2n_config_wipe_trust_store(config)' "$test_source")" -eq 1 ] || \
		fail 'hermetic trust wipe count mismatch'

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
		fail 'hermetic target build failed'

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
		>"${run_dir}/hermetic-ctest.out" 2>"${run_dir}/hermetic-ctest.err" || \
		ctest_rc=$?
	printf 'ctest_rc=%s\n' "$ctest_rc" >"${run_dir}/hermetic-ctest.rc"
	cat "${run_dir}/hermetic-ctest.out" "${run_dir}/hermetic-ctest.err"
	[ "$ctest_rc" -eq 0 ] || fail 'hermetic targeted CTest failed'
	grep -Eq \
		'^[[:space:]]*1/1 Test #[0-9]+: s2n_self_talk_certificates_test .*Passed' \
		"${run_dir}/hermetic-ctest.out" || fail 'targeted CTest result mismatch'
	grep -Eq \
		'^[[:space:]]*100% tests passed(, 0 tests failed)? out of 1[[:space:]]*$' \
		"${run_dir}/hermetic-ctest.out" || fail 'targeted CTest summary mismatch'

	printf '%s\n' \
		"system_ca_collision_preserved=YES system_ca_der_sha256=$built_system_ca_der_hash" \
		"hermetic_targeted_test=PASS tests=1 system_trust_wiped=YES" \
		"SMD407_HERMETIC_TRUST_REVALIDATION_WORKER_COMPLETE run_dir=$run_dir" \
		>"${run_dir}/hermetic-summary.txt"
	cat "${run_dir}/hermetic-summary.txt"
	exit 0
fi

if [ "${SMD407_HERMETIC_TRUST_REVALIDATION_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_HERMETIC_TRUST_REVALIDATION_CONFIRMED=YES after approving the isolated hermetic trust-store revalidation' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
attempt_dir=${SMD407_SOURCE_RUN_DIR:-/tmp/slurm-smd407-ubuntu-isolated-build-20260912T184659}
wire_dir=${SMD407_WIRE_RUN_DIR:-/tmp/slurm-smd407-ubuntu-x509-wire-diagnose-20260912T202635}
proper_ca_patch=${SMD407_PROPER_CA_PATCH:-/tmp/smd407_s2n_proper_ca_test.patch}
hermetic_patch=${SMD407_HERMETIC_PATCH:-/tmp/smd407_s2n_hermetic_trust_test.patch}
proper_ca_patch_hash=73075cbc0d8eb6c08b221bbd1f38d9b9c6b7d331c25d36bb4c1ca6da76b17ee3
hermetic_patch_hash=d0be4079436fc8afbb662609d220ec58110f5b19a20ca41c06172922161381cb
built_system_ca_der_hash=8e3cda7b1aabdb0f64ae99291ea30b1329622c1810b42b0ab16c5acfe4a7b534
system_ca=/usr/local/share/ca-certificates/ca.crt
build_user=REDACTED_USER
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-ubuntu-hermetic-trust-${run_stamp}

hash_production()
{
	output=$1
	: >"$output" || return 1
	for production_path in \
		"${prefix}/etc/slurm.conf" \
		"${prefix}/etc/slurmdbd.conf" \
		"${prefix}/etc/gres.conf" \
		"${prefix}/sbin/slurmd" \
		"${prefix}/sbin/slurmctld" \
		"${prefix}/sbin/slurmdbd" \
		"${prefix}/lib/slurm/tls_none.so" \
		"${prefix}/lib/slurm/tls_s2n.so"; do
		[ -f "$production_path" ] || continue
		sha256sum "$production_path" >>"$output" || return 1
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
	"$system_ca" \
	"$proper_ca_patch" \
	"$hermetic_patch" \
	"${attempt_dir}/cmake-env/bin/cmake" \
	"${attempt_dir}/cmake-env/bin/ctest" \
	"${attempt_dir}/s2n-tls-d25ca63bef1bc12daf2c92ffe2ad86a1689c6997.tar.gz" \
	"${wire_dir}/diagnostic-summary.txt" \
	"${wire_dir}/built-chain.txt" \
	"${wire_dir}/production-before.sha256" \
	"${wire_dir}/production-after.sha256"; do
	[ -e "$required" ] || fail "missing $required"
done

for command_name in awk cat chown cmp cp date diff file getconf grep hostname id \
	ldd mkdir openssl patch sed sha256sum sudo systemctl tar uname; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done

for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done

printf '%s  %s\n' "$proper_ca_patch_hash" "$proper_ca_patch" |
	sha256sum -c - >/dev/null 2>&1 || fail 'proper-CA patch hash mismatch'
printf '%s  %s\n' "$hermetic_patch_hash" "$hermetic_patch" |
	sha256sum -c - >/dev/null 2>&1 || fail 'hermetic trust patch hash mismatch'
grep -q 'wire_leaf_identity=MATCH' "${wire_dir}/diagnostic-summary.txt" || \
	fail 'prior wire leaf identity changed'
grep -q 'chain_ca_identity=MISMATCH' "${wire_dir}/diagnostic-summary.txt" || \
	fail 'prior chain CA diagnosis changed'
grep -q "sha256=$built_system_ca_der_hash" "${wire_dir}/built-chain.txt" || \
	fail 'prior built system CA hash changed'
cmp -s "${wire_dir}/production-before.sha256" \
	"${wire_dir}/production-after.sha256" || fail 'prior diagnosis production hash mismatch'

system_ca_der_hash=$(openssl x509 -in "$system_ca" -outform DER 2>/dev/null |
	sha256sum | awk '{print $1}')
[ "$system_ca_der_hash" = "$built_system_ca_der_hash" ] || \
	fail 'system CA collision input changed'

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
printf 'mode=ISOLATED_HERMETIC_TRUST_REVALIDATION run_dir=%s source_run_dir=%s wire_run_dir=%s build_user=%s\n' \
	"$run_dir" "$attempt_dir" "$wire_dir" "$build_user"

hash_production "${run_dir}/production-before.sha256" || \
	fail 'cannot hash production inputs'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-before.txt" || fail 'cannot capture service identities'
sha256sum "$system_ca" >"${run_dir}/system-ca-before.sha256" || \
	fail 'cannot hash system CA input'
cp "$proper_ca_patch" "${run_dir}/smd407_s2n_proper_ca_test.patch" || \
	fail 'cannot copy proper-CA patch'
cp "$hermetic_patch" "${run_dir}/smd407_s2n_hermetic_trust_test.patch" || \
	fail 'cannot copy hermetic trust patch'

build_group=$(id -gn "$build_user")
chown -R "${build_user}:${build_group}" "$run_dir" || \
	fail 'cannot transfer isolated workspace to build user'

sudo -u "$build_user" -H env \
	SMD407_HERMETIC_TRUST_REVALIDATION_CONFIRMED=YES \
	/bin/sh "$0" worker "$run_dir" "$attempt_dir" \
	"${run_dir}/smd407_s2n_proper_ca_test.patch" \
	"${run_dir}/smd407_s2n_hermetic_trust_test.patch" || \
	fail 'isolated hermetic trust revalidation worker failed'

hash_production "${run_dir}/production-after.sha256" || \
	fail 'cannot hash final production inputs'
cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-after.txt" || fail 'cannot capture final service identities'
cmp -s "${run_dir}/services-before.txt" "${run_dir}/services-after.txt" || \
	fail 'service identity changed'
sha256sum -c "${run_dir}/system-ca-before.sha256" \
	>"${run_dir}/system-ca-after.verify" 2>&1 || fail 'system CA input changed'
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'queue is not empty after revalidation'

"$scontrol" show node ubuntu >"${run_dir}/ubuntu-node-final.txt" || \
	fail 'cannot capture final Ubuntu node state'
"$scontrol" show node PC-210 >"${run_dir}/mac-node-final.txt" || \
	fail 'cannot capture final Mac node state'
for node_file in "${run_dir}/ubuntu-node-final.txt" "${run_dir}/mac-node-final.txt"; do
	[ "$(node_field State "$node_file")" = IDLE ] || fail "node is not IDLE: $node_file"
	[ "$(node_field CPUAlloc "$node_file")" = 0 ] || fail "CPU allocation is not zero: $node_file"
	[ "$(node_field AllocMem "$node_file")" = 0 ] || fail "memory allocation is not zero: $node_file"
done

printf '%s\n' \
	"SMD407_HERMETIC_TRUST_REVALIDATION_COMPLETE targeted_test=PASS tests=1 system_ca_collision=PRESERVED system_trust_wiped=TEST_CONFIG_ONLY production_unchanged=PASS services_unchanged=PASS nodes=IDLE queue=EMPTY run_dir=$run_dir"
