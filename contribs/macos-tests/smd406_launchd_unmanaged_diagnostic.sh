#!/bin/sh

set -u

prefix=/opt/slurm/26.11.0
source_plist=/Users/REDACTED_USER/dev/slurm.26-05/etc/launchd/org.schedmd.slurm.slurmd.plist
target_plist=/Library/LaunchDaemons/org.schedmd.slurm.slurmd.plist
service=system/org.schedmd.slurm.slurmd
state_file=${prefix}/.smd406-ipv6-runtime.env
expected_source=5db42efbc0f476ae54968a397961807a6061eea2d53fb131c12329c6e611ede9
timestamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd406-launchd-diagnostic-${timestamp}
report=${run_dir}/report.txt

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	/usr/bin/printf '%s\n' 'error: run as root' >&2
	exit 77
fi

umask 077
/bin/mkdir -p "$run_dir" || exit 1

{
	/usr/bin/printf 'mode=READ_ONLY run_dir=%s\n' "$run_dir"

	/usr/bin/printf '\n[source-plist]\n'
	if [ -f "$source_plist" ]; then
		/usr/bin/plutil -lint "$source_plist" 2>&1 || true
		/usr/bin/shasum -a 256 "$source_plist" 2>&1 || true
		/usr/bin/stat -f '%Su:%Sg:%Lp %z %N' "$source_plist" 2>&1 || true
		actual_source=$(/usr/bin/shasum -a 256 "$source_plist" 2>/dev/null |
			/usr/bin/awk '{print $1}')
		if [ "$actual_source" = "$expected_source" ]; then
			/usr/bin/printf 'source_hash=PASS\n'
		else
			/usr/bin/printf 'source_hash=FAIL expected=%s actual=%s\n' \
				"$expected_source" "$actual_source"
		fi
	else
		/usr/bin/printf 'source_plist=ABSENT\n'
	fi

	/usr/bin/printf '\n[target-plist]\n'
	if [ -e "$target_plist" ]; then
		/usr/bin/plutil -lint "$target_plist" 2>&1 || true
		/usr/bin/shasum -a 256 "$target_plist" 2>&1 || true
		/usr/bin/stat -f '%Su:%Sg:%Lp %z %N' "$target_plist" 2>&1 || true
		/bin/ls -leO@ "$target_plist" 2>&1 || true
	else
		/usr/bin/printf 'target_plist=ABSENT\n'
	fi

	/usr/bin/printf '\n[launchdaemons-directory]\n'
	/bin/ls -ldeO@ /Library /Library/LaunchDaemons 2>&1 || true
	/usr/bin/find /Library/LaunchDaemons -maxdepth 1 -iname '*slurm*' -ls 2>&1 || true

	/usr/bin/printf '\n[launchd-service]\n'
	/bin/launchctl print "$service" 2>&1 || true

	/usr/bin/printf '\n[pidfile-and-process]\n'
	pid=
	if [ -f /var/run/slurmd.pid ]; then
		pid=$(/bin/cat /var/run/slurmd.pid 2>/dev/null || true)
		/usr/bin/printf 'pidfile=%s\n' "$pid"
	else
		/usr/bin/printf 'pidfile=ABSENT\n'
	fi
	/usr/bin/pgrep -lf slurmd 2>&1 || true
	case "$pid" in
	''|*[!0-9]*) ;;
	*)
		/bin/ps eww -p "$pid" -o pid,ppid,lstart,state,command 2>&1 || true
		/bin/launchctl procinfo "$pid" 2>&1 || true
		/bin/launchctl print "pid/$pid" 2>&1 || true
		/usr/sbin/lsof -nP -a -p "$pid" -iTCP:6818 -sTCP:LISTEN 2>&1 || true
		;;
	esac

	/usr/bin/printf '\n[related-processes]\n'
	/bin/ps axww -o pid,ppid,lstart,state,command 2>&1 |
		/usr/bin/grep -E '[s]md406|[i]nstall-slurmd|[l]aunchctl|[s]lurmd' || true

	/usr/bin/printf '\n[launchd-event-window]\n'
	/usr/bin/log show \
		--start '2026-09-12 16:59:45' \
		--end '2026-09-12 17:00:15' \
		--style compact --info --debug \
		--predicate 'eventMessage CONTAINS[c] "org.schedmd.slurm.slurmd" OR eventMessage CONTAINS[c] "82938" OR eventMessage CONTAINS[c] "bootstrap"' \
		2>&1 || true

	/usr/bin/printf '\n[runtime-state]\n'
	if [ -f "$state_file" ]; then
		/usr/bin/stat -f '%Su:%Sg:%Lp %N' "$state_file" 2>&1 || true
		/bin/cat "$state_file" 2>&1 || true
	else
		/usr/bin/printf 'state_file=ABSENT\n'
	fi

	/usr/bin/printf '\n[mac-ula]\n'
	/sbin/ifconfig en0 2>&1 |
		/usr/bin/grep -F 'fd40:534d:4406:1::128' ||
		/usr/bin/printf 'mac_ula=ABSENT\n'

	/usr/bin/printf '\n[controller-node-queue]\n'
	SLURM_CONF=${prefix}/etc/slurm.conf "${prefix}/bin/scontrol" ping 2>&1 || true
	SLURM_CONF=${prefix}/etc/slurm.conf "${prefix}/bin/scontrol" show node PC-210 2>&1 || true
	SLURM_CONF=${prefix}/etc/slurm.conf "${prefix}/bin/squeue" -h -w PC-210 2>&1 || true
} | /usr/bin/tee "$report"

/usr/bin/printf 'SMD406_LAUNCHD_DIAGNOSTIC_COMPLETE run_dir=%s report=%s\n' \
	"$run_dir" "$report"
