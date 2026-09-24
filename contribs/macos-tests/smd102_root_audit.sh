#!/bin/sh

set -eu

job_id=${1:-}
backup_dir=${2:-}
prefix=/opt/slurm/26.11.0
production=${prefix}/sbin/slurmstepd
backup=${backup_dir}/slurmstepd
log_file=/var/log/slurm/slurmd.log
pid_file=/var/run/slurmd.pid
marker=/tmp/smd102-root-audit-${job_id}.txt

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

case "$job_id" in
''|*[!0-9]*)
	printf 'usage: %s JOB_ID BACKUP_DIR\n' "$0" >&2
	exit 64
	;;
esac
case "$backup_dir" in
"${prefix}"/.smd102-backup-20*) ;;
*) fail 'backup directory is outside the expected SMD-102 namespace' ;;
esac

[ "${SMD102_ROOT_AUDIT_CONFIRMED:-NO}" = YES ] || {
	printf 'error: set SMD102_ROOT_AUDIT_CONFIRMED=YES\n' >&2
	exit 64
}
[ -n "${SMD102_EXPECTED_PRODUCTION_SHA256:-}" ] || fail 'missing expected production hash'
[ -n "${SMD102_EXPECTED_BACKUP_SHA256:-}" ] || fail 'missing expected backup hash'
[ -n "${SMD102_EXPECTED_SLURMD_PID:-}" ] || fail 'missing expected slurmd PID'
[ "$(/usr/bin/id -u)" -eq 0 ] || {
	printf 'error: run as root\n' >&2
	exit 77
}

for file in "$production" "$backup" "$log_file" "$pid_file"; do
	[ -f "$file" ] || fail "missing $file"
done

production_hash=$(/usr/bin/shasum -a 256 "$production" | /usr/bin/awk '{ print $1 }')
backup_hash=$(/usr/bin/shasum -a 256 "$backup" | /usr/bin/awk '{ print $1 }')
[ "$production_hash" = "$SMD102_EXPECTED_PRODUCTION_SHA256" ] || \
	fail "production hash mismatch: $production_hash"
[ "$backup_hash" = "$SMD102_EXPECTED_BACKUP_SHA256" ] || \
	fail "backup hash mismatch: $backup_hash"
[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$production")" = 0:0:755 ] || \
	fail 'production ownership or mode mismatch'
[ "$(/bin/cat "$pid_file")" = "$SMD102_EXPECTED_SLURMD_PID" ] || \
	fail 'slurmd PID file changed'
/bin/kill -0 "$SMD102_EXPECTED_SLURMD_PID" >/dev/null 2>&1 || fail 'slurmd PID is not alive'

/usr/bin/awk -v job="${job_id}.0" '
	index($0, job) &&
	index($0, "credential identity smdmismatch(3201:3201)") &&
	index($0, "local macOS identity (3202:3202)") { found = 1 }
	END { exit(found ? 0 : 1) }
' "$log_file" || fail "UID/GID mismatch log is absent for job $job_id"

marker_tmp=${marker}.tmp
trap '/bin/rm -f "$marker_tmp"' EXIT HUP INT TERM
{
	printf 'SMD102_ROOT_AUDIT_PASS job_id=%s\n' "$job_id"
	printf 'production_sha256=%s\n' "$production_hash"
	printf 'backup_sha256=%s\n' "$backup_hash"
	printf 'slurmd_pid=%s\n' "$SMD102_EXPECTED_SLURMD_PID"
	printf 'identity_log_match=credential_3201:3201_local_3202:3202\n'
} >"$marker_tmp"
/usr/bin/install -o root -g wheel -m 0644 "$marker_tmp" "$marker"
/bin/rm -f "$marker_tmp"
trap - EXIT HUP INT TERM
/bin/cat "$marker"
