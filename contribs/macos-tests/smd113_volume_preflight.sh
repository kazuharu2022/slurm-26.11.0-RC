#!/bin/sh

set -u

if [ "${SMD113_VOLUME_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD113_VOLUME_PREFLIGHT_CONFIRMED=YES after accepting a 64 MiB disposable image' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
service_label=org.schedmd.slurmd
service_target=system/${service_label}
plist_hint=/Library/LaunchDaemons/${service_label}.plist
pid_file=/var/run/slurmd.pid
source_driver=/Users/REDACTED_USER/dev/slurm.26-05/contribs/macos-tests/smd113_volume_preflight.sh
volume_size_mib=64
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd113-preflight-${run_stamp}
mount_point=${run_dir}/volume
mount_point_physical=
image=${run_dir}/smd113-test.dmg
spool=${mount_point}/spool
filler=${mount_point}/filler.bin
device=
mounted=0
old_pid=
success=0

export LC_ALL=C

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
}

is_running()
{
	[ -n "$1" ] && /bin/kill -0 "$1" >/dev/null 2>&1
}

get_service_pid()
{
	/bin/launchctl print "$service_target" 2>/dev/null | /usr/bin/awk '
		$1 == "pid" && $2 == "=" { print $3; exit }
	'
}

capture_input_hashes()
{
	output=$1
	/usr/bin/shasum -a 256 "$slurm_conf" "$source_driver" >"$output" ||
		return 1
	if [ -e "$plist_hint" ]; then
		/usr/bin/shasum -a 256 "$plist_hint" >>"$output" || return 1
	else
		/usr/bin/printf 'NOT_PRESENT  %s\n' "$plist_hint" >>"$output"
	fi
}

is_mounted()
{
	[ -n "$mount_point_physical" ] || return 1
	/sbin/mount | /usr/bin/awk -v target="$mount_point_physical" '
		$2 == "on" && $3 == target { found = 1 }
		END { exit !found }
	'
}

detach_volume()
{
	[ "$mounted" -eq 1 ] || return 0
	target=$device
	[ -n "$target" ] || target=$mount_point_physical
	[ -n "$target" ] || target=$mount_point
	if /usr/bin/hdiutil detach "$target" >"${run_dir}/detach.out" \
		2>"${run_dir}/detach.err"; then
		mounted=0
		return 0
	fi
	return 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$mounted" -eq 1 ]; then
		target=$device
		[ -n "$target" ] || target=$mount_point_physical
		[ -n "$target" ] || target=$mount_point
		/bin/rm -f -- "$filler" 2>/dev/null || true
		/usr/bin/find "$mount_point" -type f \
			-name 'exhaust-*' -delete 2>/dev/null || true
		/usr/bin/hdiutil detach -force "$target" \
			>"${run_dir}/recovery-detach.out" \
			2>"${run_dir}/recovery-detach.err" || true
		mounted=0
	fi
	if [ -f "$image" ]; then
		/bin/rm -f -- "$image" 2>/dev/null || true
	fi
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf '%s\n' \
			"recovery: disposable image cleanup attempted;" \
			"production was not changed; inspect run_dir=${run_dir}" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this preflight is for macOS'
for path in "$slurm_conf" "$pid_file" "$source_driver"; do
	[ -e "$path" ] || fail "missing $path"
done
for command in /bin/cat /bin/cp /bin/date /bin/dd /bin/df /bin/kill \
	/bin/launchctl /bin/mkdir /bin/pwd /bin/rm /bin/rmdir /bin/sh /sbin/mount \
	/usr/bin/awk \
	/usr/bin/diff /usr/bin/find \
	/usr/bin/grep /usr/bin/hdiutil /usr/bin/id /usr/bin/sed /usr/bin/shasum \
	/usr/bin/stat /usr/bin/tail /usr/bin/wc; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$mount_point" ||
	fail 'cannot create preflight directories'
mount_point_physical=$(cd "$mount_point" && /bin/pwd -P) ||
	fail 'cannot resolve physical mount point'
trap cleanup EXIT HUP INT TERM

old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$old_pid" ;;
esac
is_running "$old_pid" || fail 'production slurmd is not running'
/bin/launchctl print "$service_target" >"${run_dir}/launchd-before.txt" 2>&1 ||
	fail "launchd service is not loaded: $service_target"
/usr/bin/grep -q 'state = running' "${run_dir}/launchd-before.txt" ||
	fail 'launchd slurmd service is not running'
launchd_pid=$(get_service_pid)
[ "$launchd_pid" = "$old_pid" ] ||
	fail "launchd/pidfile slurmd identity mismatch: launchd=$launchd_pid pidfile=$old_pid"
capture_input_hashes "${run_dir}/inputs-before.sha256" ||
	fail 'cannot capture production input hashes'
/bin/df -k /var/spool/slurmd /var/log/slurm \
	>"${run_dir}/production-df-before.txt" 2>&1 ||
	fail 'cannot capture production filesystem capacity'
/usr/bin/printf '%s%s\n' \
	"mode=DISPOSABLE_VOLUME_ONLY run_dir=${run_dir} volume_size_mib=${volume_size_mib}" \
	" slurmd_pid=${old_pid} mount_point=${mount_point_physical}"

/usr/bin/hdiutil create -quiet -size "${volume_size_mib}m" -fs HFS+ \
	-volname SMD113TEST "$image" >"${run_dir}/create.out" \
	2>"${run_dir}/create.err" || fail 'cannot create disposable disk image'
/usr/bin/hdiutil attach -nobrowse -owners on -mountpoint "$mount_point_physical" \
	"$image" >"${run_dir}/attach.out" 2>"${run_dir}/attach.err" ||
	fail 'cannot attach disposable disk image'
mounted=1
is_mounted || fail 'disposable image is not mounted at the expected path'
device=$(/usr/bin/awk -v mount="$mount_point_physical" '$NF == mount {
		print $1; exit
	}' "${run_dir}/attach.out")
case "$device" in
/dev/disk*) ;;
*) fail "cannot identify attached device=$device" ;;
esac
/bin/mkdir -m 0755 "$spool" || fail 'cannot create isolated spool directory'
/bin/df -k "$mount_point" >"${run_dir}/volume-df-before.txt" ||
	fail 'cannot capture initial disposable volume capacity'
/usr/bin/stat -f 'path=%N device=%d inode=%i owner=%u:%g mode=%Lp' \
	"$mount_point" "$spool" >"${run_dir}/volume-identity.txt" ||
	fail 'cannot capture disposable volume identity'

if /bin/dd if=/dev/zero of="$filler" bs=1048576 count=128 \
	>"${run_dir}/fill-dd.out" 2>"${run_dir}/fill-dd.err"; then
	dd_rc=0
else
	dd_rc=$?
fi
[ "$dd_rc" -ne 0 ] || fail 'filler unexpectedly fit in the 64 MiB image'
/usr/bin/grep -Eiq 'No space left on device|not enough space' \
	"${run_dir}/fill-dd.err" || fail 'dd failure was not ENOSPC'

if /bin/mkdir "${spool}/probe-dir" >"${run_dir}/mkdir-full.out" \
	2>"${run_dir}/mkdir-full.err"; then
	mkdir_rc=0
else
	mkdir_rc=$?
fi
if [ "$mkdir_rc" -eq 0 ]; then
	/bin/rmdir "${spool}/probe-dir" || fail 'cannot remove initial probe directory'
	index=1
	: >"${run_dir}/metadata-fill.err"
	while [ "$index" -le 10000 ]; do
		/bin/sh -c ': > "$1"' sh "${mount_point}/exhaust-${index}" \
			2>>"${run_dir}/metadata-fill.err" || break
		index=$((index + 1))
	done
	[ "$index" -le 10000 ] || fail 'metadata exhaustion bound reached without ENOSPC'
	if /bin/mkdir "${spool}/probe-dir" \
		>"${run_dir}/mkdir-full-retry.out" \
		2>"${run_dir}/mkdir-full-retry.err"; then
		mkdir_rc=0
	else
		mkdir_rc=$?
	fi
	/bin/cp "${run_dir}/mkdir-full-retry.err" "${run_dir}/mkdir-full.err" ||
		fail 'cannot preserve mkdir retry error'
fi
[ "$mkdir_rc" -ne 0 ] || fail 'mkdir unexpectedly succeeded on the full image'
/usr/bin/grep -Eiq 'No space left on device|not enough space' \
	"${run_dir}/mkdir-full.err" || fail 'mkdir failure was not ENOSPC'
/bin/df -k "$mount_point" >"${run_dir}/volume-df-full.txt" ||
	fail 'cannot capture full disposable volume capacity'
/usr/bin/printf 'enospc_observed dd_rc=%s mkdir_rc=%s device=%s\n' \
	"$dd_rc" "$mkdir_rc" "$device"

/bin/rm -f -- "$filler" || fail 'cannot remove filler'
/usr/bin/find "$mount_point" -type f -name 'exhaust-*' -delete ||
	fail 'cannot remove metadata fillers'
/bin/mkdir "${spool}/recovery-dir" || fail 'mkdir did not recover after freeing space'
/bin/rmdir "${spool}/recovery-dir" || fail 'cannot remove recovery directory'
/bin/df -k "$mount_point" >"${run_dir}/volume-df-recovered.txt" ||
	fail 'cannot capture recovered disposable volume capacity'
detach_volume || fail 'cannot detach disposable disk image'
is_mounted && fail 'disposable image remains mounted after detach'
/bin/rm -f -- "$image" || fail 'cannot remove detached disk image'
[ ! -e "$image" ] || fail 'detached disk image remains'

capture_input_hashes "${run_dir}/inputs-after.sha256" ||
	fail 'cannot capture final production input hashes'
/usr/bin/diff -u "${run_dir}/inputs-before.sha256" \
	"${run_dir}/inputs-after.sha256" >"${run_dir}/inputs.diff" ||
	fail 'production inputs or preflight driver changed'
[ "$(/bin/cat "$pid_file")" = "$old_pid" ] || fail 'production slurmd PID changed'
is_running "$old_pid" || fail 'production slurmd stopped during preflight'
/bin/launchctl print "$service_target" >"${run_dir}/launchd-after.txt" 2>&1 ||
	fail 'launchd slurmd service disappeared during preflight'
/usr/bin/grep -q 'state = running' "${run_dir}/launchd-after.txt" ||
	fail 'launchd slurmd service stopped during preflight'
[ "$(get_service_pid)" = "$old_pid" ] ||
	fail 'launchd slurmd PID changed during preflight'
/bin/df -k /var/spool/slurmd /var/log/slurm \
	>"${run_dir}/production-df-after.txt" 2>&1 ||
	fail 'cannot capture final production filesystem capacity'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s\n' \
	"SMD113_VOLUME_PREFLIGHT_COMPLETE volume_size_mib=${volume_size_mib}" \
	" dd_enospc=PASS mkdir_enospc=PASS recovery=PASS" \
	" slurmd_pid=${old_pid} production_unchanged=PASS run_dir=${run_dir}"
