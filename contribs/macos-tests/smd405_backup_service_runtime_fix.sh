#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_BACKUP_SERVICE_FIX_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_BACKUP_SERVICE_FIX_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

service=/etc/systemd/system/slurmctld.service
candidate=/tmp/smd405-slurmctld-backup.service
expected_old=f832db6f974049331b67230b2f690bf373d183fd6e3038bb6110c0e17b4f276e
expected_new=46e930ee24695791d809498254092516c5efde38d136fe781172766db71bf9d2
expected_environment='LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib/smd405-runtime/lib:/usr/local/slurm/26.11.0/lib'
run_dir=/var/tmp/smd405-backup-service-runtime-fix-$(date '+%Y%m%dT%H%M%S')
mutated=0
success=0

fail()
{
	printf 'SMD405_BACKUP_SERVICE_RUNTIME_FIX_FAILED error=%s run_dir=%s\n' \
		"$1" "$run_dir" >&2
	exit 1
}

file_hash()
{
	sha256sum "$1" | awk '{print $1}'
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$mutated" -eq 1 ] && \
		[ -f "${run_dir}/slurmctld.service.before" ]; then
		install -o root -g root -m 0644 "${run_dir}/slurmctld.service.before" "$service" \
			>/dev/null 2>&1 || true
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl reset-failed slurmctld >/dev/null 2>&1 || true
		printf '%s\n' 'recovery: original backup service unit restored' >&2
	fi
	[ -d "$run_dir" ] && chmod -R a+rX "$run_dir" >/dev/null 2>&1 || true
	exit "$rc"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(hostname -s)" = slurmctld-bak ] || fail 'unexpected backup hostname'
[ -f "$service" ] || fail 'installed service unit is absent'
[ -f "$candidate" ] || fail 'candidate service unit is absent'
[ "$(file_hash "$service")" = "$expected_old" ] || fail 'installed service hash mismatch'
[ "$(file_hash "$candidate")" = "$expected_new" ] || fail 'candidate service hash mismatch'
case "$(systemctl is-active slurmctld 2>/dev/null || true)" in
inactive|failed) ;;
*) fail 'backup service is unexpectedly active' ;;
esac
[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || \
	fail 'backup service is not disabled'
pgrep -x slurmctld >/dev/null 2>&1 && fail 'unexpected slurmctld process exists'

install -d -o root -g root -m 0700 "$run_dir"
trap cleanup EXIT HUP INT TERM
cp -p "$service" "${run_dir}/slurmctld.service.before"
diff -u "$service" "$candidate" >"${run_dir}/service.diff" || \
	[ "$?" -eq 1 ] || fail 'service diff failed'
grep -Fq -- '-Environment=LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib/smd405-runtime:/usr/local/slurm/26.11.0/lib' \
	"${run_dir}/service.diff" || fail 'expected old runtime path diff is absent'
grep -Fq -- '+Environment=LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib/smd405-runtime/lib:/usr/local/slurm/26.11.0/lib' \
	"${run_dir}/service.diff" || fail 'expected new runtime path diff is absent'
[ "$(grep -Ec '^[+-][^+-]' "${run_dir}/service.diff")" -eq 2 ] || \
	fail 'candidate service contains changes beyond one line'

install -o root -g root -m 0644 "$candidate" "$service" || \
	fail 'candidate service install failed'
mutated=1
[ "$(file_hash "$service")" = "$expected_new" ] || fail 'installed service hash mismatch'
systemctl daemon-reload || fail 'systemd daemon-reload failed'
systemctl reset-failed slurmctld || fail 'systemd failed-state reset failed'
[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = inactive ] || \
	fail 'backup service is not inactive after repair'
[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || \
	fail 'backup service enablement changed'
[ "$(systemctl show -p Environment --value slurmctld)" = "$expected_environment" ] || \
	fail 'effective service environment mismatch'
pgrep -x slurmctld >/dev/null 2>&1 && fail 'unexpected slurmctld process exists after repair'
systemctl cat slurmctld >"${run_dir}/service-readback.txt"
systemctl show slurmctld -p Environment -p ActiveState -p UnitFileState \
	>"${run_dir}/service-properties.txt"

success=1
trap - EXIT HUP INT TERM
chmod -R a+rX "$run_dir"
printf 'SMD405_BACKUP_SERVICE_RUNTIME_FIX_PASS old=%s new=%s service=inactive,disabled process=ABSENT run_dir=%s\n' \
	"$expected_old" "$expected_new" "$run_dir"
