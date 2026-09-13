#!/bin/sh

set -u

mode=${1:-root}

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

file_hash()
{
	/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

node_field()
{
	field=$1
	file=$2
	/usr/bin/awk -v key="${field}=" '
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
	proper_ca_patch=$4
	hermetic_patch=$5
	mac_sigpipe_patch=$6
	commit=d25ca63bef1bc12daf2c92ffe2ad86a1689c6997
	tar_hash=061a772e9da0e17d89b4c5ad71aaa333a70aa19c303bf70c792c862d90f13029
	proper_ca_patch_hash=73075cbc0d8eb6c08b221bbd1f38d9b9c6b7d331c25d36bb4c1ca6da76b17ee3
	hermetic_patch_hash=d0be4079436fc8afbb662609d220ec58110f5b19a20ca41c06172922161381cb
	mac_sigpipe_patch_hash=72d2d36eaafe443353d3cfb7a8be6437bcabd5f2c7f0ebe115e240ba4706cbe8
	original_test_hash=7513ce7c3d87cb8aa65587a9d00d6cd7e48ff80c2aee5a6d0c7c10425d01f3a4
	patched_test_hash=4abea977da8432558b56b2a8827bc79ebc58a758f128a1ef87e105fb107c2927
	original_tls_source_hash=4c2f79c1bec5dbe87f4b442415e03a9c2d3d7cf45a70b4a2dd30aac3cf3498a6
	patched_tls_source_hash=d92a0ef3a14840d0c1c068e3fd4a4a324dc175a8a46367d71f771b25fd37f4c3
	ca_hash=dc33004948bb7dcc5d43d8301e5de02cadc9f821cb9cdd4a013848fcabd7e004
	leaf_hash=4569cd4314a4749ffa03c6291cdbf36c6618daf89bb2532d6df15b8df068729d
	final_s2n_prefix=/opt/slurm/26.11.0/lib/slurm-s2n-1.7.9
	openssl_prefix=/opt/homebrew/opt/openssl@3
	uv=/Users/REDACTED_USER/.local/bin/uv
	python=/usr/bin/python3
	cmake_env=${run_dir}/cmake-env
	cmake=${cmake_env}/bin/cmake
	ctest=${cmake_env}/bin/ctest
	s2n_tar=${run_dir}/s2n-tls-${commit}.tar.gz
	s2n_source=${run_dir}/s2n-tls-${commit}
	s2n_build=${run_dir}/s2n-build
	stage_root=${run_dir}/stage
	staged_s2n=${stage_root}${final_s2n_prefix}
	slurm_build=${run_dir}/slurm-build
	test_source=${s2n_source}/tests/unit/s2n_self_talk_certificates_test.c
	tls_source=${source_copy}/src/plugins/tls/s2n/tls_s2n.c
	ca=${s2n_source}/tests/pems/rsa_pss_2048_sha256_CA_cert.pem
	leaf=${s2n_source}/tests/pems/rsa_pss_2048_sha256_leaf_cert.pem
	jobs=$(/usr/bin/getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1)

	[ "${SMD407_MAC_TLS_ISOLATED_BUILD_CONFIRMED:-}" = YES ] || \
		fail 'worker confirmation missing'
	[ "$(/usr/bin/id -u)" -ne 0 ] || fail 'worker must not run as root'
	[ -x "$uv" ] || fail "missing uv=$uv"
	[ -x "$python" ] || fail "missing python=$python"
	[ -d "$openssl_prefix" ] || fail "missing OpenSSL prefix=$openssl_prefix"
	[ -f "${openssl_prefix}/include/openssl/ssl.h" ] || \
		fail 'missing OpenSSL development header'
	[ -f "${source_copy}/configure" ] || fail 'missing staged Slurm configure'
	[ "$(file_hash "$proper_ca_patch")" = "$proper_ca_patch_hash" ] || \
		fail 'proper-CA test patch hash mismatch'
	[ "$(file_hash "$hermetic_patch")" = "$hermetic_patch_hash" ] || \
		fail 'hermetic trust patch hash mismatch'
	[ "$(file_hash "$mac_sigpipe_patch")" = "$mac_sigpipe_patch_hash" ] || \
		fail 'Mac SIGPIPE portability patch hash mismatch'
	[ "$(file_hash "$tls_source")" = "$original_tls_source_hash" ] || \
		fail 'original tls_s2n.c hash mismatch'

	export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
	umask 022
	printf 'worker_user=%s uid=%s gid=%s jobs=%s\n' \
		"$(/usr/bin/id -un)" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)" "$jobs"

	"$uv" venv --python "$python" "$cmake_env" \
		>"${run_dir}/uv-venv.out" 2>"${run_dir}/uv-venv.err" || \
		fail 'cannot create isolated uv environment'
	"$uv" pip install --python "${cmake_env}/bin/python" \
		--only-binary :all: 'cmake==4.4.3' \
		>"${run_dir}/uv-install.out" 2>"${run_dir}/uv-install.err" || \
		fail 'cannot install pinned CMake in isolated uv environment'
	"$cmake" --version >"${run_dir}/cmake-version.txt" || \
		fail 'isolated CMake is not executable'
	"$uv" pip freeze --python "${cmake_env}/bin/python" \
		>"${run_dir}/uv-freeze.txt" 2>"${run_dir}/uv-freeze.err" || \
		fail 'cannot record isolated uv environment'
	/usr/bin/curl --fail --location --proto '=https' --tlsv1.2 \
		-o "$s2n_tar" \
		"https://codeload.github.com/aws/s2n-tls/tar.gz/${commit}" \
		>"${run_dir}/s2n-download.out" 2>"${run_dir}/s2n-download.err" || \
		fail 's2n-tls download failed'
	[ "$(file_hash "$s2n_tar")" = "$tar_hash" ] || \
		fail 's2n-tls tarball hash mismatch'

	/usr/bin/tar -xzf "$s2n_tar" -C "$run_dir" || \
		fail 'cannot extract s2n-tls source'
	[ -d "$s2n_source" ] || fail "missing extracted source=$s2n_source"
	[ "$(file_hash "$test_source")" = "$original_test_hash" ] || \
		fail 'original test source hash mismatch'
	[ "$(file_hash "$ca")" = "$ca_hash" ] || fail 'CA fixture hash mismatch'
	[ "$(file_hash "$leaf")" = "$leaf_hash" ] || fail 'leaf fixture hash mismatch'

	/bin/cp "$test_source" "${run_dir}/test-source.before" || \
		fail 'cannot preserve original test source'
	/usr/bin/patch -d "$s2n_source" -p1 --forward --batch <"$proper_ca_patch" \
		>"${run_dir}/proper-ca-patch.out" 2>"${run_dir}/proper-ca-patch.err" || \
		fail 'cannot apply proper-CA test patch'
	/usr/bin/patch -d "$s2n_source" -p1 --forward --batch <"$hermetic_patch" \
		>"${run_dir}/hermetic-patch.out" 2>"${run_dir}/hermetic-patch.err" || \
		fail 'cannot apply hermetic trust patch'
	[ "$(file_hash "$test_source")" = "$patched_test_hash" ] || \
		fail 'patched test source hash mismatch'
	diff_rc=0
	/usr/bin/diff -u "${run_dir}/test-source.before" "$test_source" \
		>"${run_dir}/test-source.diff" || diff_rc=$?
	[ "$diff_rc" -eq 1 ] || fail 'unexpected test source diff result'

	/bin/cp "$tls_source" "${run_dir}/tls-s2n-source.before" || \
		fail 'cannot preserve original tls_s2n.c'
	/usr/bin/patch -d "$source_copy" -p1 --forward --batch <"$mac_sigpipe_patch" \
		>"${run_dir}/mac-sigpipe-patch.out" \
		2>"${run_dir}/mac-sigpipe-patch.err" || \
		fail 'cannot apply Mac SIGPIPE portability patch'
	[ "$(file_hash "$tls_source")" = "$patched_tls_source_hash" ] || \
		fail 'patched tls_s2n.c hash mismatch'
	diff_rc=0
	/usr/bin/diff -u "${run_dir}/tls-s2n-source.before" "$tls_source" \
		>"${run_dir}/tls-s2n-source.diff" || diff_rc=$?
	[ "$diff_rc" -eq 1 ] || fail 'unexpected tls_s2n.c diff result'

	S2N_DONT_MLOCK=1 "$cmake" \
		-S "$s2n_source" \
		-B "$s2n_build" \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_SHARED_LIBS=ON \
		-DOPENSSL_ROOT_DIR="$openssl_prefix" \
		-DCMAKE_PREFIX_PATH="$openssl_prefix" \
		-DCMAKE_INSTALL_PREFIX="$final_s2n_prefix" \
		>"${run_dir}/s2n-cmake.out" 2>"${run_dir}/s2n-cmake.err" || \
		fail 's2n-tls CMake configure failed'
	S2N_DONT_MLOCK=1 "$cmake" --build "$s2n_build" --parallel "$jobs" \
		>"${run_dir}/s2n-build.out" 2>"${run_dir}/s2n-build.err" || \
		fail 's2n-tls build failed'

	ctest_rc=0
	S2N_DONT_MLOCK=1 CTEST_PARALLEL_LEVEL=1 "$ctest" \
		--test-dir "$s2n_build" \
		-R '^s2n_self_talk_certificates_test$' \
		--output-on-failure \
		>"${run_dir}/hermetic-ctest.out" 2>"${run_dir}/hermetic-ctest.err" || \
		ctest_rc=$?
	printf 'ctest_rc=%s\n' "$ctest_rc" >"${run_dir}/hermetic-ctest.rc"
	/bin/cat "${run_dir}/hermetic-ctest.out" "${run_dir}/hermetic-ctest.err"
	[ "$ctest_rc" -eq 0 ] || fail 'hermetic targeted CTest failed'
	/usr/bin/grep -Eq \
		'^[[:space:]]*1/1 Test #[0-9]+: s2n_self_talk_certificates_test .*Passed' \
		"${run_dir}/hermetic-ctest.out" || fail 'targeted CTest result mismatch'
	/usr/bin/grep -Eq \
		'^[[:space:]]*100% tests passed(, 0 tests failed)? out of 1[[:space:]]*$' \
		"${run_dir}/hermetic-ctest.out" || fail 'targeted CTest summary mismatch'

	/bin/mkdir "$stage_root" || fail 'cannot create staging root'
	DESTDIR="$stage_root" "$cmake" --install "$s2n_build" \
		>"${run_dir}/s2n-install.out" 2>"${run_dir}/s2n-install.err" || \
		fail 's2n-tls staged install failed'
	[ -f "${staged_s2n}/include/s2n.h" ] || fail 'staged s2n header missing'
	[ -f "${staged_s2n}/lib/libs2n.dylib" ] || \
		fail 'staged shared s2n library missing'

	/bin/mkdir "$slurm_build" || fail 'cannot create Slurm build directory'
	(
		cd "$slurm_build" || exit 1
		env \
			DYLD_LIBRARY_PATH="${staged_s2n}/lib:${openssl_prefix}/lib" \
			CPPFLAGS="-I/opt/slurm-deps/libjwt-2.1.3/include -I/opt/homebrew/opt/hwloc/include -I${openssl_prefix}/include" \
			LDFLAGS="-L/opt/slurm-deps/libjwt-2.1.3/lib -L/opt/homebrew/opt/hwloc/lib -L${openssl_prefix}/lib" \
			PKG_CONFIG_PATH="/opt/homebrew/opt/json-c/lib/pkgconfig:/opt/homebrew/opt/hwloc/lib/pkgconfig:/opt/slurm-deps/libjwt-2.1.3/lib/pkgconfig:${openssl_prefix}/lib/pkgconfig" \
			"${source_copy}/configure" \
			--prefix=/opt/slurm/26.11.0 \
			--sysconfdir=/opt/slurm/26.11.0/etc \
			--with-jwt=/opt/slurm-deps/libjwt-2.1.3 \
			--with-hwloc=/opt/homebrew/opt/hwloc \
			--with-json=/opt/homebrew/opt/json-c \
			--with-s2n="$staged_s2n" \
			--with-rpath \
			--without-munge \
			--without-readline \
			--disable-cgroupv2 \
			--disable-x11 \
			--disable-sview \
			--disable-slurmrestd
	) >"${run_dir}/slurm-configure.out" \
		2>"${run_dir}/slurm-configure.err" || fail 'Slurm configure with s2n failed'
	/usr/bin/grep -q '^#define HAVE_S2N 1$' "${slurm_build}/config.h" || \
		fail 'Slurm configure did not enable HAVE_S2N'
	/usr/bin/grep -q 'S\["WITH_S2N_TRUE"\]=""' "${slurm_build}/config.status" || \
		fail 'Slurm configure did not enable WITH_S2N'

	env DYLD_LIBRARY_PATH="${staged_s2n}/lib:${openssl_prefix}/lib" \
		/usr/bin/make -C "${slurm_build}/src/plugins/tls/s2n" \
		S2N_CPPFLAGS="-I${staged_s2n}/include" \
		S2N_LDFLAGS="-Wl,-rpath -Wl,${final_s2n_prefix}/lib -L${staged_s2n}/lib" \
		S2N_LIBS=-ls2n V=1 \
		>"${run_dir}/slurm-plugin-build.out" \
		2>"${run_dir}/slurm-plugin-build.err" || fail 'tls/s2n plugin build failed'

	plugin=${slurm_build}/src/plugins/tls/s2n/.libs/tls_s2n.so
	[ -f "$plugin" ] || fail "missing plugin=$plugin"
	/bin/mkdir "${run_dir}/artifacts" || fail 'cannot create artifact directory'
	/bin/cp "$plugin" "${run_dir}/artifacts/tls_s2n.so" || \
		fail 'cannot stage plugin artifact'
	/bin/cp -R "$staged_s2n" "${run_dir}/artifacts/s2n-prefix" || \
		fail 'cannot stage s2n prefix artifact'
	/bin/cp "$proper_ca_patch" "${run_dir}/artifacts/smd407_s2n_proper_ca_test.patch"
	/bin/cp "$hermetic_patch" "${run_dir}/artifacts/smd407_s2n_hermetic_trust_test.patch"
	/bin/cp "$mac_sigpipe_patch" \
		"${run_dir}/artifacts/smd407_tls_s2n_macos_sigpipe.patch"

	/usr/bin/file "$plugin" >"${run_dir}/plugin-file.txt" || \
		fail 'cannot inspect plugin architecture'
	/usr/bin/grep -Eq 'Mach-O 64-bit bundle arm64' "${run_dir}/plugin-file.txt" || \
		fail 'plugin architecture is not arm64 Mach-O bundle'
	/usr/bin/otool -L "$plugin" >"${run_dir}/plugin-links.txt" || \
		fail 'cannot inspect plugin dependencies'
	/usr/bin/otool -l "$plugin" >"${run_dir}/plugin-load-commands.txt" || \
		fail 'cannot inspect plugin load commands'
	/usr/bin/nm -g "$plugin" >"${run_dir}/plugin-symbols.txt" 2>&1 || \
		fail 'cannot inspect plugin symbols'
	/usr/bin/grep -q 'libs2n' "${run_dir}/plugin-links.txt" || \
		fail 'plugin does not link libs2n'
	/usr/bin/grep -q "$final_s2n_prefix/lib" "${run_dir}/plugin-load-commands.txt" || \
		fail 'plugin lacks final s2n LC_RPATH'
	/usr/bin/grep -q '_plugin_type' "${run_dir}/plugin-symbols.txt" || \
		fail 'plugin metadata symbol missing'

	/usr/bin/shasum -a 256 \
		"${run_dir}/artifacts/tls_s2n.so" \
		"${run_dir}/artifacts/s2n-prefix/lib/libs2n.dylib" \
		"${run_dir}/artifacts/smd407_s2n_proper_ca_test.patch" \
		"${run_dir}/artifacts/smd407_s2n_hermetic_trust_test.patch" \
		"${run_dir}/artifacts/smd407_tls_s2n_macos_sigpipe.patch" \
		>"${run_dir}/artifact-hashes.txt" || fail 'cannot hash artifacts'
	printf '%s\n' \
		"hermetic_targeted_test=PASS tests=1 system_trust_wiped=TEST_CONFIG_ONLY" \
		"mac_sigpipe_compat=PASS mechanism=sigpending_then_sigwait" \
		"SMD407_MAC_TLS_ISOLATED_BUILD_WORKER_COMPLETE plugin=$plugin staged_s2n=$staged_s2n"
	exit 0
fi

if [ "${SMD407_MAC_TLS_ISOLATED_BUILD_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_MAC_TLS_ISOLATED_BUILD_CONFIRMED=YES after approving the isolated Mac s2n/plugin build and pinned uv CMake download' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
source_root=/Users/REDACTED_USER/dev/slurm.26-05
expected_head=a77367bb482ab2f626fb5981d1349159e5ae8740
expected_configure=2f07951369dc6d2be0948e551d3d6a28d06f8310ee1e16213e8faec06d691940
expected_configure_ac=b6d79c8ff53a77274e67529afbbdd67116fb934a64d6fc403fcc1ae4422c79e8
expected_config_h_in=6028f2c6c24f4eae4f0ca728d7756400ccd9483dcd51c4af04c08741d690b3ee
expected_tls_source=4c2f79c1bec5dbe87f4b442415e03a9c2d3d7cf45a70b4a2dd30aac3cf3498a6
expected_tls_makefile=4d54fb737e977c4257de98dbceef749982d42e9faa61af82472d9c5b3aa7f709
proper_ca_patch=${SMD407_PROPER_CA_PATCH:-${source_root}/contribs/macos-tests/smd407_s2n_proper_ca_test.patch}
hermetic_patch=${SMD407_HERMETIC_PATCH:-${source_root}/contribs/macos-tests/smd407_s2n_hermetic_trust_test.patch}
mac_sigpipe_patch=${SMD407_MAC_SIGPIPE_PATCH:-${source_root}/contribs/macos-tests/smd407_tls_s2n_macos_sigpipe.patch}
proper_ca_patch_hash=73075cbc0d8eb6c08b221bbd1f38d9b9c6b7d331c25d36bb4c1ca6da76b17ee3
hermetic_patch_hash=d0be4079436fc8afbb662609d220ec58110f5b19a20ca41c06172922161381cb
mac_sigpipe_patch_hash=72d2d36eaafe443353d3cfb7a8be6437bcabd5f2c7f0ebe115e240ba4706cbe8
build_user=REDACTED_USER
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-mac-isolated-build-${run_stamp}
source_copy=${run_dir}/slurm-source

hash_production()
{
	output=$1
	: >"$output" || return 1
	for production_path in \
		"${prefix}/etc/slurm.conf" \
		"${prefix}/etc/gres.conf" \
		"${prefix}/sbin/slurmd" \
		"${prefix}/lib/slurm/libslurmfull.dylib" \
		"${prefix}/lib/slurm/tls_none.so" \
		"${prefix}/lib/slurm/tls_s2n.so"; do
		[ -f "$production_path" ] || continue
		/usr/bin/shasum -a 256 "$production_path" >>"$output" || return 1
	done
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for macOS'
[ "$(/bin/hostname -s)" = PC-210 ] || fail "unexpected host=$(/bin/hostname -s)"
/usr/bin/id "$build_user" >/dev/null 2>&1 || fail "missing build user=$build_user"
[ -d "${source_root}/.git" ] || fail "missing source git tree=$source_root"
for required in "$slurm_conf" "$scontrol" "$squeue" "$proper_ca_patch" \
	"$hermetic_patch" "$mac_sigpipe_patch" /Users/REDACTED_USER/.local/bin/uv /usr/bin/python3 \
	/opt/homebrew/opt/openssl@3/include/openssl/ssl.h; do
	[ -e "$required" ] || fail "missing $required"
done
for command_path in /bin/cp /bin/date /bin/mkdir /bin/ps /bin/rm /bin/sh \
	/usr/bin/awk /usr/bin/curl /usr/bin/diff /usr/bin/file /usr/bin/git \
	/usr/bin/grep /usr/bin/make /usr/bin/nm /usr/bin/otool /usr/bin/patch \
	/usr/bin/shasum /usr/bin/sudo /usr/bin/tar /usr/bin/uname; do
	[ -x "$command_path" ] || fail "missing command=$command_path"
done
[ "$(/usr/bin/sudo -u "$build_user" -H /usr/bin/git -C "$source_root" rev-parse HEAD)" = \
	"$expected_head" ] || \
	fail 'Mac source HEAD changed'
[ "$(file_hash "${source_root}/configure")" = "$expected_configure" ] || \
	fail 'configure hash mismatch'
[ "$(file_hash "${source_root}/configure.ac")" = "$expected_configure_ac" ] || \
	fail 'configure.ac hash mismatch'
[ "$(file_hash "${source_root}/config.h.in")" = "$expected_config_h_in" ] || \
	fail 'config.h.in hash mismatch'
[ "$(file_hash "${source_root}/src/plugins/tls/s2n/tls_s2n.c")" = \
	"$expected_tls_source" ] || fail 'tls_s2n.c hash mismatch'
[ "$(file_hash "${source_root}/src/plugins/tls/s2n/Makefile.am")" = \
	"$expected_tls_makefile" ] || fail 'tls/s2n Makefile.am hash mismatch'
[ "$(file_hash "$proper_ca_patch")" = "$proper_ca_patch_hash" ] || \
	fail 'proper-CA patch hash mismatch'
[ "$(file_hash "$hermetic_patch")" = "$hermetic_patch_hash" ] || \
	fail 'hermetic patch hash mismatch'
[ "$(file_hash "$mac_sigpipe_patch")" = "$mac_sigpipe_patch_hash" ] || \
	fail 'Mac SIGPIPE portability patch hash mismatch'

export SLURM_CONF="$slurm_conf"
controller_output=$("$scontrol" ping 2>&1) || fail 'controller ping failed'
printf '%s\n' "$controller_output" | /usr/bin/grep -q ' is UP$' || \
	fail 'controller is not UP'
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'Slurm queue is not empty'
for node_name in ubuntu PC-210; do
	node_output=$("$scontrol" show node "$node_name") || fail "cannot read node=$node_name"
	printf '%s\n' "$node_output" | /usr/bin/grep -q 'State=IDLE' || \
		fail "node=$node_name is not IDLE"
	printf '%s\n' "$node_output" | /usr/bin/grep -q 'CPUAlloc=0' || \
		fail "node=$node_name CPU allocation is not zero"
	printf '%s\n' "$node_output" | /usr/bin/grep -q 'AllocMem=0' || \
		fail "node=$node_name memory allocation is not zero"
done
[ -f /var/run/slurmd.pid ] || fail 'missing slurmd pidfile'
slurmd_pid=$(/bin/cat /var/run/slurmd.pid)
/bin/kill -0 "$slurmd_pid" 2>/dev/null || fail "slurmd pid is not alive=$slurmd_pid"

umask 077
/bin/mkdir "$run_dir" || fail 'cannot create run directory'
printf 'mode=ISOLATED_MAC_TLS_PLUGIN_BUILD run_dir=%s source=%s build_user=%s\n' \
	"$run_dir" "$source_root" "$build_user"
hash_production "${run_dir}/production-before.sha256" || \
	fail 'cannot hash production inputs'
/usr/bin/sudo -u "$build_user" -H /usr/bin/git -C "$source_root" status --short \
	>"${run_dir}/source-status-before.txt"
/usr/bin/sudo -u "$build_user" -H /usr/bin/git -C "$source_root" \
	diff --name-only --diff-filter=ACMRTUXB \
	>"${run_dir}/modified-tracked-files.txt"
/bin/ps -p "$slurmd_pid" -o pid,ppid,lstart,state,command \
	>"${run_dir}/slurmd-before.txt" || fail 'cannot capture slurmd identity'

/usr/bin/sudo -u "$build_user" -H /usr/bin/git -C "$source_root" \
	archive --format=tar HEAD \
	>"${run_dir}/slurm-source.tar" || fail 'cannot archive Mac Slurm source'
/bin/mkdir "$source_copy" || fail 'cannot create source snapshot directory'
/usr/bin/tar -xf "${run_dir}/slurm-source.tar" -C "$source_copy" || \
	fail 'cannot extract Mac Slurm source snapshot'
while IFS= read -r relative_path; do
	[ -n "$relative_path" ] || continue
	[ -f "${source_root}/${relative_path}" ] || fail "modified source missing=$relative_path"
	/bin/mkdir -p "${source_copy}/$(/usr/bin/dirname "$relative_path")" || \
		fail "cannot create source parent=$relative_path"
	/bin/cp -p "${source_root}/${relative_path}" "${source_copy}/${relative_path}" || \
		fail "cannot overlay modified source=$relative_path"
done <"${run_dir}/modified-tracked-files.txt"
/bin/cp "$proper_ca_patch" "${run_dir}/smd407_s2n_proper_ca_test.patch" || \
	fail 'cannot copy proper-CA patch'
/bin/cp "$hermetic_patch" "${run_dir}/smd407_s2n_hermetic_trust_test.patch" || \
	fail 'cannot copy hermetic patch'
/bin/cp "$mac_sigpipe_patch" "${run_dir}/smd407_tls_s2n_macos_sigpipe.patch" || \
	fail 'cannot copy Mac SIGPIPE portability patch'

build_group=$(/usr/bin/id -gn "$build_user")
/usr/sbin/chown -R "${build_user}:${build_group}" "$run_dir" || \
	fail 'cannot transfer isolated workspace to build user'
/usr/bin/sudo -u "$build_user" -H env \
	SMD407_MAC_TLS_ISOLATED_BUILD_CONFIRMED=YES \
	/bin/sh "$0" worker "$run_dir" "$source_copy" \
	"${run_dir}/smd407_s2n_proper_ca_test.patch" \
	"${run_dir}/smd407_s2n_hermetic_trust_test.patch" \
	"${run_dir}/smd407_tls_s2n_macos_sigpipe.patch" || \
	fail 'isolated Mac TLS plugin worker failed'

hash_production "${run_dir}/production-after.sha256" || \
	fail 'cannot hash final production inputs'
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed'
/usr/bin/sudo -u "$build_user" -H /usr/bin/git -C "$source_root" status --short \
	>"${run_dir}/source-status-after.txt"
/usr/bin/cmp -s "${run_dir}/source-status-before.txt" \
	"${run_dir}/source-status-after.txt" || fail 'Mac source worktree changed'
[ "$(/bin/cat /var/run/slurmd.pid)" = "$slurmd_pid" ] || fail 'slurmd pid changed'
/bin/kill -0 "$slurmd_pid" 2>/dev/null || fail 'slurmd stopped during build'
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'queue is not empty after build'
"$scontrol" show node ubuntu >"${run_dir}/ubuntu-node-final.txt" || \
	fail 'cannot capture final Ubuntu node state'
"$scontrol" show node PC-210 >"${run_dir}/mac-node-final.txt" || \
	fail 'cannot capture final Mac node state'
for node_file in "${run_dir}/ubuntu-node-final.txt" "${run_dir}/mac-node-final.txt"; do
	[ "$(node_field State "$node_file")" = IDLE ] || fail "node is not IDLE: $node_file"
	[ "$(node_field CPUAlloc "$node_file")" = 0 ] || \
		fail "CPU allocation is not zero: $node_file"
	[ "$(node_field AllocMem "$node_file")" = 0 ] || \
		fail "memory allocation is not zero: $node_file"
done

plugin_hash=$(/usr/bin/awk 'NR == 1 {print $1}' "${run_dir}/artifact-hashes.txt")
libs2n_hash=$(/usr/bin/awk 'NR == 2 {print $1}' "${run_dir}/artifact-hashes.txt")
printf '%s\n' \
	"SMD407_MAC_TLS_ISOLATED_BUILD_COMPLETE plugin_hash=$plugin_hash libs2n_hash=$libs2n_hash architecture=arm64 production_unchanged=PASS slurmd_pid_unchanged=$slurmd_pid nodes=IDLE queue=EMPTY run_dir=$run_dir"
