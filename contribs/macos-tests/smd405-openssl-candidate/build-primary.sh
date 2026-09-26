#!/bin/sh

# Build-only validation for the SMD-405 OpenSSL shutdown-race candidate.
# This script never installs into the production prefix and never controls a
# daemon. It must be run by the user on the primary controller as root because
# the validated source tree is root-owned.

set -eu
umask 077

expected_source_head=a44a5b8cd1704890c183b7dc44984ab1c2e7a519
expected_patch_sha=0e3482269d4c78636304343058d8ae0a7a61d542c02f580326ba3880a22161f3
expected_makefile_patch_sha=134727a472f6b7a7085f41ab7a47eb1598d4df7be986bffbb6704ccb1e188cdc
expected_production_binary_sha=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
expected_configure_sha=a68de909de86a07af82f4c5618806fcc915d70d67a9890f66ad2e0a741bd9846
expected_base_makefile_sha=cd81db3024f9396884eddfdc4e2ed5c3b1d8333db9db2b5034d303cbd561f264
expected_candidate_makefile_sha=e0957381a2677862b396f73ad43f077212e3b707fb0ffdcbfad219f7fdfcc214

source_tree=/root/slurm/slurm
patch_input=${SMD405_PATCH_INPUT:-/tmp/smd405_openssl_shutdown_race_source.patch}
makefile_patch_input=${SMD405_MAKEFILE_PATCH_INPUT:-/tmp/smd405_openssl_shutdown_race_makefile.patch}
production_prefix=/usr/local/slurm/26.11.0
production_binary=${production_prefix}/sbin/slurmctld
production_conf=${production_prefix}/etc/slurm.conf

production_command()
{
	env \
		PATH=${production_prefix}/bin:${production_prefix}/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
		LD_LIBRARY_PATH=${production_prefix}/lib \
		SLURM_CONF=$production_conf \
		"$@"
}

fail()
{
	printf 'SMD405_OPENSSL_CANDIDATE_BUILD_FAIL reason=%s\n' "$1" >&2
	exit 1
}

[ "${SMD405_OPENSSL_CANDIDATE_BUILD_CONFIRMED:-}" = YES ] || {
	printf '%s\n' \
		'error: set SMD405_OPENSSL_CANDIDATE_BUILD_CONFIRMED=YES after reviewing the build-only scope' >&2
	exit 64
}

[ "$(id -u)" -eq 0 ] || fail 'run as root on the primary controller'
[ "$(hostname -s)" = ubuntu2504 ] || fail 'unexpected primary hostname'
[ -d "${source_tree}/.git" ] || fail 'validated source tree is absent'
[ -f "$patch_input" ] || fail 'candidate source patch is absent'
[ -f "$makefile_patch_input" ] || fail 'candidate Makefile.in patch is absent'
[ -x "$production_binary" ] || fail 'production slurmctld is absent'
[ -f "$production_conf" ] || fail 'production slurm.conf is absent'

[ "$(git -C "$source_tree" rev-parse HEAD)" = "$expected_source_head" ] || \
	fail 'source HEAD mismatch'
[ -z "$(git -C "$source_tree" status --short --untracked-files=no)" ] || \
	fail 'tracked source changes are present'
[ "$(sha256sum "$patch_input" | awk '{print $1}')" = "$expected_patch_sha" ] || \
	fail 'candidate patch hash mismatch'
[ "$(sha256sum "$makefile_patch_input" | awk '{print $1}')" = \
	"$expected_makefile_patch_sha" ] || fail 'candidate Makefile.in patch hash mismatch'
[ "$(sha256sum "$production_binary" | awk '{print $1}')" = \
	"$expected_production_binary_sha" ] || fail 'production binary hash mismatch'

for service_name in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service_name")" = active ] || \
		fail "production service is not active=${service_name}"
done

production_command "${production_prefix}/bin/scontrol" ping >/dev/null 2>&1 || \
	fail 'production controller ping failed'
[ -z "$(production_command "${production_prefix}/bin/squeue" -h)" ] || \
	fail 'production queue is not empty'

before_ctld_pid=$(systemctl show -p MainPID --value slurmctld)
before_dbd_pid=$(systemctl show -p MainPID --value slurmdbd)
before_slurmd_pid=$(systemctl show -p MainPID --value slurmd)

run_root=$(mktemp -d /var/tmp/smd405-openssl-candidate.XXXXXX)
source_copy=${run_root}/source
stage_root=${run_root}/stage
log_root=${run_root}/logs
mkdir -m 0700 "$source_copy" "$stage_root" "$log_root"

finish()
{
	rc=$?
	trap - 0 HUP INT TERM
	set +e
	after_ctld_pid=$(systemctl show -p MainPID --value slurmctld 2>/dev/null)
	after_dbd_pid=$(systemctl show -p MainPID --value slurmdbd 2>/dev/null)
	after_slurmd_pid=$(systemctl show -p MainPID --value slurmd 2>/dev/null)
	after_production_sha=$(sha256sum "$production_binary" 2>/dev/null | \
		awk '{print $1}')
	postflight_services=active
	for service_name in slurmctld slurmdbd slurmd; do
		if [ "$(systemctl is-active "$service_name" 2>/dev/null)" != active ]; then
			postflight_services=not-active
		fi
	done
	if production_command "${production_prefix}/bin/scontrol" ping \
		>/dev/null 2>&1; then
		postflight_ping=PASS
	else
		postflight_ping=FAIL
	fi
	printf 'postflight_pids_before=%s,%s,%s after=%s,%s,%s\n' \
		"$before_ctld_pid" "$before_dbd_pid" "$before_slurmd_pid" \
		"$after_ctld_pid" "$after_dbd_pid" "$after_slurmd_pid"
	printf 'postflight_production_sha256=%s\n' \
		"${after_production_sha:-UNAVAILABLE}"
	printf 'postflight_services=%s\n' "$postflight_services"
	printf 'postflight_controller_ping=%s\n' "$postflight_ping"
	printf 'candidate_run_root=%s\n' "$run_root"
	if [ "$before_ctld_pid,$before_dbd_pid,$before_slurmd_pid" != \
		"$after_ctld_pid,$after_dbd_pid,$after_slurmd_pid" ]; then
		printf '%s\n' 'postflight_production_pids_unchanged=NO' >&2
		rc=1
	else
		printf '%s\n' 'postflight_production_pids_unchanged=YES'
	fi
	if [ "$after_production_sha" != "$expected_production_binary_sha" ]; then
		printf '%s\n' 'postflight_production_binary_unchanged=NO' >&2
		rc=1
	else
		printf '%s\n' 'postflight_production_binary_unchanged=YES'
	fi
	if [ "$postflight_services" != active ] || [ "$postflight_ping" != PASS ]; then
		printf '%s\n' 'postflight_production_health=FAIL' >&2
		rc=1
	else
		printf '%s\n' 'postflight_production_health=PASS'
	fi
	exit "$rc"
}
trap finish 0
trap 'exit 130' HUP INT TERM

printf 'source_head=%s\n' "$expected_source_head" >"${log_root}/inputs.txt"
printf 'patch_sha256=%s\n' "$expected_patch_sha" >>"${log_root}/inputs.txt"
printf 'makefile_patch_sha256=%s\n' \
	"$expected_makefile_patch_sha" >>"${log_root}/inputs.txt"
printf 'production_binary_sha256=%s\n' \
	"$expected_production_binary_sha" >>"${log_root}/inputs.txt"

source_archive=${run_root}/source.tar
git -C "$source_tree" archive --format=tar \
	--output="$source_archive" HEAD || fail 'source archive creation failed'
tar -xf "$source_archive" -C "$source_copy" || \
	fail 'source archive extraction failed'
cp "$patch_input" "${run_root}/source.patch"
cp "$makefile_patch_input" "${run_root}/makefile.patch"
chmod 0600 "${run_root}/source.patch" "${run_root}/makefile.patch"

[ "$(sha256sum "${source_copy}/configure" | awk '{print $1}')" = \
	"$expected_configure_sha" ] || fail 'base configure hash mismatch'
[ "$(sha256sum "${source_copy}/src/common/Makefile.in" | awk '{print $1}')" = \
	"$expected_base_makefile_sha" ] || fail 'base src/common/Makefile.in hash mismatch'

(
	cd "$source_copy"
	git apply --check "${run_root}/source.patch"
	git apply "${run_root}/source.patch"
	git apply --reverse --check "${run_root}/source.patch"
) >"${log_root}/patch-apply.out" 2>"${log_root}/patch-apply.err" || \
	fail 'source patch application failed'

(
	cd "$source_copy"
	git apply --unidiff-zero --check "${run_root}/makefile.patch"
	git apply --unidiff-zero "${run_root}/makefile.patch"
	git apply --unidiff-zero --reverse --check "${run_root}/makefile.patch"
) >"${log_root}/makefile-patch-apply.out" \
	2>"${log_root}/makefile-patch-apply.err" || \
	fail 'generated Makefile.in patch application failed'

grep -F 'openssl_helper.lo' "${source_copy}/src/common/Makefile.in" >/dev/null || \
	fail 'generated Makefile.in lacks openssl helper'
[ "$(sha256sum "${source_copy}/src/common/Makefile.in" | awk '{print $1}')" = \
	"$expected_candidate_makefile_sha" ] || \
	fail 'candidate src/common/Makefile.in hash mismatch'
[ "$(sha256sum "${source_copy}/configure" | awk '{print $1}')" = \
	"$expected_configure_sha" ] || fail 'candidate configure changed unexpectedly'

(
	cd "$source_copy"
	./configure --prefix="$production_prefix"
) >"${log_root}/configure.out" 2>"${log_root}/configure.err" || \
	fail 'configure failed'

if cmp -s "${source_tree}/config.h" "${source_copy}/config.h"; then
	config_h_match=YES
else
	config_h_match=NO
	diff -u "${source_tree}/config.h" "${source_copy}/config.h" \
		>"${log_root}/config-h.diff" 2>&1 || true
fi

(
	cd "$source_copy"
	make -j4
) >"${log_root}/make.out" 2>"${log_root}/make.err" || \
	fail 'full build failed'

(
	cd "$source_copy"
	make -j4 check
) >"${log_root}/make-check.out" 2>"${log_root}/make-check.err" || \
	fail 'make check failed'

(
	cd "$source_copy"
	make DESTDIR="$stage_root" install
) >"${log_root}/make-install.out" 2>"${log_root}/make-install.err" || \
	fail 'DESTDIR install failed'

build_binary=${source_copy}/src/slurmctld/.libs/slurmctld
stage_binary=${stage_root}${production_prefix}/sbin/slurmctld
[ -x "$build_binary" ] || fail 'build-tree slurmctld is absent'
[ -x "$stage_binary" ] || fail 'staged slurmctld is absent'

file "$build_binary" "$stage_binary" >"${log_root}/binary-file.txt"
for candidate_binary in "$build_binary" "$stage_binary"; do
	file "$candidate_binary" | \
		grep -F 'ELF 64-bit LSB pie executable, x86-64' >/dev/null || \
		fail "candidate is not x86-64 ELF=${candidate_binary}"
done

ldd "$build_binary" >"${log_root}/binary-ldd.txt" 2>&1 || \
	fail 'candidate ldd failed'
if grep -Fq 'not found' "${log_root}/binary-ldd.txt"; then
	fail 'candidate runtime dependency is missing'
fi

cmp -s "$build_binary" "$stage_binary" || \
	fail 'build and staged slurmctld differ'

sha256sum "$build_binary" "$stage_binary" \
	>"${log_root}/candidate-binaries.sha256"
sha256sum \
	"${source_copy}/src/common/openssl_helper.c" \
	"${source_copy}/src/common/openssl_helper.h" \
	"${source_copy}/src/plugins/auth/slurm/auth_slurm.c" \
	>"${log_root}/candidate-sources.sha256"

build_sha=$(sha256sum "$build_binary" | awk '{print $1}')
build_size=$(stat -c '%s' "$build_binary")
build_id=$(file -L "$build_binary" | sed -n 's/.*BuildID\[sha1\]=\([^,]*\).*/\1/p')

printf '%s\n' \
	'SMD405_OPENSSL_CANDIDATE_BUILD_RESULTS' \
	"source_head=${expected_source_head}" \
	"patch_sha256=${expected_patch_sha}" \
	"makefile_patch_sha256=${expected_makefile_patch_sha}" \
	'autoreconf=NOT_RUN_VERSION_MATCHED_GENERATED_DELTA_USED' \
	"config_h_match=${config_h_match}" \
	"candidate_binary_sha256=${build_sha}" \
	"candidate_binary_size=${build_size}" \
	"candidate_build_id=${build_id:-ABSENT}" \
	'full_build=PASS' \
	'make_check=PASS' \
	'destdir_install=PASS' \
	'production_install=NOT_RUN' \
	"run_root=${run_root}"

[ "$config_h_match" = YES ] || fail 'candidate config.h differs from production build'

printf '%s\n' 'SMD405_OPENSSL_CANDIDATE_BUILD_COMPLETE'
