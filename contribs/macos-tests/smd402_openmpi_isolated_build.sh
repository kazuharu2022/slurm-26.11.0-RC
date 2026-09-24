#!/bin/sh

set -eu

if [ "${SMD402_OPENMPI_BUILD_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD402_OPENMPI_BUILD_CONFIRMED=YES after approval' >&2
	exit 64
fi

version=5.0.11
archive=openmpi-${version}.tar.bz2
archive_url=https://download.open-mpi.org/release/open-mpi/v5.0/${archive}
archive_sha256=e668a3c4acd50c41dc204c8a6dd98a611e0f26af89cf677577fa9be8a2698003
base=${SMD402_OPENMPI_BASE:-/tmp/smd402-openmpi-${version}}
source_dir=${base}/source/openmpi-${version}
build_dir=${base}/build
prefix=${base}/install
logs=${base}/logs
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
probe_source=${SMD402_OPENMPI_PROBE_SOURCE:-${script_dir}/smd402_openmpi_probe.c}
macos_endian_patch=${SMD402_OPENMPI_MACOS_ENDIAN_PATCH:-${script_dir}/smd402_prrte_macos_endian.patch}
make_jobs=${SMD402_MAKE_JOBS:-4}

fail()
{
	printf 'SMD402_OPENMPI_ISOLATED_BUILD_FAILED error=%s base=%s\n' \
		"$1" "$base" >&2
	exit 1
}

[ "$(id -u)" -ne 0 ] || fail 'refusing root build'
case "$base" in
	"/tmp/smd402-openmpi-${version}"|\
	"/tmp/smd402-openmpi-${version}-clean"|\
	"/tmp/smd402-openmpi-${version}-clean-attempt2") ;;
	*) fail 'unexpected isolated base path' ;;
esac
[ -f "$probe_source" ] || fail "missing probe source: $probe_source"
[ -f "$macos_endian_patch" ] || \
	fail "missing macOS endian patch: $macos_endian_patch"
case "$make_jobs" in
	''|*[!0-9]*) fail 'make job count is not numeric' ;;
esac
[ "$make_jobs" -ge 1 ] && [ "$make_jobs" -le 8 ] || \
	fail 'make job count must be between 1 and 8'
[ ! -e "$base" ] || fail 'isolated base already exists'

for tool in cc make tar bzip2 curl; do
	command -v "$tool" >/dev/null 2>&1 || fail "missing build tool: $tool"
done

umask 022
mkdir -p "${base}/source" "$build_dir" "$logs"

curl --fail --location --retry 3 --output "${base}/${archive}" \
	"$archive_url" >"${logs}/download.out" 2>"${logs}/download.err" || \
	fail 'archive download failed'

if command -v shasum >/dev/null 2>&1; then
	actual_sha256=$(shasum -a 256 "${base}/${archive}" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
	actual_sha256=$(sha256sum "${base}/${archive}" | awk '{print $1}')
else
	fail 'no SHA-256 tool found'
fi
printf 'expected=%s\nactual=%s\n' "$archive_sha256" "$actual_sha256" \
	>"${logs}/archive-sha256.txt"
[ "$actual_sha256" = "$archive_sha256" ] || fail 'archive SHA-256 mismatch'

tar -xjf "${base}/${archive}" -C "${base}/source" \
	>"${logs}/extract.out" 2>"${logs}/extract.err" || \
	fail 'archive extraction failed'
[ -x "${source_dir}/configure" ] || fail 'configure script missing'

if [ "$(uname -s)" = Darwin ]; then
	command -v patch >/dev/null 2>&1 || fail 'missing build tool: patch'
	patch -d "$source_dir" -p1 <"$macos_endian_patch" \
		>"${logs}/prrte-macos-endian-patch.out" \
		2>"${logs}/prrte-macos-endian-patch.err" || \
		fail 'PRRTE macOS endian patch failed'
fi

(
	cd "$build_dir"
	"${source_dir}/configure" \
		--prefix="$prefix" \
		--with-hwloc=internal \
		--with-libevent=internal \
		--with-pmix=internal \
		--with-prrte=internal \
		--without-munge \
		--enable-mpi-fortran=no \
		--disable-oshmem \
		>"${logs}/configure.out" 2>"${logs}/configure.err"
) || fail 'configure failed'

make -C "$build_dir" -j "$make_jobs" \
	>"${logs}/make.out" 2>"${logs}/make.err" || fail 'build failed'
make -C "$build_dir" install \
	>"${logs}/install.out" 2>"${logs}/install.err" || fail 'install failed'

"${prefix}/bin/mpicc" -std=c11 -Wall -Wextra -Werror "$probe_source" \
	-o "${prefix}/bin/smd402-openmpi-probe" \
	>"${logs}/probe-build.out" 2>"${logs}/probe-build.err" || \
	fail 'probe build failed'

"${prefix}/bin/mpirun" --version >"${logs}/mpirun-version.txt" 2>&1 || \
	fail 'mpirun version readback failed'
"${prefix}/bin/ompi_info" --version >"${logs}/ompi-version.txt" 2>&1 || \
	fail 'ompi_info version readback failed'
"${prefix}/bin/ompi_info" --all >"${logs}/ompi-info-all.txt" 2>&1 || \
	fail 'ompi_info full readback failed'
"${prefix}/bin/pmix_info" >"${logs}/pmix-version.txt" 2>&1 || \
	fail 'pmix_info version readback failed'
"${prefix}/bin/prte_info" >"${logs}/prte-version.txt" 2>&1 || \
	fail 'prte_info version readback failed'
"${prefix}/bin/mpicc" --showme:command >"${logs}/mpicc-command.txt" 2>&1 || \
	fail 'mpicc command readback failed'
"${prefix}/bin/mpicc" --showme:compile >"${logs}/mpicc-compile.txt" 2>&1 || \
	fail 'mpicc compile readback failed'
"${prefix}/bin/mpicc" --showme:link >"${logs}/mpicc-link.txt" 2>&1 || \
	fail 'mpicc link readback failed'

file "${prefix}/bin/mpirun" "${prefix}/bin/mpicc" \
	"${prefix}/bin/smd402-openmpi-probe" >"${logs}/binary-file.txt" || \
	fail 'binary architecture readback failed'

if [ "$(uname -s)" = Darwin ]; then
	libmpi=${prefix}/lib/libmpi.40.dylib
	libpmix=${prefix}/lib/libpmix.2.dylib
	[ -f "$libmpi" ] || fail 'Darwin libmpi missing'
	[ -f "$libpmix" ] || fail 'Darwin libpmix missing'
	otool -L "${prefix}/bin/mpirun" >"${logs}/mpirun-linkage.txt" || \
		fail 'mpirun linkage readback failed'
	otool -L "${prefix}/bin/prted" >"${logs}/prted-linkage.txt" || \
		fail 'prted linkage readback failed'
	otool -L "$libmpi" >"${logs}/libmpi-linkage.txt" || \
		fail 'libmpi linkage readback failed'
	otool -L "$libpmix" >"${logs}/libpmix-linkage.txt" || \
		fail 'libpmix linkage readback failed'
	otool -L "${prefix}/bin/smd402-openmpi-probe" \
		>"${logs}/probe-linkage.txt" || fail 'probe linkage readback failed'
else
	libmpi=${prefix}/lib/libmpi.so.40
	libpmix=${prefix}/lib/libpmix.so.2
	[ -f "$libmpi" ] || fail 'Linux libmpi missing'
	[ -f "$libpmix" ] || fail 'Linux libpmix missing'
	ldd "${prefix}/bin/mpirun" >"${logs}/mpirun-linkage.txt" || \
		fail 'mpirun linkage readback failed'
	ldd "${prefix}/bin/prted" >"${logs}/prted-linkage.txt" || \
		fail 'prted linkage readback failed'
	ldd "$libmpi" >"${logs}/libmpi-linkage.txt" || \
		fail 'libmpi linkage readback failed'
	ldd "$libpmix" >"${logs}/libpmix-linkage.txt" || \
		fail 'libpmix linkage readback failed'
	ldd "${prefix}/bin/smd402-openmpi-probe" \
		>"${logs}/probe-linkage.txt" || fail 'probe linkage readback failed'
fi

chmod -R a+rX "$base"
[ -r "$libmpi" ] || fail 'libmpi is not readable'
[ -x "${prefix}/bin/mpirun" ] || fail 'mpirun is not executable'
[ -x "${prefix}/bin/smd402-openmpi-probe" ] || \
	fail 'probe is not executable'

if command -v shasum >/dev/null 2>&1; then
	shasum -a 256 "$probe_source" "$macos_endian_patch" \
		"${prefix}/bin/mpirun" "$libmpi" \
		"$libpmix" \
		"${prefix}/bin/smd402-openmpi-probe" >"${logs}/critical-sha256.txt"
else
	sha256sum "$probe_source" "$macos_endian_patch" \
		"${prefix}/bin/mpirun" "$libmpi" \
		"$libpmix" \
		"${prefix}/bin/smd402-openmpi-probe" >"${logs}/critical-sha256.txt"
fi

grep -F 'Open MPI) 5.0.11' "${logs}/mpirun-version.txt" >/dev/null || \
	fail 'mpirun version mismatch'
grep -F 'Open MPI v5.0.11' "${logs}/ompi-version.txt" >/dev/null || \
	fail 'ompi_info version mismatch'
grep -E '^[[:space:]]+PMIX: 5\.0\.11rc1$' \
	"${logs}/pmix-version.txt" >/dev/null || fail 'PMIx version mismatch'
grep -E '^[[:space:]]+PRTE: 3\.0\.14$' \
	"${logs}/prte-version.txt" >/dev/null || fail 'PRRTE version mismatch'
grep -F -- '--with-hwloc=internal' "${logs}/ompi-info-all.txt" >/dev/null || \
	fail 'internal hwloc configure flag missing'
grep -F -- '--with-libevent=internal' "${logs}/ompi-info-all.txt" >/dev/null || \
	fail 'internal libevent configure flag missing'
grep -F -- '--with-pmix=internal' "${logs}/ompi-info-all.txt" >/dev/null || \
	fail 'internal PMIx configure flag missing'
grep -F -- '--with-prrte=internal' "${logs}/ompi-info-all.txt" >/dev/null || \
	fail 'internal PRRTE configure flag missing'
grep -F -- '--without-munge' "${logs}/ompi-info-all.txt" >/dev/null || \
	fail 'MUNGE disable configure flag missing'
if grep -i 'libmunge' "${logs}/mpirun-linkage.txt" \
	"${logs}/prted-linkage.txt" "${logs}/libmpi-linkage.txt" \
	"${logs}/libpmix-linkage.txt" >/dev/null; then
	fail 'isolated runtime retains libmunge dependency'
fi

printf '%s\n' \
	'SMD402_OPENMPI_ISOLATED_BUILD_COMPLETE' \
	"host=$(hostname)" \
	"os=$(uname -s)" \
	"architecture=$(uname -m)" \
	"version=${version}" \
	"archive_sha256=${actual_sha256}" \
	"prefix=${prefix}" \
	"probe=${prefix}/bin/smd402-openmpi-probe" \
	"logs=${logs}" \
	'production=UNCHANGED_BY_BUILD_SCRIPT'
