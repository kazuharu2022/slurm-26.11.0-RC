#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_RUNTIME_BUILD_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_RUNTIME_BUILD_CONFIRMED=YES after approval' >&2
	exit 64
fi

output=/output
libdir=${output}/lib

fail()
{
	printf 'SMD405_RUNTIME_BUILD_FAILED error=%s\n' "$1" >&2
	exit 1
}

copy_soname()
{
	soname=$1
	source=$(ldconfig -p | awk -v wanted="$soname" \
		'$1 == wanted {print $NF; exit}')
	[ -n "$source" ] || fail "missing library=$soname"
	[ -f "$source" ] || fail "library is not a regular file=$source"
	cp -L "$source" "${libdir}/${soname}"
	chmod 0755 "${libdir}/${soname}"
}

[ "$(uname -s)" = Linux ] || fail 'builder OS is not Linux'
[ "$(uname -m)" = x86_64 ] || fail 'builder architecture is not x86_64'
[ -d "$output" ] || fail 'output mount is absent'
if find "$output" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
	fail 'output directory is not empty'
fi

mkdir -m 0755 "$libdir"
for soname in libjwt.so.2 libb64.so.0d libjansson.so.4 \
	libhttp_parser.so.2.9; do
	copy_soname "$soname"
done

dpkg-query -W >"${output}/all-packages.txt"
dpkg-query -W libjwt2 libb64-0d libjansson4 libhttp-parser2.9 \
	>"${output}/runtime-packages.txt"
cat /etc/os-release >"${output}/os-release.txt"
uname -a >"${output}/uname.txt"
file "${libdir}"/* >"${output}/runtime-file.txt"
for library in "${libdir}"/*; do
	readelf -d "$library" || fail "readelf failed=$library"
	ldd "$library" || fail "ldd failed=$library"
done >"${output}/runtime-dynamic.txt" 2>&1
if grep -Fq 'not found' "${output}/runtime-dynamic.txt"; then
	fail 'container runtime dependency is missing'
fi
(cd "$output" && sha256sum lib/* >runtime.sha256)
chmod -R a+rX "$output"

printf '%s\n' \
	'SMD405_RUNTIME_BUILD_COMPLETE' \
	'container_os=ubuntu:24.04' \
	'architecture=x86_64' \
	'runtime_libraries=libjwt.so.2,libb64.so.0d,libjansson.so.4,libhttp_parser.so.2.9' \
	"output=$output"
