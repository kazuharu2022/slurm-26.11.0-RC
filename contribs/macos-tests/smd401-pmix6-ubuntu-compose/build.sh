#!/bin/sh

set -eu

if [ "${SMD401_PMIX6_BUILD_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD401_PMIX6_BUILD_CONFIRMED=YES after approval' >&2
	exit 64
fi

pmix_version=6.1.0
pmix_archive=pmix-${pmix_version}.tar.bz2
pmix_url=https://github.com/openpmix/openpmix/releases/download/v${pmix_version}/${pmix_archive}
pmix_sha1=f276e91075aed84ff595eb004f7d69118596e869
input_root=/input
output_root=/tmp/smd401-pmix6
source_root=${output_root}/source/slurm
pmix_source=${output_root}/source/pmix-${pmix_version}
pmix_build=${output_root}/build/pmix
slurm_build=${output_root}/build/slurm
pmix_prefix=${output_root}/pmix
artifact_root=${output_root}/artifacts
log_root=${output_root}/logs
probe=${artifact_root}/smd401-pmix-probe
candidate=${slurm_build}/src/plugins/mpi/pmix/.libs/mpi_pmix_v6.so

fail()
{
	printf 'SMD401_PMIX6_UBUNTU_BUILD_FAILED error=%s output=%s\n' \
		"$1" "$output_root" >&2
	exit 1
}

[ "$(uname -s)" = Linux ] || fail 'builder OS is not Linux'
[ "$(uname -m)" = x86_64 ] || fail 'builder architecture is not x86_64'
for path in \
	"${input_root}/slurm-source.tar" \
	"${input_root}/mpi_pmix.c" \
	"${input_root}/smd401_pmix_probe.c" \
	"${input_root}/inputs.sha256"; do
	[ -r "$path" ] || fail "missing input: $path"
done

if find "$output_root" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
	fail 'output root is not empty'
fi

(cd "$input_root" && sha256sum -c inputs.sha256) \
	>"${output_root}/input-verify.txt" 2>&1 || fail 'input hash mismatch'

mkdir -p "${output_root}/source" "$pmix_build" "$slurm_build" \
	"$artifact_root" "$log_root"

curl --fail --location --retry 3 --output "${output_root}/${pmix_archive}" \
	"$pmix_url" >"${log_root}/pmix-download.out" \
	2>"${log_root}/pmix-download.err" || fail 'PMIx download failed'
actual_pmix_sha1=$(sha1sum "${output_root}/${pmix_archive}" | awk '{print $1}')
printf 'expected_sha1=%s\nactual_sha1=%s\n' \
	"$pmix_sha1" "$actual_pmix_sha1" >"${log_root}/pmix-archive-hash.txt"
[ "$actual_pmix_sha1" = "$pmix_sha1" ] || fail 'PMIx archive SHA-1 mismatch'
sha256sum "${output_root}/${pmix_archive}" \
	>>"${log_root}/pmix-archive-hash.txt"

tar -xjf "${output_root}/${pmix_archive}" -C "${output_root}/source" \
	>"${log_root}/pmix-extract.out" 2>"${log_root}/pmix-extract.err" || \
	fail 'PMIx extraction failed'
mkdir -p "$source_root"
tar -xf "${input_root}/slurm-source.tar" -C "$source_root" \
	>"${log_root}/slurm-extract.out" 2>"${log_root}/slurm-extract.err" || \
	fail 'Slurm extraction failed'
cp "${input_root}/mpi_pmix.c" \
	"${source_root}/src/plugins/mpi/pmix/mpi_pmix.c"

(
	cd "$pmix_build"
	"${pmix_source}/configure" \
		--prefix="$pmix_prefix" \
		--with-libevent=/usr \
		--with-libevent-libdir=/usr/lib/x86_64-linux-gnu \
		--with-hwloc=/usr \
		--with-hwloc-libdir=/usr/lib/x86_64-linux-gnu \
		--without-munge \
		--disable-static \
		>"${log_root}/pmix-configure.out" \
		2>"${log_root}/pmix-configure.err" || exit 21
	make -j4 >"${log_root}/pmix-make.out" \
		2>"${log_root}/pmix-make.err" || exit 22
	make install >"${log_root}/pmix-install.out" \
		2>"${log_root}/pmix-install.err" || exit 23
) || fail 'PMIx configure/build/install failed'

pmix_libdir=
for directory in "${pmix_prefix}/lib" "${pmix_prefix}/lib64"; do
	if [ -e "${directory}/libpmix.so.2" ]; then
		pmix_libdir=$directory
		break
	fi
done
[ -n "$pmix_libdir" ] || fail 'PMIx shared library missing'

pkg_config_path=${pmix_libdir}/pkgconfig
(
	cd "$slurm_build"
	env PKG_CONFIG_PATH="$pkg_config_path" \
		"${source_root}/configure" \
		--prefix="${output_root}/slurm-prefix" \
		--sysconfdir="${output_root}/slurm-prefix/etc" \
		--with-jwt=/usr \
		--with-hwloc=/usr \
		--with-json=/usr \
		--with-pmix="$pmix_prefix" \
		--with-munge=/usr \
		--without-readline \
		--disable-x11 \
		--disable-sview \
		--disable-slurmrestd \
		>"${log_root}/slurm-configure.out" \
		2>"${log_root}/slurm-configure.err" || exit 31
	make -C src/plugins/mpi/pmix -j4 \
		>"${log_root}/slurm-pmix-make.out" \
		2>"${log_root}/slurm-pmix-make.err" || exit 32
) || fail 'Slurm PMIx plugin configure/build failed'

[ -f "$candidate" ] || fail 'mpi_pmix_v6 candidate missing'
cp "$candidate" "${artifact_root}/mpi_pmix_v6.so"

pmix_cflags=$(PKG_CONFIG_PATH="$pkg_config_path" pkg-config --cflags pmix)
pmix_libs=$(PKG_CONFIG_PATH="$pkg_config_path" pkg-config --libs pmix)
# pkg-config intentionally supplies multiple shell words here.
# shellcheck disable=SC2086
cc -std=c11 -Wall -Wextra -Werror $pmix_cflags \
	"${input_root}/smd401_pmix_probe.c" \
	-Wl,-rpath,"$pmix_libdir" $pmix_libs -o "$probe" \
	>"${log_root}/probe-build.out" 2>"${log_root}/probe-build.err" || \
	fail 'PMIx probe build failed'

"${pmix_prefix}/bin/pmix_info" --version \
	>"${log_root}/pmix-version.txt" 2>&1 || fail 'PMIx version readback failed'
grep -F 'PMIx) 6.1.0' "${log_root}/pmix-version.txt" >/dev/null || \
	fail 'PMIx version mismatch'
file "${artifact_root}/mpi_pmix_v6.so" "$probe" \
	>"${log_root}/artifact-file.txt"
grep -F 'ELF 64-bit LSB shared object, x86-64' \
	"${log_root}/artifact-file.txt" >/dev/null || \
	fail 'plugin is not x86-64 ELF'
grep -F 'ELF 64-bit LSB pie executable, x86-64' \
	"${log_root}/artifact-file.txt" >/dev/null || \
	fail 'probe is not x86-64 ELF'
strings "${artifact_root}/mpi_pmix_v6.so" \
	>"${log_root}/plugin-strings.txt"
readelf -d "${artifact_root}/mpi_pmix_v6.so" \
	>"${log_root}/plugin-readelf-dynamic.txt"
if ! grep -Fx "${pmix_libdir}/libpmix.so.2" \
	"${log_root}/plugin-strings.txt" >/dev/null; then
	grep -Fx 'libpmix.so.2' "${log_root}/plugin-strings.txt" >/dev/null || \
		fail 'plugin lacks PMIx runtime library name'
	grep -F "$pmix_libdir" \
		"${log_root}/plugin-readelf-dynamic.txt" >/dev/null || \
		fail 'plugin PMIx RUNPATH mismatch'
fi
ldd "${artifact_root}/mpi_pmix_v6.so" \
	>"${log_root}/plugin-ldd.txt" || fail 'plugin ldd failed'
ldd "$probe" >"${log_root}/probe-ldd.txt" || fail 'probe ldd failed'
if grep -q 'not found' "${log_root}/plugin-ldd.txt" \
	"${log_root}/probe-ldd.txt"; then
	fail 'artifact dependency missing'
fi

{
	uname -a
	cat /etc/os-release
	cc --version
	"${pmix_prefix}/bin/pmix_info" --version
	dpkg-query -W -f='${binary:Package}|${Version}\n' \
		libevent-dev libhwloc-dev libjson-c-dev libjwt-dev libmunge-dev
} >"${log_root}/environment.txt"
cp "${input_root}/inputs.sha256" "${output_root}/input-sources.sha256"
sha256sum \
	"${output_root}/${pmix_archive}" \
	"${artifact_root}/mpi_pmix_v6.so" \
	"$probe" \
	"${pmix_libdir}/libpmix.so.2" \
	>"${output_root}/artifacts.sha256"
chmod -R a+rX "$output_root"

printf '%s\n' \
	'SMD401_PMIX6_UBUNTU_ISOLATED_BUILD_COMPLETE' \
	"pmix_version=${pmix_version}" \
	'architecture=x86_64' \
	'container_os=ubuntu:24.04' \
	"pmix_prefix=${pmix_prefix}" \
	"plugin=${artifact_root}/mpi_pmix_v6.so" \
	"probe=${probe}" \
	'production=UNCHANGED' \
	"output=${output_root}"
