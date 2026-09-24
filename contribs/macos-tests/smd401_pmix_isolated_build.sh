#!/bin/sh

set -eu

source_root=${SMD401_SOURCE_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}
pmix_prefix=${SMD401_PMIX_PREFIX:-/opt/homebrew/opt/pmix}
libevent_prefix=${SMD401_LIBEVENT_PREFIX:-/opt/homebrew/opt/libevent}
hwloc_prefix=${SMD401_HWLOC_PREFIX:-/opt/homebrew/opt/hwloc}
json_prefix=${SMD401_JSON_PREFIX:-/opt/homebrew/opt/json-c}
jwt_prefix=${SMD401_JWT_PREFIX:-/opt/slurm-deps/libjwt-2.1.3}
run_dir=${SMD401_RUN_DIR:-$(mktemp -d /private/tmp/slurm-smd401-pmix-isolated.XXXXXX)}
source_copy=${run_dir}/source
prefix=${run_dir}/prefix
probe=${run_dir}/pmix-dlopen-probe
candidate=${source_copy}/src/plugins/mpi/pmix/.libs/mpi_pmix_v6.so
pkg_config_path=${pmix_prefix}/lib/pkgconfig
pkg_config_path=${pkg_config_path}:${libevent_prefix}/lib/pkgconfig
pkg_config_path=${pkg_config_path}:${json_prefix}/lib/pkgconfig
pkg_config_path=${pkg_config_path}:${hwloc_prefix}/lib/pkgconfig
pkg_config_path=${pkg_config_path}:${jwt_prefix}/lib/pkgconfig
build_ldflags=-L${jwt_prefix}/lib
build_ldflags="${build_ldflags} -L${hwloc_prefix}/lib"
build_ldflags="${build_ldflags} -L${pmix_prefix}/lib"
build_ldflags="${build_ldflags} -L${libevent_prefix}/lib"
build_cppflags=-I${jwt_prefix}/include
build_cppflags="${build_cppflags} -I${hwloc_prefix}/include"
build_cppflags="${build_cppflags} -I${pmix_prefix}/include"
build_cppflags="${build_cppflags} -I${libevent_prefix}/include"

fail()
{
	printf 'SMD401_PMIX_ISOLATED_BUILD_FAILED error=%s run_dir=%s\n' \
		"$1" "$run_dir" >&2
	exit 1
}

for path in \
	"${pmix_prefix}/include/pmix_server.h" \
	"${pmix_prefix}/include/pmix_version.h" \
	"${pmix_prefix}/lib/libpmix.2.dylib" \
	"${libevent_prefix}/lib/libevent_core-2.1.7.dylib" \
	"${hwloc_prefix}/lib/libhwloc.15.dylib" \
	"${source_root}/src/plugins/mpi/pmix/mpi_pmix.c" \
	"${source_root}/contribs/macos-tests/smd401_pmix_dlopen_probe.c"; do
	[ -e "$path" ] || fail "missing prerequisite: $path"
done

[ "$(uname -m)" = arm64 ] || fail 'host architecture is not arm64'
[ "$(git -C "$source_root" rev-parse HEAD)" = \
	1e20bbab8b88a20446ea28b5418ed6a9013a15a7 ] || \
	fail 'unexpected source revision'

mkdir -p "$source_copy"
git -C "$source_root" archive --format=tar HEAD -o "${run_dir}/source.tar"
tar -xf "${run_dir}/source.tar" -C "$source_copy"
cp "${source_root}/src/plugins/mpi/pmix/mpi_pmix.c" \
	"${source_copy}/src/plugins/mpi/pmix/mpi_pmix.c"

(
	cd "$source_copy"
	env \
		CPP='clang -E' \
		PKG_CONFIG_PATH="$pkg_config_path" \
		LDFLAGS="$build_ldflags" \
		CPPFLAGS="$build_cppflags" \
		./configure \
		--prefix="$prefix" \
		--sysconfdir="${prefix}/etc" \
		--with-jwt="$jwt_prefix" \
		--with-hwloc="$hwloc_prefix" \
		--with-json="$json_prefix" \
		--with-pmix="$pmix_prefix" \
		--without-munge \
		--without-readline \
		--disable-cgroupv2 \
		--disable-x11 \
		--disable-sview \
		--disable-slurmrestd \
		>"${run_dir}/configure.out" 2>"${run_dir}/configure.err"
	make -C src/plugins/mpi/pmix -j4 \
		>"${run_dir}/make-pmix.out" 2>"${run_dir}/make-pmix.err"
) || fail 'configure or mpi/pmix build failed'

[ -f "$candidate" ] || fail 'PMIx v6 plugin candidate was not built'
file "$candidate" >"${run_dir}/candidate-file.txt"
grep -F 'Mach-O 64-bit bundle arm64' "${run_dir}/candidate-file.txt" \
	>/dev/null || fail 'candidate is not an arm64 Mach-O bundle'
otool -L "$candidate" >"${run_dir}/candidate-otool.txt"
otool -l "$candidate" >"${run_dir}/candidate-load-commands.txt"
strings "$candidate" >"${run_dir}/candidate-strings.txt"
grep -Fx 'libpmix.2.dylib' "${run_dir}/candidate-strings.txt" \
	>/dev/null || fail 'candidate lacks Darwin PMIx library name'
if grep -Fx 'libpmix.so.2' "${run_dir}/candidate-strings.txt" >/dev/null; then
	fail 'candidate retains Linux PMIx library name'
fi

clang -std=c11 -Wall -Wextra -Werror \
	-Wl,-rpath,"${pmix_prefix}/lib" \
	"${source_root}/contribs/macos-tests/smd401_pmix_dlopen_probe.c" \
	-o "$probe" >"${run_dir}/probe-build.out" 2>"${run_dir}/probe-build.err" || \
	fail 'cannot build PMIx dlopen probe'

set +e
"$probe" libpmix.so.2 >"${run_dir}/linux-name.out" \
	2>"${run_dir}/linux-name.err"
linux_name_rc=$?
set -e
[ "$linux_name_rc" -eq 2 ] || fail 'Linux PMIx name did not fail as expected'
grep -F 'result=LOAD_FAILED target=libpmix.so.2' \
	"${run_dir}/linux-name.err" >/dev/null || \
	fail 'Linux-name failure was not explicit'

"$probe" libpmix.2.dylib >"${run_dir}/darwin-name.out" \
	2>"${run_dir}/darwin-name.err" || fail 'Darwin PMIx name did not load'
grep -F 'result=LOAD_OK target=libpmix.2.dylib version=OpenPMIx 6.1.0 ' \
	"${run_dir}/darwin-name.out" >/dev/null || \
	fail 'Darwin-name PMIx version mismatch'

if [ -s "${run_dir}/make-pmix.err" ]; then
	grep -Ev '^\.\./\.\./\.\./\.\./libtool: line [0-9]+: test: : integer expression expected$' \
		"${run_dir}/make-pmix.err" >"${run_dir}/unexpected-make-stderr.txt" || true
	[ ! -s "${run_dir}/unexpected-make-stderr.txt" ] || \
		fail 'PMIx plugin build emitted unexpected stderr'
fi
libtool_warning_count=$(wc -l <"${run_dir}/make-pmix.err" | tr -d ' ')

shasum -a 256 \
	"${source_root}/src/plugins/mpi/pmix/mpi_pmix.c" \
	"${source_root}/contribs/macos-tests/smd401_pmix_dlopen_probe.c" \
	"$candidate" "$probe" >"${run_dir}/sha256.txt"

printf '%s\n' \
	'SMD401_PMIX_ISOLATED_BUILD_COMPLETE' \
	'pmix_version=6.1.0' \
	'architecture=arm64' \
	'configure=PASS' \
	'plugin_build=PASS' \
	'linux_name=EXPECTED_LOAD_FAILURE' \
	'darwin_name=LOAD_OK' \
	"known_libtool_warnings=$libtool_warning_count" \
	'production=UNCHANGED' \
	"candidate=$candidate" \
	"run_dir=$run_dir"
