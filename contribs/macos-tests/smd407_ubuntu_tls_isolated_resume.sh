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
	[ "$#" -eq 6 ] || fail 'invalid worker arguments'
	run_dir=$2
	source_copy=$3
	attempt_dir=$4
	proper_ca_patch=$5
	hermetic_patch=$6
	commit=d25ca63bef1bc12daf2c92ffe2ad86a1689c6997
	tar_hash=061a772e9da0e17d89b4c5ad71aaa333a70aa19c303bf70c792c862d90f13029
	proper_ca_patch_hash=73075cbc0d8eb6c08b221bbd1f38d9b9c6b7d331c25d36bb4c1ca6da76b17ee3
	hermetic_patch_hash=d0be4079436fc8afbb662609d220ec58110f5b19a20ca41c06172922161381cb
	original_test_hash=7513ce7c3d87cb8aa65587a9d00d6cd7e48ff80c2aee5a6d0c7c10425d01f3a4
	patched_test_hash=4abea977da8432558b56b2a8827bc79ebc58a758f128a1ef87e105fb107c2927
	ca_hash=dc33004948bb7dcc5d43d8301e5de02cadc9f821cb9cdd4a013848fcabd7e004
	leaf_hash=4569cd4314a4749ffa03c6291cdbf36c6618daf89bb2532d6df15b8df068729d
	final_s2n_prefix=/usr/local/slurm/26.11.0/lib/slurm-s2n-1.7.9
	cmake=${attempt_dir}/cmake-env/bin/cmake
	ctest=${attempt_dir}/cmake-env/bin/ctest
	s2n_tar=${attempt_dir}/s2n-tls-${commit}.tar.gz
	s2n_source=${run_dir}/s2n-tls-${commit}
	s2n_build=${run_dir}/s2n-build
	stage_root=${run_dir}/stage
	staged_s2n=${stage_root}${final_s2n_prefix}
	slurm_build=${run_dir}/slurm-build
	test_source=${s2n_source}/tests/unit/s2n_self_talk_certificates_test.c
	ca=${s2n_source}/tests/pems/rsa_pss_2048_sha256_CA_cert.pem
	leaf=${s2n_source}/tests/pems/rsa_pss_2048_sha256_leaf_cert.pem
	jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1)

	[ "${SMD407_TLS_ISOLATED_RESUME_CONFIRMED:-}" = YES ] || \
		fail 'worker confirmation missing'
	[ "$(id -u)" -ne 0 ] || fail 'worker must not run as root'
	[ -x "$cmake" ] || fail "missing isolated cmake=$cmake"
	[ -x "$ctest" ] || fail "missing isolated ctest=$ctest"
	[ -f "$s2n_tar" ] || fail "missing prior tarball=$s2n_tar"
	[ -f "$proper_ca_patch" ] || fail "missing proper-CA patch=$proper_ca_patch"
	[ -f "$hermetic_patch" ] || fail "missing hermetic patch=$hermetic_patch"
	[ -f "${source_copy}/configure" ] || fail 'missing staged Slurm configure'

	printf '%s  %s\n' "$tar_hash" "$s2n_tar" |
		sha256sum -c - >"${run_dir}/s2n-tar.verify" 2>&1 || \
		fail 'prior s2n-tls tarball hash mismatch'
	printf '%s  %s\n' "$proper_ca_patch_hash" "$proper_ca_patch" |
		sha256sum -c - >"${run_dir}/proper-ca-patch.verify" 2>&1 || \
		fail 'proper-CA test patch hash mismatch'
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
	printf '%s  %s\n' "$ca_hash" "$ca" |
		sha256sum -c - >"${run_dir}/ca.verify" 2>&1 || fail 'CA fixture hash mismatch'
	printf '%s  %s\n' "$leaf_hash" "$leaf" |
		sha256sum -c - >"${run_dir}/leaf.verify" 2>&1 || fail 'leaf fixture hash mismatch'

	openssl verify -verbose -show_chain -purpose sslserver \
		-CAfile "$ca" "$leaf" >"${run_dir}/proper-ca-verify.out" \
		2>"${run_dir}/proper-ca-verify.err" || fail 'proper CA-chain verification failed'
	cp "$test_source" "${run_dir}/s2n_self_talk_certificates_test.c.before" || \
		fail 'cannot preserve original test source'
	patch -d "$s2n_source" -p1 --forward --batch <"$proper_ca_patch" \
		>"${run_dir}/proper-ca-patch.out" 2>"${run_dir}/proper-ca-patch.err" || \
		fail 'cannot apply proper-CA test patch'
	patch -d "$s2n_source" -p1 --forward --batch <"$hermetic_patch" \
		>"${run_dir}/hermetic-patch.out" 2>"${run_dir}/hermetic-patch.err" || \
		fail 'cannot apply hermetic trust patch'
	printf '%s  %s\n' "$patched_test_hash" "$test_source" |
		sha256sum -c - >"${run_dir}/patched-test.verify" 2>&1 || \
		fail 'patched test source hash mismatch'
	diff -u "${run_dir}/s2n_self_talk_certificates_test.c.before" "$test_source" \
		>"${run_dir}/test-source.diff" || diff_rc=$?
	[ "${diff_rc:-0}" -eq 1 ] || fail 'unexpected test source diff result'

	S2N_DONT_MLOCK=1 "$cmake" \
		-S "$s2n_source" \
		-B "$s2n_build" \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_SHARED_LIBS=ON \
		-DCMAKE_PREFIX_PATH=/usr \
		-DCMAKE_INSTALL_PREFIX="$final_s2n_prefix" \
		>"${run_dir}/s2n-cmake.out" 2>"${run_dir}/s2n-cmake.err" || \
		fail 's2n-tls cmake configure failed'

	S2N_DONT_MLOCK=1 "$cmake" --build "$s2n_build" --parallel "$jobs" \
		>"${run_dir}/s2n-build.out" 2>"${run_dir}/s2n-build.err" || \
		fail 's2n-tls build failed'

	S2N_DONT_MLOCK=1 CTEST_PARALLEL_LEVEL=1 "$ctest" \
		--test-dir "$s2n_build" \
		-R '^s2n_self_talk_certificates_test$' \
		--output-on-failure \
		>"${run_dir}/hermetic-ctest.out" 2>"${run_dir}/hermetic-ctest.err" || \
		fail 'hermetic targeted s2n handshake test failed'
	grep -Eq \
		'^[[:space:]]*1/1 Test #[0-9]+: s2n_self_talk_certificates_test .*Passed' \
		"${run_dir}/hermetic-ctest.out" || fail 'targeted CTest result mismatch'
	grep -Eq \
		'^[[:space:]]*100% tests passed(, 0 tests failed)? out of 1[[:space:]]*$' \
		"${run_dir}/hermetic-ctest.out" || fail 'targeted CTest summary mismatch'

	mkdir "$stage_root" || fail 'cannot create staging root'
	DESTDIR="$stage_root" "$cmake" --install "$s2n_build" \
		>"${run_dir}/s2n-install.out" 2>"${run_dir}/s2n-install.err" || \
		fail 's2n-tls staged install failed'
	[ -f "${staged_s2n}/include/s2n.h" ] || fail 'staged s2n header missing'
	[ -f "${staged_s2n}/lib/libs2n.so" ] || fail 'staged shared s2n library missing'

	mkdir "$slurm_build" || fail 'cannot create Slurm build directory'
(
	cd "$slurm_build" || exit 1
	"${source_copy}/configure" \
		--prefix=/usr/local/slurm/26.11.0 \
		--with-s2n="$staged_s2n"
) >"${run_dir}/slurm-configure.out" \
	2>"${run_dir}/slurm-configure.err" || fail 'Slurm configure with s2n failed'

	grep -q '^#define HAVE_S2N 1$' "${slurm_build}/config.h" || \
		fail 'Slurm configure did not enable HAVE_S2N'
	grep -q 'S\["WITH_S2N_TRUE"\]=""' "${slurm_build}/config.status" || \
		fail 'Slurm configure did not enable WITH_S2N'

	make -C "${slurm_build}/src/plugins/tls/s2n" \
		S2N_CPPFLAGS="-I${staged_s2n}/include" \
		S2N_LDFLAGS="-Wl,-rpath -Wl,${final_s2n_prefix}/lib -L${staged_s2n}/lib" \
		S2N_LIBS=-ls2n V=1 \
		>"${run_dir}/slurm-plugin-build.out" \
		2>"${run_dir}/slurm-plugin-build.err" || fail 'tls/s2n plugin build failed'

	plugin=${slurm_build}/src/plugins/tls/s2n/.libs/tls_s2n.so
	[ -f "$plugin" ] || fail "missing plugin=$plugin"
	mkdir "${run_dir}/artifacts" || fail 'cannot create artifact directory'
	cp "$plugin" "${run_dir}/artifacts/tls_s2n.so" || fail 'cannot stage plugin artifact'
	cp -R "$staged_s2n" "${run_dir}/artifacts/s2n-prefix" || \
		fail 'cannot stage s2n prefix artifact'
	cp "$proper_ca_patch" "${run_dir}/artifacts/smd407_s2n_proper_ca_test.patch" || \
		fail 'cannot stage proper-CA test patch'
	cp "$hermetic_patch" "${run_dir}/artifacts/smd407_s2n_hermetic_trust_test.patch" || \
		fail 'cannot stage hermetic trust patch'

	file "$plugin" >"${run_dir}/plugin-file.txt"
	grep -Eq 'ELF 64-bit LSB.*x86-64' "${run_dir}/plugin-file.txt" || \
		fail 'plugin architecture is not x86-64 ELF'
	readelf -d "$plugin" >"${run_dir}/plugin-dynamic.txt" 2>&1 || \
		fail 'cannot inspect plugin dynamic section'
	LD_LIBRARY_PATH="${staged_s2n}/lib" ldd "$plugin" \
		>"${run_dir}/plugin-ldd.txt" 2>&1 || fail 'plugin dependency resolution failed'
	if grep -q 'not found' "${run_dir}/plugin-ldd.txt"; then
		fail 'plugin has an unresolved dynamic dependency'
	fi
	nm -D "$plugin" >"${run_dir}/plugin-symbols.txt" 2>&1 || \
		fail 'cannot inspect plugin symbols'
	grep -q "${final_s2n_prefix}/lib" "${run_dir}/plugin-dynamic.txt" || \
		fail 'plugin lacks final s2n RUNPATH'
	grep -q 'libs2n\.so' "${run_dir}/plugin-ldd.txt" || \
		fail 'plugin does not resolve staged libs2n'
	grep -q 'plugin_type' "${run_dir}/plugin-symbols.txt" || \
		fail 'plugin metadata symbol missing'

	sha256sum \
		"${run_dir}/artifacts/tls_s2n.so" \
		"${run_dir}/artifacts/s2n-prefix/lib/libs2n.so" \
		"${run_dir}/artifacts/smd407_s2n_proper_ca_test.patch" \
		"${run_dir}/artifacts/smd407_s2n_hermetic_trust_test.patch" \
		>"${run_dir}/artifact-hashes.txt" || fail 'cannot hash artifacts'

	printf '%s\n' \
		"hermetic_targeted_test=PASS tests=1 system_trust_wiped=TEST_CONFIG_ONLY official_ctest_preserved=283/284" \
		"SMD407_UBUNTU_TLS_ISOLATED_RESUME_WORKER_COMPLETE plugin=$plugin staged_s2n=$staged_s2n"
	exit 0
fi

if [ "${SMD407_TLS_ISOLATED_RESUME_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_TLS_ISOLATED_RESUME_CONFIRMED=YES after approving the bounded hermetic revalidation and isolated plugin build' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
attempt_dir=${SMD407_SOURCE_RUN_DIR:-/tmp/slurm-smd407-ubuntu-isolated-build-20260912T184659}
proper_ca_patch=${SMD407_PROPER_CA_PATCH:-/tmp/smd407_s2n_proper_ca_test.patch}
hermetic_patch=${SMD407_HERMETIC_PATCH:-/tmp/smd407_s2n_hermetic_trust_test.patch}
proper_ca_patch_hash=73075cbc0d8eb6c08b221bbd1f38d9b9c6b7d331c25d36bb4c1ca6da76b17ee3
hermetic_patch_hash=d0be4079436fc8afbb662609d220ec58110f5b19a20ca41c06172922161381cb
commit=d25ca63bef1bc12daf2c92ffe2ad86a1689c6997
build_user=REDACTED_USER
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-ubuntu-isolated-resume-${run_stamp}
source_copy=${run_dir}/slurm-source

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
	"$hermetic_patch" \
	"${attempt_dir}/cmake-env/bin/cmake" \
	"${attempt_dir}/cmake-env/bin/ctest" \
	"${attempt_dir}/s2n-tls-${commit}.tar.gz" \
	"${attempt_dir}/slurm-source.tar" \
	"${attempt_dir}/s2n-ctest.out" \
	"${attempt_dir}/s2n-build/Testing/Temporary/LastTestsFailed.log" \
	"${attempt_dir}/s2n-build/Testing/Temporary/LastTest.log"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_name in awk cat chown cmp cp diff file getconf grep hostname id ldd \
	make mkdir nm openssl patch readelf sha256sum sudo systemctl tar uname; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done

printf '%s  %s\n' "$proper_ca_patch_hash" "$proper_ca_patch" |
	sha256sum -c - >/dev/null 2>&1 || fail 'proper-CA patch hash mismatch'
printf '%s  %s\n' "$hermetic_patch_hash" "$hermetic_patch" |
	sha256sum -c - >/dev/null 2>&1 || fail 'hermetic trust patch hash mismatch'
[ "$(cat "${attempt_dir}/s2n-build/Testing/Temporary/LastTestsFailed.log")" = \
	'192:s2n_self_talk_certificates_test' ] || fail 'Attempt 1 failed-test set changed'
grep -q '99% tests passed, 1 tests failed out of 284' \
	"${attempt_dir}/s2n-ctest.out" || fail 'Attempt 1 CTest summary changed'
grep -q 'Handshake failed version=34 cert=../pems/rsa_pss_2048_sha256_leaf_cert.pem' \
	"${attempt_dir}/s2n-build/Testing/Temporary/LastTest.log" || \
	fail 'Attempt 1 certificate failure signature changed'
grep -q "Error Message: 'Certificate is untrusted'" \
	"${attempt_dir}/s2n-build/Testing/Temporary/LastTest.log" || \
	fail 'Attempt 1 error classification changed'

export SLURM_CONF="$slurm_conf"
controller_output=$("$scontrol" ping 2>&1) || fail 'controller ping failed'
printf '%s\n' "$controller_output" | grep -q ' is UP$' || fail 'controller is not UP'
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'Slurm queue is not empty'

for node_name in ubuntu PC-210; do
	node_output=$("$scontrol" show node "$node_name") || \
		fail "cannot read node=$node_name"
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
printf 'mode=ISOLATED_HERMETIC_PLUGIN_BUILD run_dir=%s source_run_dir=%s build_user=%s\n' \
	"$run_dir" "$attempt_dir" "$build_user"

hash_production "${run_dir}/production-before.sha256" || \
	fail 'cannot hash production inputs'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-before.txt" || fail 'cannot capture service identities'
cp "$proper_ca_patch" "${run_dir}/smd407_s2n_proper_ca_test.patch" || \
	fail 'cannot copy proper-CA test patch'
cp "$hermetic_patch" "${run_dir}/smd407_s2n_hermetic_trust_test.patch" || \
	fail 'cannot copy hermetic trust patch'
mkdir "$source_copy" || fail 'cannot create Slurm source directory'
tar -xf "${attempt_dir}/slurm-source.tar" -C "$source_copy" || \
	fail 'cannot extract prior Slurm source snapshot'

printf '%s  %s\n' a68de909de86a07af82f4c5618806fcc915d70d67a9890f66ad2e0a741bd9846 \
	"${source_copy}/configure" | sha256sum -c - >/dev/null || fail 'configure hash mismatch'
printf '%s  %s\n' a573b53121b7657e71f0efe5ae3bd7e993a3a63c7db568b86a74e287b61b6b5e \
	"${source_copy}/configure.ac" | sha256sum -c - >/dev/null || fail 'configure.ac hash mismatch'
printf '%s  %s\n' 15a514973455082a970caa4ba752de8e85fede616a4414ddb9e08b99f5114e2d \
	"${source_copy}/config.h.in" | sha256sum -c - >/dev/null || fail 'config.h.in hash mismatch'
printf '%s  %s\n' 4c2f79c1bec5dbe87f4b442415e03a9c2d3d7cf45a70b4a2dd30aac3cf3498a6 \
	"${source_copy}/src/plugins/tls/s2n/tls_s2n.c" | sha256sum -c - >/dev/null || \
	fail 'tls_s2n.c hash mismatch'

build_group=$(id -gn "$build_user")
chown -R "${build_user}:${build_group}" "$run_dir" || \
	fail 'cannot transfer isolated workspace to build user'

sudo -u "$build_user" -H env \
	SMD407_TLS_ISOLATED_RESUME_CONFIRMED=YES \
	/bin/sh "$0" worker "$run_dir" "$source_copy" "$attempt_dir" \
	"${run_dir}/smd407_s2n_proper_ca_test.patch" \
	"${run_dir}/smd407_s2n_hermetic_trust_test.patch" || \
	fail 'bounded isolated resume worker failed'

hash_production "${run_dir}/production-after.sha256" || \
	fail 'cannot hash final production inputs'
cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-after.txt" || fail 'cannot capture final service identities'
cmp -s "${run_dir}/services-before.txt" "${run_dir}/services-after.txt" || \
	fail 'service identity changed'
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'queue is not empty after build'

"$scontrol" show node ubuntu >"${run_dir}/ubuntu-node-final.txt" || \
	fail 'cannot capture final Ubuntu node state'
"$scontrol" show node PC-210 >"${run_dir}/mac-node-final.txt" || \
	fail 'cannot capture final Mac node state'
for node_file in "${run_dir}/ubuntu-node-final.txt" "${run_dir}/mac-node-final.txt"; do
	[ "$(node_field State "$node_file")" = IDLE ] || fail "node is not IDLE: $node_file"
	[ "$(node_field CPUAlloc "$node_file")" = 0 ] || fail "CPU allocation is not zero: $node_file"
	[ "$(node_field AllocMem "$node_file")" = 0 ] || fail "memory allocation is not zero: $node_file"
done

plugin_hash=$(awk 'NR == 1 {print $1}' "${run_dir}/artifact-hashes.txt")
libs2n_hash=$(awk 'NR == 2 {print $1}' "${run_dir}/artifact-hashes.txt")
printf '%s\n' \
	"official_ctest=283/284 preserved_failure=s2n_self_talk_certificates_test" \
	"hermetic_targeted_test=PASS tests=1 system_trust_wiped=TEST_CONFIG_ONLY" \
	"SMD407_UBUNTU_TLS_ISOLATED_RESUME_COMPLETE plugin_hash=$plugin_hash libs2n_hash=$libs2n_hash production_unchanged=PASS services_unchanged=PASS nodes=IDLE queue=EMPTY run_dir=$run_dir"
