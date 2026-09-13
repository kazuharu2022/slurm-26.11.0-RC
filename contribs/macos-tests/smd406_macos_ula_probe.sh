#!/bin/sh

set -u

if [ "${SMD406_ULA_NETWORK_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD406_ULA_NETWORK_CONFIRMED=YES after approving temporary ULA add/remove' >&2
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
interface=en0
ubuntu_address=fd40:534d:4406:1::180
mac_address=fd40:534d:4406:1::128
prefix_length=64
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd406-mac-ula-probe-${run_stamp}
address_added=0

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

cleanup_on_exit()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$address_added" -eq 1 ]; then
		/sbin/ifconfig "$interface" inet6 "${mac_address}/${prefix_length}" delete \
			>/dev/null 2>&1 || true
		address_added=0
	fi
	if [ "$rc" -ne 0 ]; then
		/usr/bin/printf 'recovery: temporary Mac ULA removal attempted; Slurm config and daemon were not intentionally changed; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

capture_default_routes()
{
	label=$1
	{
		/sbin/route -n get default 2>&1
		/usr/bin/printf 'rc=%s\n' "$?"
	} >"${run_dir}/default-ipv4-${label}.txt"
	{
		/sbin/route -n get -inet6 default 2>&1
		/usr/bin/printf 'rc=%s\n' "$?"
	} >"${run_dir}/default-ipv6-${label}.txt"
}

trap cleanup_on_exit EXIT
trap 'exit 130' HUP INT TERM

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this probe is for the macOS worker'
/bin/mkdir -m 0700 "$run_dir" || fail 'cannot create run directory'
for required in "$slurm_conf" "$gres_conf" "$slurmd" "$scontrol" "$squeue" \
	"$plist" "$pid_file"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_path in /sbin/ifconfig /sbin/route /sbin/ping6 /usr/bin/awk \
	/usr/bin/cmp /usr/bin/grep /usr/bin/shasum /bin/launchctl; do
	[ -x "$command_path" ] || fail "required command is not executable: $command_path"
done
/usr/bin/printf 'mode=TEMPORARY_ULA_PROBE run_dir=%s interface=%s mac_ula=%s/%s ubuntu_ula=%s/%s\n' \
	"$run_dir" "$interface" "$mac_address" "$prefix_length" \
	"$ubuntu_address" "$prefix_length"
/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurmd" "$plist" \
	>"${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'
export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
"$scontrol" show node PC-210 >"${run_dir}/mac-node-before.txt" || \
	fail 'Mac node readback failed'
"$scontrol" show node ubuntu >"${run_dir}/ubuntu-node-before.txt" || \
	fail 'Ubuntu node readback failed'
"$squeue" -h -w PC-210,ubuntu >"${run_dir}/queue-before.txt" || fail 'queue readback failed'
[ "$(node_field State "${run_dir}/mac-node-before.txt")" = IDLE ] || fail 'PC-210 is not IDLE'
[ "$(node_field State "${run_dir}/ubuntu-node-before.txt")" = IDLE ] || fail 'ubuntu is not IDLE'
[ "x$(node_field CPUAlloc "${run_dir}/mac-node-before.txt")" = x0 ] || \
	fail 'PC-210 CPUAlloc is not zero'
[ "x$(node_field AllocMem "${run_dir}/mac-node-before.txt")" = x0 ] || \
	fail 'PC-210 AllocMem is not zero'
[ ! -s "${run_dir}/queue-before.txt" ] || fail 'target nodes have active jobs'

pid=$(/bin/cat "$pid_file")
case "$pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$pid" ;;
esac
/bin/kill -0 "$pid" >/dev/null 2>&1 || fail "slurmd pid=$pid is not running"
/bin/launchctl print "$service_target" >"${run_dir}/launchd-before.txt" 2>&1 || \
	fail "launchd service is not loaded: $service_target"
launchd_pid=$(/usr/bin/awk '/pid =/ { print $3; exit }' "${run_dir}/launchd-before.txt")
[ "$launchd_pid" = "$pid" ] || fail "launchd and pidfile mismatch launchd=$launchd_pid pidfile=$pid"

capture_default_routes before
/sbin/ifconfig "$interface" >"${run_dir}/interface-before.txt" || fail "missing interface=$interface"
if /usr/bin/grep -Fq "inet6 ${mac_address} " "${run_dir}/interface-before.txt"; then
	fail "candidate Mac ULA already exists: $mac_address"
fi

/sbin/ifconfig "$interface" inet6 "${mac_address}/${prefix_length}" alias || \
	fail 'cannot add temporary Mac ULA'
address_added=1

wait_count=0
while :; do
	/sbin/ifconfig "$interface" >"${run_dir}/interface-applied.txt" || \
		fail 'cannot capture applied Mac address'
	address_line=$(/usr/bin/grep -F "inet6 ${mac_address} " \
		"${run_dir}/interface-applied.txt" || true)
	if [ -n "$address_line" ] && \
	    ! /usr/bin/printf '%s\n' "$address_line" | \
		/usr/bin/grep -Eq 'tentative|duplicated'; then
		break
	fi
	[ "$wait_count" -lt 20 ] || fail 'temporary Mac ULA did not complete DAD'
	/bin/sleep 1
	wait_count=$((wait_count + 1))
done

/sbin/route -n get -inet6 "$ubuntu_address" >"${run_dir}/route-to-ubuntu.txt" 2>&1 || \
	fail 'no IPv6 route to Ubuntu ULA'
/usr/bin/grep -Eq "interface:[[:space:]]+${interface}([[:space:]]|$)" \
	"${run_dir}/route-to-ubuntu.txt" || fail 'candidate route does not use en0'
/sbin/ping6 -S "$mac_address" -c 3 "$ubuntu_address" \
	>"${run_dir}/ping6-ubuntu.out" 2>"${run_dir}/ping6-ubuntu.err" || \
	fail 'native IPv6 ping to Ubuntu ULA failed'

/sbin/ifconfig "$interface" inet6 "${mac_address}/${prefix_length}" delete || \
	fail 'cannot remove temporary Mac ULA'
address_added=0
/sbin/ifconfig "$interface" >"${run_dir}/interface-restored.txt" || \
	fail 'cannot capture restored Mac interface'
if /usr/bin/grep -Fq "inet6 ${mac_address} " "${run_dir}/interface-restored.txt"; then
	fail 'temporary Mac ULA remains after cleanup'
fi
capture_default_routes restored
/usr/bin/cmp -s "${run_dir}/default-ipv4-before.txt" \
	"${run_dir}/default-ipv4-restored.txt" || fail 'IPv4 default route changed'
/usr/bin/cmp -s "${run_dir}/default-ipv6-before.txt" \
	"${run_dir}/default-ipv6-restored.txt" || fail 'IPv6 default route changed'
/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurmd" "$plist" \
	>"${run_dir}/production-restored.sha256" || fail 'cannot rehash production inputs'
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-restored.sha256" || fail 'production input changed'
[ "$(/bin/cat "$pid_file")" = "$pid" ] || fail 'slurmd PID changed'
/bin/launchctl print "$service_target" >"${run_dir}/launchd-restored.txt" 2>&1 || \
	fail 'launchd service unavailable after cleanup'
restored_pid=$(/usr/bin/awk '/pid =/ { print $3; exit }' "${run_dir}/launchd-restored.txt")
[ "$restored_pid" = "$pid" ] || fail 'launchd PID changed'
"$scontrol" ping >"${run_dir}/controller-restored.txt" 2>&1 || fail 'controller ping failed after cleanup'
"$scontrol" show node PC-210 >"${run_dir}/mac-node-restored.txt" || \
	fail 'Mac node readback failed after cleanup'
[ "$(node_field State "${run_dir}/mac-node-restored.txt")" = IDLE ] || \
	fail 'PC-210 is not IDLE after cleanup'

/usr/bin/printf 'SMD406_MAC_ULA_PROBE_COMPLETE source=%s destination=%s packets=3 native_ipv6=PASS mac_address_removed=PASS slurmd_pid=%s production_unchanged=PASS run_dir=%s\n' \
	"$mac_address" "$ubuntu_address" "$pid" "$run_dir"
/usr/bin/printf '%s\n' \
	'NEXT_ON_UBUNTU: run smd406_ubuntu_ula_control.sh restore'
