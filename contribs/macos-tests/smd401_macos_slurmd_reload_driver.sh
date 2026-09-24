#!/bin/sh

set -u

if [ "${SMD401_MAC_SLURMD_RELOAD_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD401_MAC_SLURMD_RELOAD_CONFIRMED=YES after approval' >&2
	exit 64
fi

case "${SMD401_CONFIG_MODE:-}" in
apply)
	expected_conf=62bcea15398de5f373132a1a3ef21c005c184c20f483da076b44eb5af284f157
	;;
rollback)
	expected_conf=70d5f437c6622b860e3eff7c029dcd713a073bfdf90395f5399c9c95f50d16a0
	;;
*)
	printf '%s\n' 'error: set SMD401_CONFIG_MODE=apply or rollback' >&2
	exit 64
	;;
esac

conf=/opt/slurm/26.11.0/etc/slurm.conf
scontrol=/opt/slurm/26.11.0/bin/scontrol
squeue=/opt/slurm/26.11.0/bin/squeue
label=system/org.schedmd.slurmd

fail()
{
	printf 'SMD401_MAC_SLURMD_RELOAD_FAILED mode=%s error=%s\n' \
		"$SMD401_CONFIG_MODE" "$1" >&2
	exit 1
}

launchd_pid()
{
	/bin/launchctl print "$label" 2>/dev/null | /usr/bin/awk '
		$1 == "pid" && $2 == "=" { print $3; exit }
	'
}

node_field()
{
	field=$1
	"$scontrol" show node PC-210 -o | /usr/bin/awk -v key="${field}=" '
		{
			for (i = 1; i <= NF; i++) {
				if (index($i, key) == 1) {
					sub(key, "", $i)
					print $i
					exit
				}
			}
		}
	'
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root'
[ "$(/usr/bin/shasum -a 256 "$conf" | /usr/bin/awk '{print $1}')" = \
	"$expected_conf" ] || fail 'unexpected production config hash'
[ "$(node_field State)" = IDLE ] || fail 'PC-210 is not IDLE'
[ "$(node_field CPUAlloc)" = 0 ] || fail 'PC-210 is allocated'
[ -z "$("$squeue" -h -w PC-210)" ] || fail 'PC-210 queue is not empty'
pid_before=$(launchd_pid)
case "$pid_before" in ''|*[!0-9]*) fail 'invalid launchd PID before reload' ;; esac
start_before=$(node_field SlurmdStartTime)

/bin/kill -HUP "$pid_before" || fail 'cannot send SIGHUP'
attempt=0
while [ "$attempt" -lt 60 ]; do
	pid_after=$(launchd_pid)
	if [ -n "$pid_after" ] && [ "$(node_field State)" = IDLE ] && \
		[ "$(node_field CPUAlloc)" = 0 ]; then
		break
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
[ "$attempt" -lt 60 ] || fail 'slurmd did not return stable IDLE'
case "$pid_after" in ''|*[!0-9]*) fail 'invalid launchd PID after reload' ;; esac
[ -z "$("$squeue" -h -w PC-210)" ] || fail 'final PC-210 queue is not empty'
start_after=$(node_field SlurmdStartTime)

printf '%s%s%s%s\n' \
	'SMD401_MAC_SLURMD_RELOAD_COMPLETE' \
	" mode=$SMD401_CONFIG_MODE pid=${pid_before}->${pid_after}" \
	" start=${start_before}->${start_after}" \
	" config_sha256=$expected_conf node=IDLE queue=empty"
