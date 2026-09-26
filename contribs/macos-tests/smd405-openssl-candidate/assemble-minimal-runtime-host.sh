#!/bin/sh

# Assemble an isolated production-runtime clone with only the three SMD-405
# OpenSSL candidate artifacts overlaid. This never writes to the production
# prefix and deliberately excludes etc/ so no authentication key is copied.

set -eu
umask 077

if [ "${SMD405_OPENSSL_MINIMAL_STAGE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_OPENSSL_MINIMAL_STAGE_CONFIRMED=YES after reviewing the isolated copy scope' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

host=$(hostname -s)
case "$host" in
ubuntu2504) role=primary ;;
slurmctld-bak) role=backup ;;
*) printf 'error: unexpected hostname=%s\n' "$host" >&2; exit 64 ;;
esac

production_prefix=/usr/local/slurm/26.11.0
production_conf=${production_prefix}/etc/slurm.conf
production_binary=${production_prefix}/sbin/slurmctld
candidate_prefix=${SMD405_CANDIDATE_STAGE_PREFIX:-}
output_prefix=${SMD405_MINIMAL_STAGE_PREFIX:-}

expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_production_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
expected_candidate_libslurmfull=791fa00eff4b949cfbb667fc250fc9b40e2e096f7494ad0d763138d62fea9391
expected_candidate_auth=536b07689bedad94cc8e663682b85db0d4e42391a86cc499e4f5895247ff3ee9
expected_candidate_auth_jwt=686057ecdca7c6476ddf44fefdb3b90014bf208fde39e759f2cf0c55e15f7167

fail()
{
	printf 'SMD405_OPENSSL_MINIMAL_STAGE_FAILED host=%s role=%s error=%s output=%s\n' \
		"$host" "$role" "$1" "$output_prefix" >&2
	exit 1
}

make_manifest()
{
	prefix=$1
	output=$2
	(
		cd "$prefix"
		find bin sbin lib -type f -print | LC_ALL=C sort | while IFS= read -r relative; do
			printf '%s  %s\n' "$(sha256sum "$relative" | awk '{print $1}')" "$relative"
		done
	) >"$output"
}

[ "$(id -u)" -eq 0 ] || fail 'must run as root'
[ -n "$candidate_prefix" ] || fail 'candidate stage prefix is required'
[ -d "$candidate_prefix" ] || fail 'candidate stage prefix is absent'
[ -n "$output_prefix" ] || fail 'minimal stage prefix is required'
case "$output_prefix" in
/var/tmp/smd405-openssl-minimal-stage-*) ;;
*) fail 'minimal stage prefix is outside the allowed run-specific path' ;;
esac
[ ! -e "$output_prefix" ] || fail 'minimal stage prefix already exists'

[ "$(sha256sum "$production_conf" | awk '{print $1}')" = "$expected_config" ] || \
	fail 'production config hash mismatch'
[ "$(sha256sum "$production_binary" | awk '{print $1}')" = \
	"$expected_production_binary" ] || fail 'production slurmctld hash mismatch'
if [ "$role" = primary ]; then
	[ "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)" = \
		active,active,active ] || fail 'primary production services are not active'
else
	[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = active ] || \
		fail 'backup production slurmctld is not active'
	[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || \
		fail 'backup production slurmctld is not disabled for boot'
fi

for directory in bin sbin lib; do
	[ -d "${production_prefix}/${directory}" ] || \
		fail "production runtime directory is absent directory=${directory}"
done

for specification in \
	"lib/slurm/libslurmfull.so:${expected_candidate_libslurmfull}" \
	"lib/slurm/auth_slurm.so:${expected_candidate_auth}" \
	"lib/slurm/auth_jwt.so:${expected_candidate_auth_jwt}"
do
	relative=${specification%%:*}
	expected=${specification#*:}
	artifact=${candidate_prefix}/${relative}
	[ -f "$artifact" ] || fail "candidate artifact is absent artifact=${relative}"
	[ "$(sha256sum "$artifact" | awk '{print $1}')" = "$expected" ] || \
		fail "candidate artifact hash mismatch artifact=${relative}"
done

install -d -o root -g root -m 0755 "$output_prefix"
for directory in bin sbin lib; do
	cp -a -- "${production_prefix}/${directory}" "${output_prefix}/${directory}"
done
[ ! -e "${output_prefix}/etc" ] || fail 'SECURITY: etc unexpectedly copied into minimal stage'

for relative in \
	lib/slurm/libslurmfull.so \
	lib/slurm/auth_slurm.so \
	lib/slurm/auth_jwt.so
do
	cp -a -- "${candidate_prefix}/${relative}" "${output_prefix}/${relative}"
done

work_dir=${output_prefix}.audit
[ ! -e "$work_dir" ] || fail 'manifest work directory already exists'
install -d -o root -g root -m 0700 "$work_dir"
make_manifest "$production_prefix" "${work_dir}/production.sha256"
make_manifest "$output_prefix" "${work_dir}/minimal-stage.sha256"
awk '
	NR == FNR { production[$2] = $1; next }
	production[$2] != $1 { print $2 }
' "${work_dir}/production.sha256" "${work_dir}/minimal-stage.sha256" \
	>"${work_dir}/changed-paths.txt"
cat >"${work_dir}/expected-changed-paths.txt" <<'EOF'
lib/slurm/auth_jwt.so
lib/slurm/auth_slurm.so
lib/slurm/libslurmfull.so
EOF
cmp -s "${work_dir}/expected-changed-paths.txt" "${work_dir}/changed-paths.txt" || \
	fail 'runtime clone differs from production outside the exact three-artifact allowlist'

[ "$(sha256sum "${output_prefix}/sbin/slurmctld" | awk '{print $1}')" = \
	"$expected_production_binary" ] || fail 'minimal stage slurmctld is not the production binary'

runtime_lib_path=${output_prefix}/lib/slurm:${output_prefix}/lib
if [ -d "${output_prefix}/lib/smd405-runtime/lib" ]; then
	runtime_lib_path=${runtime_lib_path}:${output_prefix}/lib/smd405-runtime/lib
fi
{
	printf '%s\n' 'minimal_stage_slurmctld_dependencies'
	env LD_LIBRARY_PATH="$runtime_lib_path" ldd "${output_prefix}/sbin/slurmctld"
	for relative in \
		lib/slurm/libslurmfull.so \
		lib/slurm/auth_slurm.so \
		lib/slurm/auth_jwt.so
	do
		printf 'minimal_stage_artifact_dependencies=%s\n' "$relative"
		env LD_LIBRARY_PATH="$runtime_lib_path" ldd "${output_prefix}/${relative}"
	done
} >"${work_dir}/runtime-dependencies.txt" 2>&1 || \
	fail 'minimal stage dependency inspection failed'
grep -Fq 'not found' "${work_dir}/runtime-dependencies.txt" && \
	fail 'minimal stage has an unresolved runtime dependency'
grep -Fq "libslurmfull.so => ${output_prefix}/lib/slurm/libslurmfull.so" \
	"${work_dir}/runtime-dependencies.txt" || \
	fail 'minimal stage slurmctld does not resolve the overlaid libslurmfull'

printf '%s\n' 'SMD405_OPENSSL_MINIMAL_STAGE_RESULT'
printf 'host=%s role=%s\n' "$host" "$role"
printf 'output_prefix=%s\n' "$output_prefix"
printf 'runtime_binary_sha256=%s\n' "$expected_production_binary"
printf 'candidate_libslurmfull_sha256=%s\n' "$expected_candidate_libslurmfull"
printf 'candidate_auth_slurm_sha256=%s\n' "$expected_candidate_auth"
printf 'candidate_auth_jwt_sha256=%s\n' "$expected_candidate_auth_jwt"
sed 's/^/changed_path=/' "${work_dir}/changed-paths.txt"
printf '%s\n' 'secret_config_copied=NO'
printf 'SMD405_OPENSSL_MINIMAL_STAGE_COMPLETE host=%s role=%s content_delta=EXACTLY_THREE_ARTIFACTS dependencies=PASS production=UNCHANGED\n' \
	"$host" "$role"
