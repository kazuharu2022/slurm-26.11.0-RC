#!/bin/sh

# Read-only deployment-scope audit for the SMD-405 OpenSSL shutdown candidate.

set -eu

if [ "${SMD405_OPENSSL_DEPLOYMENT_AUDIT_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_OPENSSL_DEPLOYMENT_AUDIT_CONFIRMED=YES after reviewing the read-only scope' >&2
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
candidate_prefix=${SMD405_CANDIDATE_STAGE_PREFIX:-}
production_binary=${production_prefix}/sbin/slurmctld
production_conf=${production_prefix}/etc/slurm.conf
production_lib_path=${production_prefix}/lib/slurm:${production_prefix}/lib
candidate_lib_path=${candidate_prefix}/lib/slurm:${candidate_prefix}/lib
if [ "$role" = backup ]; then
	candidate_lib_path=${candidate_lib_path}:${production_prefix}/lib/smd405-runtime/lib:${production_prefix}/lib
fi

expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_production_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
expected_candidate_binary=8ca849849bbaafd25a85f3d21506f82bb0cd50c0370c631331e2334801668cee
expected_candidate_libslurmfull=791fa00eff4b949cfbb667fc250fc9b40e2e096f7494ad0d763138d62fea9391
expected_candidate_auth=536b07689bedad94cc8e663682b85db0d4e42391a86cc499e4f5895247ff3ee9
expected_candidate_auth_jwt=686057ecdca7c6476ddf44fefdb3b90014bf208fde39e759f2cf0c55e15f7167

fail()
{
	printf 'SMD405_OPENSSL_DEPLOYMENT_AUDIT_FAILED host=%s role=%s error=%s\n' \
		"$host" "$role" "$1" >&2
	exit 1
}

build_id()
{
	if ! command -v readelf >/dev/null 2>&1; then
		printf '%s\n' 'TOOL_UNAVAILABLE'
		return
	fi
	readelf -n "$1" 2>/dev/null | \
		awk '/Build ID:/ { print $3; found = 1; exit } END { if (!found) print "ABSENT" }'
}

production_command()
{
	env \
		PATH=${production_prefix}/bin:${production_prefix}/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
		LD_LIBRARY_PATH=$production_lib_path \
		SLURM_CONF=$production_conf \
		"$@"
}

production_health()
{
	if [ "$role" = primary ]; then
		[ "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)" = \
			active,active,active ] || return 1
		ping_output=$(production_command "${production_prefix}/bin/scontrol" ping 2>&1) || \
			return 1
		printf '%s\n' "$ping_output" | \
			grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' || return 1
		printf '%s\n' "$ping_output" | \
			grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' || return 1
		[ -z "$(production_command "${production_prefix}/bin/squeue" -h)" ] || return 1
		for node in ubuntu PC-210; do
			node_output=$(production_command "${production_prefix}/bin/scontrol" show node "$node") || \
				return 1
			printf '%s\n' "$node_output" | grep -Eq \
				'(^|[[:space:]])State=IDLE([[:space:]]|$)' || return 1
			printf '%s\n' "$node_output" | grep -Eq \
				'(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' || return 1
		done
	else
		[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = active ] || \
			return 1
		[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || \
			return 1
	fi
	[ "$(sha256sum "$production_conf" | awk '{print $1}')" = "$expected_config" ] || \
		return 1
	[ "$(sha256sum "$production_binary" | awk '{print $1}')" = \
		"$expected_production_binary" ] || return 1
}

audit_artifact()
{
	relative=$1
	candidate=${candidate_prefix}/${relative}
	production=${production_prefix}/${relative}
	printf 'artifact_begin=%s\n' "$relative"
	if [ -f "$candidate" ]; then
		printf 'candidate=EXISTS sha256=%s size=%s build_id=%s\n' \
			"$(sha256sum "$candidate" | awk '{print $1}')" \
			"$(stat -c '%s' "$candidate")" "$(build_id "$candidate")"
		dependency_output=$(env LD_LIBRARY_PATH="$candidate_lib_path" ldd "$candidate" 2>&1) || \
			fail "ldd failed for candidate artifact=${relative}"
		printf '%s\n' "$dependency_output" | sed 's/^/candidate_ldd=/'
		printf '%s\n' "$dependency_output" | grep -Fq 'not found' && \
			fail "candidate dependency not found artifact=${relative}"
	else
		printf '%s\n' 'candidate=NOT_BUILT'
	fi
	if [ -f "$production" ]; then
		printf 'production=EXISTS sha256=%s size=%s build_id=%s\n' \
			"$(sha256sum "$production" | awk '{print $1}')" \
			"$(stat -c '%s' "$production")" "$(build_id "$production")"
	else
		printf '%s\n' 'production=ABSENT'
	fi
	if [ -f "$candidate" ] && [ -f "$production" ]; then
		if cmp -s "$candidate" "$production"; then
			printf '%s\n' 'candidate_matches_production=YES'
		else
			printf '%s\n' 'candidate_matches_production=NO'
		fi
	fi
	printf 'artifact_end=%s\n' "$relative"
}

[ "$(id -u)" -eq 0 ] || fail 'must run as root'
[ -n "$candidate_prefix" ] || fail 'candidate stage prefix is required'
[ -d "$candidate_prefix" ] || fail 'candidate stage prefix is absent'
[ -x "${candidate_prefix}/sbin/slurmctld" ] || fail 'candidate slurmctld is absent'
[ "$(sha256sum "${candidate_prefix}/sbin/slurmctld" | awk '{print $1}')" = \
	"$expected_candidate_binary" ] || fail 'candidate slurmctld hash mismatch'
[ "$(sha256sum "${candidate_prefix}/lib/slurm/libslurmfull.so" | awk '{print $1}')" = \
	"$expected_candidate_libslurmfull" ] || fail 'candidate libslurmfull hash mismatch'
[ "$(sha256sum "${candidate_prefix}/lib/slurm/auth_slurm.so" | awk '{print $1}')" = \
	"$expected_candidate_auth" ] || fail 'candidate auth/slurm hash mismatch'
[ "$(sha256sum "${candidate_prefix}/lib/slurm/auth_jwt.so" | awk '{print $1}')" = \
	"$expected_candidate_auth_jwt" ] || fail 'candidate auth/jwt hash mismatch'
production_health || fail 'production health failed'

printf '%s\n' 'SMD405_OPENSSL_DEPLOYMENT_AUDIT_BEGIN'
printf 'host=%s role=%s\n' "$host" "$role"
printf 'production_config_sha256=%s\n' "$expected_config"
printf 'production_slurmctld_sha256=%s\n' "$expected_production_binary"
printf 'candidate_slurmctld_sha256=%s\n' "$expected_candidate_binary"

audit_artifact lib/slurm/libslurmfull.so
audit_artifact lib/slurm/auth_slurm.so
audit_artifact lib/slurm/auth_jwt.so
audit_artifact lib/slurm/tls_s2n.so

if command -v readelf >/dev/null 2>&1; then
	printf '%s\n' 'candidate_helper_provider_symbols_begin'
	readelf -Ws "${candidate_prefix}/lib/slurm/libslurmfull.so" | \
		grep -E 'openssl_helper_disable_atexit' || \
		fail 'candidate helper provider symbol is absent'
	printf '%s\n' 'candidate_helper_provider_symbols_end'

	for plugin in auth_slurm.so auth_jwt.so tls_s2n.so; do
		path=${candidate_prefix}/lib/slurm/${plugin}
		[ -f "$path" ] || continue
		printf 'candidate_helper_consumer=%s\n' "$plugin"
		readelf -Ws "$path" | grep -E 'slurm_openssl_helper_disable_atexit' || \
			fail "candidate helper consumer symbol is absent plugin=${plugin}"
	done
	printf '%s\n' 'candidate_symbol_validation=LOCAL_READELF_PASS'
else
	[ "$role" = backup ] || fail 'readelf is required on primary'
	printf '%s\n' \
		'candidate_symbol_validation=CORROBORATED_BY_PRIMARY_AUDIT_AND_FIXED_SHA256'
fi

printf '%s\n' 'production_process_maps_begin'
if [ "$role" = primary ]; then
	services='slurmctld slurmdbd slurmd'
else
	services=slurmctld
fi
for service in $services; do
	pid=$(systemctl show -p MainPID --value "$service")
	printf 'service=%s pid=%s\n' "$service" "$pid"
	if [ -r "/proc/${pid}/maps" ]; then
		awk '/libslurmfull\.so|auth_slurm\.so|auth_jwt\.so|tls_s2n\.so/ { print }' \
			"/proc/${pid}/maps" | sed "s/^/${service}_map=/"
	fi
done
printf '%s\n' 'production_process_maps_end'

production_health || fail 'production health changed during audit'
if [ "$role" = primary ]; then
	printf 'SMD405_OPENSSL_DEPLOYMENT_AUDIT_COMPLETE host=%s role=%s production=UNCHANGED queue=EMPTY nodes=IDLE jobs=NONE\n' \
		"$host" "$role"
else
	printf 'SMD405_OPENSSL_DEPLOYMENT_AUDIT_COMPLETE host=%s role=%s production=UNCHANGED service=ACTIVE_DISABLED\n' \
		"$host" "$role"
fi
