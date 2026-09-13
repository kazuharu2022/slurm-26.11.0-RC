#!/bin/sh

set -u

prefix=/opt/slurm/26.11.0
source_plist=/Users/REDACTED_USER/dev/slurm.26-05/etc/launchd/org.schedmd.slurm.slurmd.plist
target_dir=/Library/LaunchDaemons
target_plist=${target_dir}/org.schedmd.slurm.slurmd.plist
state_file=${prefix}/.smd406-ipv6-runtime.env
expected_source=5db42efbc0f476ae54968a397961807a6061eea2d53fb131c12329c6e611ede9
monitor_seconds=${SMD406_PLIST_MONITOR_SECONDS:-180}
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd406-plist-probe-${run_stamp}
trace_pid=
tmp_plist=

fail()
{
	/usr/bin/printf 'error: %s\n' "$1" >&2
	exit 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ -n "$trace_pid" ] && /bin/kill -0 "$trace_pid" >/dev/null 2>&1; then
		/bin/kill -TERM "$trace_pid" >/dev/null 2>&1 || true
		wait "$trace_pid" 2>/dev/null || true
	fi
	if [ -n "$tmp_plist" ] && [ -e "$tmp_plist" ]; then
		/bin/rm -f "$tmp_plist"
	fi
	exit "$rc"
}

trap cleanup EXIT HUP INT TERM

[ "${SMD406_PLIST_RESTORE_PROBE_CONFIRMED:-}" = YES ] || {
	/usr/bin/printf '%s\n' \
		'error: set SMD406_PLIST_RESTORE_PROBE_CONFIRMED=YES after approving the plist persistence probe' >&2
	exit 64
}
[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this probe is for macOS'

case "$monitor_seconds" in
''|*[!0-9]*) fail 'invalid monitor duration' ;;
esac
[ "$monitor_seconds" -ge 30 ] && [ "$monitor_seconds" -le 600 ] ||
	fail 'monitor duration must be between 30 and 600 seconds'

for required in "$source_plist" "$state_file" "${prefix}/bin/scontrol" \
	"${prefix}/bin/squeue" /usr/bin/fs_usage /usr/bin/install /usr/bin/shasum \
	/usr/bin/find /usr/bin/grep /usr/bin/stat /bin/launchctl /bin/mv; do
	[ -e "$required" ] || fail "missing $required"
done

umask 077
/bin/mkdir "$run_dir" || fail 'cannot create run directory'

actual_source=$(/usr/bin/shasum -a 256 "$source_plist" |
	/usr/bin/awk '{print $1}')
[ "$actual_source" = "$expected_source" ] || fail 'source plist hash mismatch'
/usr/bin/plutil -lint "$source_plist" >"${run_dir}/source-lint.txt" 2>&1 ||
	fail 'source plist lint failed'

pid=$(/bin/cat /var/run/slurmd.pid 2>/dev/null || true)
case "$pid" in
''|*[!0-9]*) fail 'invalid or missing slurmd pidfile' ;;
esac
/bin/kill -0 "$pid" >/dev/null 2>&1 || fail 'slurmd pid is not alive'
/bin/launchctl procinfo "$pid" >"${run_dir}/procinfo-before.txt" 2>&1 ||
	fail 'launchctl procinfo failed'
/usr/bin/grep -Fq 'system/org.schedmd.slurmd = {' "${run_dir}/procinfo-before.txt" ||
	fail 'slurmd is not associated with the expected launchd service'
/usr/bin/grep -Fq 'state = running' "${run_dir}/procinfo-before.txt" ||
	fail 'launchd service is not running'

export SLURM_CONF=${prefix}/etc/slurm.conf
"${prefix}/bin/scontrol" show node PC-210 >"${run_dir}/node-before.txt" 2>&1 ||
	fail 'cannot read PC-210'
node_state=$(/usr/bin/awk '{
	for (i=1;i<=NF;i++) if ($i ~ /^State=/) {
		sub(/^State=/,"",$i); print $i; exit
	}
}' "${run_dir}/node-before.txt")
[ "$node_state" = IDLE ] || fail "node is not IDLE: $node_state"
[ -z "$("${prefix}/bin/squeue" -h -w PC-210)" ] ||
	fail 'PC-210 has active jobs'

found_before=$(/usr/bin/find "$target_dir" -maxdepth 1 \
	-name 'org.schedmd.slurm.slurmd.plist' -print -quit 2>/dev/null)
if [ -e "$target_plist" ] || [ -n "$found_before" ]; then
	fail 'target plist already exists; refusing to overwrite'
fi

/usr/bin/printf 'mode=RESTORE_FILE_AND_MONITOR run_dir=%s pid=%s monitor_seconds=%s\n' \
	"$run_dir" "$pid" "$monitor_seconds"

/usr/bin/fs_usage -w -f pathname -t "$monitor_seconds" \
	>"${run_dir}/fs-usage.txt" 2>"${run_dir}/fs-usage.err" &
trace_pid=$!
/bin/sleep 1
/bin/kill -0 "$trace_pid" >/dev/null 2>&1 ||
	fail 'fs_usage monitor did not stay running'

tmp_plist=${target_plist}.smd406.$$
/usr/bin/install -o root -g wheel -m 0644 "$source_plist" "$tmp_plist" ||
	fail 'cannot stage target plist'
/bin/mv -f "$tmp_plist" "$target_plist" || fail 'cannot install target plist'
tmp_plist=

/usr/bin/plutil -lint "$target_plist" >"${run_dir}/target-lint.txt" 2>&1 ||
	fail 'installed target plist lint failed'
/usr/bin/shasum -a 256 "$target_plist" >"${run_dir}/target-initial.sha256" ||
	fail 'cannot hash installed target plist'
/usr/bin/stat -f '%i %Su:%Sg:%Lp %z %N' "$target_plist" \
	>"${run_dir}/target-initial.stat" || fail 'cannot stat installed target plist'
/usr/bin/printf 'target_installed=PASS path=%s\n' "$target_plist"

attempt=0
disappeared_at=
while [ "$attempt" -lt "$monitor_seconds" ]; do
	direct=NO
	directory=NO
	[ -f "$target_plist" ] && direct=YES
	found=$(/usr/bin/find "$target_dir" -maxdepth 1 \
		-name 'org.schedmd.slurm.slurmd.plist' -print -quit 2>/dev/null)
	[ -n "$found" ] && directory=YES
	/usr/bin/printf '%s direct=%s directory=%s\n' "$attempt" "$direct" "$directory" \
		>>"${run_dir}/presence.txt"
	if [ "$direct" = NO ] && [ "$directory" = NO ]; then
		disappeared_at=$attempt
		break
	fi
	if [ $((attempt % 30)) -eq 0 ]; then
		/usr/bin/printf 'monitor elapsed=%s direct=%s directory=%s\n' \
			"$attempt" "$direct" "$directory"
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done

if /bin/kill -0 "$trace_pid" >/dev/null 2>&1; then
	/bin/kill -TERM "$trace_pid" >/dev/null 2>&1 || true
fi
wait "$trace_pid" 2>/dev/null || true
trace_pid=

/usr/bin/grep -F 'org.schedmd.slurm.slurmd.plist' "${run_dir}/fs-usage.txt" \
	>"${run_dir}/plist-events.txt" 2>/dev/null || true
/usr/bin/printf '%s\n' '[plist-events]'
/bin/cat "${run_dir}/plist-events.txt"

/bin/launchctl procinfo "$pid" >"${run_dir}/procinfo-after.txt" 2>&1 || true
"${prefix}/bin/scontrol" show node PC-210 >"${run_dir}/node-after.txt" 2>&1 || true
"${prefix}/bin/squeue" -h -w PC-210 >"${run_dir}/queue-after.txt" 2>&1 || true

if [ -n "$disappeared_at" ]; then
	/usr/bin/printf 'SMD406_PLIST_PERSISTENCE_RESULT=DISAPPEARED elapsed_seconds=%s run_dir=%s\n' \
		"$disappeared_at" "$run_dir"
	exit 0
fi

final_hash=$(/usr/bin/shasum -a 256 "$target_plist" 2>/dev/null |
	/usr/bin/awk '{print $1}')
[ "$final_hash" = "$expected_source" ] || fail 'target plist final hash mismatch'
final_meta=$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$target_plist" 2>/dev/null)
[ "$final_meta" = root:wheel:644 ] || fail "target plist final metadata mismatch: $final_meta"
/usr/bin/printf 'SMD406_PLIST_PERSISTENCE_RESULT=PERSISTED elapsed_seconds=%s hash=%s metadata=%s run_dir=%s\n' \
	"$monitor_seconds" "$final_hash" "$final_meta" "$run_dir"
