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
	[ "$#" -eq 3 ] || fail 'invalid worker arguments'
	run_dir=$2
	source_copy=$3
	cmake=${run_dir}/cmake-env/bin/cmake
	ctest=${run_dir}/cmake-env/bin/ctest
	commit=d25ca63bef1bc12daf2c92ffe2ad86a1689c6997
	tar_hash=061a772e9da0e17d89b4c5ad71aaa333a70aa19c303bf70c792c862d90f13029
	final_s2n_prefix=/usr/local/slurm/26.11.0/lib/slurm-s2n-1.7.9
	s2n_tar=${run_dir}/s2n-tls-${commit}.tar.gz
	s2n_source=${run_dir}/s2n-tls-${commit}
	s2n_build=${run_dir}/s2n-build
	stage_root=${run_dir}/stage
	staged_s2n=${stage_root}${final_s2n_prefix}
	slurm_build=${run_dir}/slurm-build
	jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1)

	[ "${SMD407_TLS_ISOLATED_BUILD_CONFIRMED:-}" = YES ] || \
		fail 'worker confirmation missing'
	[ "$(id -u)" -ne 0 ] || fail 'worker must not run as root'
	[ -x "$cmake" ] || fail "missing isolated cmake=$cmake"
	[ -x "$ctest" ] || fail "missing isolated ctest=$ctest"
	[ -f "${source_copy}/configure" ] || fail 'missing staged Slurm configure'

	umask 022
	printf 'worker_user=%s uid=%s gid=%s jobs=%s\n' \
		"$(id -un)" "$(id -u)" "$(id -g)" "$jobs"

	curl --fail --location --proto '=https' --tlsv1.2 \
		-o "$s2n_tar" \
		"https://codeload.github.com/aws/s2n-tls/tar.gz/${commit}" \
		>"${run_dir}/s2n-download.out" 2>"${run_dir}/s2n-download.err" || \
		fail 's2n-tls download failed'
	printf '%s  %s\n' "$tar_hash" "$s2n_tar" \
		>"${run_dir}/s2n-tar.expected.sha256"
(
		cd "$run_dir" || exit 1
		sha256sum -c "${run_dir}/s2n-tar.expected.sha256"
	) >"${run_dir}/s2n-tar.verify" 2>&1 || fail 's2n-tls tarball hash mismatch'

	tar -xzf "$s2n_tar" -C "$run_dir" || fail 'cannot extract s2n-tls source'
	[ -d "$s2n_source" ] || fail "missing extracted source=$s2n_source"

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

	S2N_DONT_MLOCK=1 CTEST_PARALLEL_LEVEL="$jobs" "$ctest" \
		--test-dir "$s2n_build" --output-on-failure \
		>"${run_dir}/s2n-ctest.out" 2>"${run_dir}/s2n-ctest.err" || \
		fail 's2n-tls test suite failed'

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

	file "$plugin" >"${run_dir}/plugin-file.txt"
	readelf -d "$plugin" >"${run_dir}/plugin-dynamic.txt" 2>&1 || \
		fail 'cannot inspect plugin dynamic section'
	LD_LIBRARY_PATH="${staged_s2n}/lib" ldd "$plugin" \
		>"${run_dir}/plugin-ldd.txt" 2>&1 || fail 'plugin dependency resolution failed'
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
		>"${run_dir}/artifact-hashes.txt" || fail 'cannot hash artifacts'

	printf '%s\n' \
		"SMD407_UBUNTU_TLS_ISOLATED_WORKER_COMPLETE plugin=$plugin staged_s2n=$staged_s2n"
	exit 0
fi

if [ "${SMD407_TLS_ISOLATED_BUILD_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_TLS_ISOLATED_BUILD_CONFIRMED=YES after approving the network download and isolated build' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
source_root=/root/slurm/slurm
expected_head=a44a5b8cd1704890c183b7dc44984ab1c2e7a519
expected_configure=a68de909de86a07af82f4c5618806fcc915d70d67a9890f66ad2e0a741bd9846
expected_configure_ac=a573b53121b7657e71f0efe5ae3bd7e993a3a63c7db568b86a74e287b61b6b5e
expected_config_h_in=15a514973455082a970caa4ba752de8e85fede616a4414ddb9e08b99f5114e2d
expected_tls_source=4c2f79c1bec5dbe87f4b442415e03a9c2d3d7cf45a70b4a2dd30aac3cf3498a6
expected_tls_makefile=4d54fb737e977c4257de98dbceef749982d42e9faa61af82472d9c5b3aa7f709
cmake_hash=bae3c4954623ec4d62e62c70443f0da7988b733111c2871fcc6a31ead5137e20
uv=/root/.local/bin/uv
build_user=REDACTED_USER
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-ubuntu-isolated-build-${run_stamp}
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
[ -x "$uv" ] || fail "missing uv=$uv"
[ -f "$slurm_conf" ] || fail "missing $slurm_conf"
[ -d "$source_root/.git" ] || fail "missing source git tree=$source_root"
for command_name in curl file git grep ldd make nm readelf sha256sum sudo systemctl tar; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done

export SLURM_CONF="$slurm_conf"
controller_output=$("$scontrol" ping 2>&1) || fail 'controller ping failed'
printf '%s\n' "$controller_output" | grep -q ' is UP$' || fail 'controller is not UP'
node_output=$("$scontrol" show node ubuntu) || fail 'node readback failed'
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
[ "$node_state" = IDLE ] || fail "Ubuntu node is not IDLE: $node_state"
printf '%s\n' "$node_output" | grep -q 'CPUAlloc=0' || \
	fail 'Ubuntu CPU allocation is not zero'
printf '%s\n' "$node_output" | grep -q 'AllocMem=0' || \
	fail 'Ubuntu memory allocation is not zero'
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'Slurm queue is not empty'

[ "$(git -C "$source_root" rev-parse HEAD)" = "$expected_head" ] || \
	fail 'Ubuntu source HEAD changed'
source_status=$(git -C "$source_root" status --short)
expected_status='?? src/slurmrestd/slurmrestd
?? src/swait/swait'
[ "$source_status" = "$expected_status" ] || fail 'Ubuntu source status changed'

printf '%s  %s\n' "$expected_configure" "${source_root}/configure" |
	sha256sum -c - >/dev/null || fail 'configure hash mismatch'
printf '%s  %s\n' "$expected_configure_ac" "${source_root}/configure.ac" |
	sha256sum -c - >/dev/null || fail 'configure.ac hash mismatch'
printf '%s  %s\n' "$expected_config_h_in" "${source_root}/config.h.in" |
	sha256sum -c - >/dev/null || fail 'config.h.in hash mismatch'
printf '%s  %s\n' "$expected_tls_source" \
	"${source_root}/src/plugins/tls/s2n/tls_s2n.c" |
	sha256sum -c - >/dev/null || fail 'tls_s2n.c hash mismatch'
printf '%s  %s\n' "$expected_tls_makefile" \
	"${source_root}/src/plugins/tls/s2n/Makefile.am" |
	sha256sum -c - >/dev/null || fail 'tls/s2n Makefile.am hash mismatch'

umask 077
mkdir "$run_dir" || fail 'cannot create run directory'
printf 'mode=ISOLATED_BUILD_ONLY run_dir=%s source=%s build_user=%s\n' \
	"$run_dir" "$source_root" "$build_user"

hash_production "${run_dir}/production-before.sha256" || \
	fail 'cannot hash production inputs'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-before.txt" || fail 'cannot capture service identities'
git -C "$source_root" status --short >"${run_dir}/source-status.txt"
git -C "$source_root" rev-parse HEAD >"${run_dir}/source-head.txt"
git -C "$source_root" archive --format=tar HEAD \
	>"${run_dir}/slurm-source.tar" || fail 'cannot archive Slurm source'
mkdir "$source_copy" || fail 'cannot create source snapshot directory'
tar -xf "${run_dir}/slurm-source.tar" -C "$source_copy" || \
	fail 'cannot extract Slurm source snapshot'

printf '%s\n' \
	"cmake==4.4.3 --hash=sha256:${cmake_hash}" \
	>"${run_dir}/cmake-requirements.txt"
"$uv" venv --python /usr/bin/python3 "${run_dir}/cmake-env" \
	>"${run_dir}/uv-venv.out" 2>"${run_dir}/uv-venv.err" || \
	fail 'cannot create isolated uv environment'
"$uv" pip install \
	--python "${run_dir}/cmake-env/bin/python" \
	--only-binary :all: --require-hashes \
	-r "${run_dir}/cmake-requirements.txt" \
	>"${run_dir}/uv-install.out" 2>"${run_dir}/uv-install.err" || \
	fail 'cannot install pinned cmake in isolated uv environment'
"${run_dir}/cmake-env/bin/cmake" --version >"${run_dir}/cmake-version.txt" || \
	fail 'isolated cmake is not executable'

build_group=$(id -gn "$build_user")
chown -R "${build_user}:${build_group}" "$run_dir" || \
	fail 'cannot transfer isolated workspace to build user'

sudo -u "$build_user" -H env \
	SMD407_TLS_ISOLATED_BUILD_CONFIRMED=YES \
	/bin/sh "$0" worker "$run_dir" "$source_copy" || \
	fail 'isolated build worker failed'

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
[ "$(node_field State "${run_dir}/ubuntu-node-final.txt")" = IDLE ] || \
	fail 'Ubuntu node is not IDLE after build'
[ "$(node_field CPUAlloc "${run_dir}/ubuntu-node-final.txt")" = 0 ] || \
	fail 'Ubuntu CPU allocation is not zero after build'
[ "$(node_field AllocMem "${run_dir}/ubuntu-node-final.txt")" = 0 ] || \
	fail 'Ubuntu memory allocation is not zero after build'

plugin_hash=$(awk 'NR == 1 {print $1}' "${run_dir}/artifact-hashes.txt")
libs2n_hash=$(awk 'NR == 2 {print $1}' "${run_dir}/artifact-hashes.txt")
printf '%s\n' \
	"SMD407_UBUNTU_TLS_ISOLATED_BUILD_COMPLETE plugin_hash=$plugin_hash libs2n_hash=$libs2n_hash production_unchanged=PASS services_unchanged=PASS run_dir=$run_dir"
