#!/bin/sh

set -u

slurm_prefix=/opt/slurm/26.11.0
slurm_conf=${slurm_prefix}/etc/slurm.conf
squeue=${slurm_prefix}/bin/squeue
scontrol=${slurm_prefix}/bin/scontrol
pid_file=/var/run/slurmd.pid
controller_name=ubuntu2504
controller_addr=192.168.10.180
controller_port=6817
node_name=PC-210
test_anchor=com.apple/slurm-smd010

export SLURM_CONF="$slurm_conf"

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	printf 'error: run as root with sudo\n' >&2
	exit 77
fi

for required_file in "$slurm_conf" "$squeue" "$scontrol" /sbin/pfctl \
	/sbin/route /usr/bin/nc /etc/pf.conf; do
	if [ ! -e "$required_file" ]; then
		printf 'error: missing %s\n' "$required_file" >&2
		exit 66
	fi
done

printf 'mode=READ_ONLY no_firewall_change=yes\n'
printf 'controller_name=%s controller_addr=%s controller_port=%s\n' \
	"$controller_name" "$controller_addr" "$controller_port"

printf '\n[route]\n'
/sbin/route -n get "$controller_addr" || exit 1

printf '\n[source-address]\n'
route_interface=$(/sbin/route -n get "$controller_addr" |
	/usr/bin/awk '/interface:/ { print $2; exit }')
if [ -z "$route_interface" ]; then
	printf 'error: unable to determine route interface\n' >&2
	exit 1
fi
printf 'route_interface=%s\n' "$route_interface"
/usr/sbin/ipconfig getifaddr "$route_interface" || true

printf '\n[pf-info]\n'
/sbin/pfctl -s info || exit 1

printf '\n[pf-enable-references]\n'
/sbin/pfctl -s References || exit 1

printf '\n[pf-main-anchors]\n'
/sbin/pfctl -s Anchors || exit 1

printf '\n[pf-com-apple-rules-recursive]\n'
/sbin/pfctl -a 'com.apple/*' -sr || exit 1

printf '\n[test-anchor-existing-rules]\n'
/sbin/pfctl -a "$test_anchor" -sr || exit 1

printf '\n[pf-conf-anchor-reference]\n'
/usr/bin/grep -nE '^[[:space:]]*anchor[[:space:]]+"com\.apple/\*"' \
	/etc/pf.conf || exit 1

printf '\n[slurmd]\n'
if [ ! -f "$pid_file" ]; then
	printf 'error: missing %s\n' "$pid_file" >&2
	exit 69
fi
slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*)
	printf 'error: invalid slurmd pid=%s\n' "$slurmd_pid" >&2
	exit 69
	;;
esac
/bin/ps -p "$slurmd_pid" -o user=,pid=,ppid=,lstart=,command= || exit 1

printf '\n[node]\n'
"$scontrol" show node "$node_name" || exit 1

printf '\n[active-jobs]\n'
active_jobs=$("$squeue" -h -w "$node_name" -o '%i %T %u %j') || exit 1
if [ -n "$active_jobs" ]; then
	printf '%s\n' "$active_jobs"
	printf 'error: node has active jobs; do not start SMD-010\n' >&2
	exit 75
fi
printf '(none)\n'

printf '\n[baseline-controller-connectivity]\n'
/usr/bin/nc -vz -G 3 "$controller_addr" "$controller_port" || exit 1

printf '\nSMD010_PREFLIGHT_COMPLETE pf_unchanged=yes interface=%s controller=%s:%s\n' \
	"$route_interface" "$controller_addr" "$controller_port"
