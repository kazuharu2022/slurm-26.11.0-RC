#!/bin/sh

set -u

if [ "${SMD406_IPV6_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD406_IPV6_PREFLIGHT_CONFIRMED=YES after confirming a read-only IPv6 preflight' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmdbd_conf=${prefix}/etc/slurmdbd.conf
gres_conf=${prefix}/etc/gres.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
node_name=ubuntu
peer_name=PC-210
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd406-ubuntu-preflight-${run_stamp}

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

node_field()
{
	field=$1
	file=$2
	awk -v key="${field}=" '
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

[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Linux ] || fail 'this preflight is for Ubuntu'
for required in "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
	"$scontrol" "$squeue"; do
	[ -e "$required" ] || fail "missing $required"
done
for command in ip getent ss nc sysctl sha256sum systemctl awk cmp grep sort; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command=$command"
done
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done

mkdir -m 0700 "$run_dir" || fail 'cannot create run directory'
printf 'mode=READ_ONLY_PRODUCTION run_dir=%s\n' "$run_dir"
sha256sum "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
	>"${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'
systemctl show slurmctld slurmdbd slurmd -p Id -p MainPID -p ActiveEnterTimestamp \
	>"${run_dir}/services-before.txt" || fail 'cannot capture service identities'

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
"$scontrol" show config >"${run_dir}/controller-config.txt" || \
	fail 'controller config readback failed'
"$scontrol" show node "$node_name" >"${run_dir}/ubuntu-node.txt" || \
	fail 'Ubuntu node readback failed'
"$scontrol" show node "$peer_name" >"${run_dir}/mac-node.txt" || \
	fail 'Mac node readback failed'
[ "$(node_field State "${run_dir}/ubuntu-node.txt")" = IDLE ] || fail 'ubuntu is not IDLE'
[ "$(node_field State "${run_dir}/mac-node.txt")" = IDLE ] || fail 'PC-210 is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/ubuntu-node.txt")" = 0 ] || fail 'ubuntu CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/ubuntu-node.txt")" = 0 ] || fail 'ubuntu AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name,$peer_name")" ] || fail 'target nodes have active jobs'

ip -br -6 addr >"${run_dir}/ip-addresses.txt" || fail 'cannot capture IPv6 addresses'
ip -6 -o addr show scope global >"${run_dir}/routable-ipv6.txt" || \
	fail 'cannot capture routable IPv6 addresses'
ip -6 route show table all >"${run_dir}/route-ipv6.txt" || fail 'cannot capture IPv6 routes'
getent ahostsv6 "$peer_name" >"${run_dir}/mac-resolution.txt" 2>&1 || true
getent ahostsv6 "$(hostname -s)" >"${run_dir}/controller-resolution.txt" 2>&1 || true
ss -ltnp >"${run_dir}/listeners.txt" || fail 'cannot capture TCP listeners'
grep -E ':(6817|6818|6819)[[:space:]]' "${run_dir}/listeners.txt" \
	>"${run_dir}/slurm-listeners.txt" || true
sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 \
	>"${run_dir}/ipv6-sysctl.txt" || fail 'cannot read IPv6 sysctl state'

ubuntu_routable_count=$(awk 'NF { count++ } END { print count + 0 }' \
	"${run_dir}/routable-ipv6.txt")
awk '$1 ~ /:/ && $1 !~ /^fe80:/ && $1 !~ /^::ffff:/ && $1 != "::1" { print $1 }' \
	"${run_dir}/mac-resolution.txt" | sort -u >"${run_dir}/mac-routable-ipv6.txt"
mac_routable_count=$(awk 'NF { count++ } END { print count + 0 }' \
	"${run_dir}/mac-routable-ipv6.txt")

if grep -Eq '^CommunicationParameters[[:space:]]*=.*EnableIPv6' \
	"${run_dir}/controller-config.txt"; then
	slurm_ipv6_enabled=YES
else
	slurm_ipv6_enabled=NO
fi
if grep -Eq '^[[:space:]]*CommunicationParameters[[:space:]]*=.*EnableIPv6' \
	"$slurmdbd_conf"; then
	slurmdbd_ipv6_enabled=YES
else
	slurmdbd_ipv6_enabled=NO
fi

if [ "$mac_routable_count" -gt 0 ]; then
	mac_ipv6=$(awk 'NF { print; exit }' "${run_dir}/mac-routable-ipv6.txt")
	if nc -6 -vz -w 3 "$mac_ipv6" 6818 \
		>"${run_dir}/mac-6818-ipv6.out" 2>"${run_dir}/mac-6818-ipv6.err"; then
		mac_6818_ipv6=PASS
	else
		mac_6818_ipv6=FAIL
	fi
else
	mac_ipv6=NONE
	mac_6818_ipv6=NOT_TESTED_NO_ADDRESS
fi

if [ "$ubuntu_routable_count" -gt 0 ] && [ "$mac_routable_count" -gt 0 ]; then
	network_prerequisite=ADDRESS_PRESENT_REQUIRES_MAC_CROSSCHECK
else
	network_prerequisite=MISSING_ROUTABLE_IPV6
fi

sha256sum "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
	>"${run_dir}/production-after.sha256" || fail 'cannot hash final production inputs'
cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed during preflight'
systemctl show slurmctld slurmdbd slurmd -p Id -p MainPID -p ActiveEnterTimestamp \
	>"${run_dir}/services-after.txt" || fail 'cannot recapture service identities'
cmp -s "${run_dir}/services-before.txt" "${run_dir}/services-after.txt" || \
	fail 'service identity changed during preflight'

printf '%s\n' \
	"ubuntu_routable_ipv6_count=$ubuntu_routable_count" \
	"mac_routable_ipv6_count=$mac_routable_count mac_ipv6=$mac_ipv6" \
	"mac_6818_ipv6=$mac_6818_ipv6" \
	"slurm_enable_ipv6=$slurm_ipv6_enabled slurmdbd_enable_ipv6=$slurmdbd_ipv6_enabled" \
	"network_prerequisite=$network_prerequisite" \
	"SMD406_UBUNTU_PREFLIGHT_COMPLETE classification=$network_prerequisite production_unchanged=PASS run_dir=$run_dir"
