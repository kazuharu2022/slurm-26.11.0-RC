#!/bin/sh

set -u

if [ "${SMD406_IPV6_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD406_IPV6_PREFLIGHT_CONFIRMED=YES after confirming a read-only IPv6 preflight' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
pid_file=/var/run/slurmd.pid
service_target=system/org.schedmd.slurmd
node_name=PC-210
peer_name=ubuntu
controller_name=ubuntu2504
interface=en0
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd406-mac-preflight-${run_stamp}

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
}

node_field()
{
	field=$1
	file=$2
	/usr/bin/awk -v key="${field}=" '
	{
		for (i = 1; i <= NF; i++) {
			if (index($i, key) == 1) {
				sub(key, "", $i)
				print $i
				exit
			}
		}
	}' "$file"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this preflight is for the macOS worker'
for required in "$slurm_conf" "$gres_conf" "$slurmd" "$scontrol" "$squeue" \
	"$plist" "$pid_file"; do
	[ -e "$required" ] || fail "missing $required"
done
for command in /sbin/ifconfig /usr/sbin/netstat /usr/bin/dscacheutil \
	/usr/bin/nc /usr/sbin/lsof /usr/bin/awk /usr/bin/cmp /usr/bin/grep \
	/usr/bin/shasum /bin/launchctl; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/usr/bin/printf 'mode=READ_ONLY_PRODUCTION run_dir=%s interface=%s\n' \
	"$run_dir" "$interface"
/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurmd" "$plist" \
	>"${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
"$scontrol" show config >"${run_dir}/controller-config.txt" || \
	fail 'controller config readback failed'
"$scontrol" show node "$node_name" >"${run_dir}/mac-node.txt" || \
	fail 'Mac node readback failed'
"$scontrol" show node "$peer_name" >"${run_dir}/ubuntu-node.txt" || \
	fail 'Ubuntu node readback failed'
[ "$(node_field State "${run_dir}/mac-node.txt")" = IDLE ] || fail 'PC-210 is not IDLE'
[ "$(node_field State "${run_dir}/ubuntu-node.txt")" = IDLE ] || fail 'ubuntu is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/mac-node.txt")" = 0 ] || fail 'PC-210 CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/mac-node.txt")" = 0 ] || fail 'PC-210 AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name,$peer_name")" ] || fail 'target nodes have active jobs'

pid=$(/bin/cat "$pid_file")
case "$pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$pid" ;;
esac
/bin/kill -0 "$pid" >/dev/null 2>&1 || fail "slurmd pid=$pid is not running"
/bin/launchctl print "$service_target" >"${run_dir}/launchd.txt" 2>&1 || \
	fail "launchd service is not loaded: $service_target"
launchd_pid=$(/usr/bin/awk '/pid =/ { print $3; exit }' "${run_dir}/launchd.txt")
[ "$launchd_pid" = "$pid" ] || \
	fail "launchd and pidfile mismatch launchd=$launchd_pid pidfile=$pid"

/sbin/ifconfig -a >"${run_dir}/ifconfig-all.txt" || fail 'ifconfig failed'
/sbin/ifconfig "$interface" >"${run_dir}/ifconfig-interface.txt" || \
	fail "missing interface=$interface"
/usr/sbin/netstat -rn -f inet6 >"${run_dir}/route-ipv6.txt" 2>&1 || \
	fail 'IPv6 route capture failed'
/usr/bin/dscacheutil -q host -a name "$controller_name" \
	>"${run_dir}/controller-resolution.txt" 2>"${run_dir}/controller-resolution.err" || true
/usr/bin/dscacheutil -q host -a name "${node_name}.local" \
	>"${run_dir}/mac-resolution.txt" 2>"${run_dir}/mac-resolution.err" || true
/usr/sbin/lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN \
	>"${run_dir}/slurmd-listeners.txt" 2>"${run_dir}/slurmd-listeners.err" || true
/bin/cp /etc/hosts "${run_dir}/hosts.txt" || fail 'cannot capture /etc/hosts'

/usr/bin/awk '
	/inet6 / {
		addr = $2
		sub(/%.*/, "", addr)
		if (addr != "::1" && addr !~ /^fe80:/)
			print addr
	}
' "${run_dir}/ifconfig-interface.txt" >"${run_dir}/mac-routable-ipv6.txt"
/usr/bin/awk '
	/^ipv6_address:/ {
		addr = $2
		sub(/%.*/, "", addr)
		if (addr != "::1" && addr !~ /^fe80:/)
			print addr
	}
' "${run_dir}/controller-resolution.txt" >"${run_dir}/controller-routable-ipv6.txt"

mac_routable_count=$(/usr/bin/awk 'NF { count++ } END { print count + 0 }' \
	"${run_dir}/mac-routable-ipv6.txt")
controller_routable_count=$(/usr/bin/awk 'NF { count++ } END { print count + 0 }' \
	"${run_dir}/controller-routable-ipv6.txt")
if /usr/bin/grep -Eq '^CommunicationParameters[[:space:]]*=.*EnableIPv6' \
	"${run_dir}/controller-config.txt"; then
	slurm_ipv6_enabled=YES
else
	slurm_ipv6_enabled=NO
fi

if [ "$controller_routable_count" -gt 0 ]; then
	controller_ipv6=$(/usr/bin/awk 'NF { print; exit }' \
		"${run_dir}/controller-routable-ipv6.txt")
	if /usr/bin/nc -6 -vz -w 3 "$controller_ipv6" 6817 \
		>"${run_dir}/controller-6817-ipv6.out" \
		2>"${run_dir}/controller-6817-ipv6.err"; then
		controller_6817_ipv6=PASS
	else
		controller_6817_ipv6=FAIL
	fi
else
	controller_ipv6=NONE
	controller_6817_ipv6=NOT_TESTED_NO_ADDRESS
fi

if [ "$mac_routable_count" -gt 0 ] && [ "$controller_routable_count" -gt 0 ]; then
	network_prerequisite=ADDRESS_PRESENT_REQUIRES_UBUNTU_CROSSCHECK
else
	network_prerequisite=MISSING_ROUTABLE_IPV6
fi

/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurmd" "$plist" \
	>"${run_dir}/production-after.sha256" || fail 'cannot hash final production inputs'
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed during preflight'
[ "$(/bin/cat "$pid_file")" = "$pid" ] || fail 'slurmd PID changed during preflight'

/usr/bin/printf '%s\n' \
	"mac_routable_ipv6_count=$mac_routable_count" \
	"controller_routable_ipv6_count=$controller_routable_count controller_ipv6=$controller_ipv6" \
	"controller_6817_ipv6=$controller_6817_ipv6" \
	"slurm_enable_ipv6=$slurm_ipv6_enabled" \
	"network_prerequisite=$network_prerequisite" \
	"SMD406_MAC_PREFLIGHT_COMPLETE classification=$network_prerequisite slurmd_pid=$pid production_unchanged=PASS run_dir=$run_dir"
