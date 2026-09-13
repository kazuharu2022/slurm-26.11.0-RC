#!/bin/sh

set -u

mode=${1:-}
if [ "$mode" != apply ] && [ "$mode" != restore ]; then
	printf 'usage: %s apply|restore\n' "$0" >&2
	exit 64
fi
if [ "${SMD406_ULA_NETWORK_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD406_ULA_NETWORK_CONFIRMED=YES after approving temporary ULA add/remove' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmdbd_conf=${prefix}/etc/slurmdbd.conf
gres_conf=${prefix}/etc/gres.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
interface=br0
ubuntu_address=fd40:534d:4406:1::180
mac_address=fd40:534d:4406:1::128
prefix_length=64
state_file=/run/smd406-ubuntu-ula.env
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd406-ubuntu-ula-${mode}-${run_stamp}
address_added=0

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

cleanup_on_exit()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$rc" -ne 0 ] && [ "$address_added" -eq 1 ]; then
		ip -6 addr del "${ubuntu_address}/${prefix_length}" dev "$interface" \
			>/dev/null 2>&1 || true
		printf 'recovery: removed temporary Ubuntu ULA=%s/%s interface=%s\n' \
			"$ubuntu_address" "$prefix_length" "$interface" >&2
	fi
	if [ "$rc" -ne 0 ]; then
		printf 'recovery: Slurm config and daemons were not intentionally changed; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

capture_default_routes()
{
	label=$1
	ip -4 route show default >"${run_dir}/default-ipv4-${label}.txt" || return 1
	ip -6 route show default >"${run_dir}/default-ipv6-${label}.txt" || return 1
	sed -E 's/[[:space:]]+expires[[:space:]]+[0-9]+sec//g' \
		"${run_dir}/default-ipv4-${label}.txt" \
		>"${run_dir}/default-ipv4-${label}.semantic.txt" || return 1
	sed -E 's/[[:space:]]+expires[[:space:]]+[0-9]+sec//g' \
		"${run_dir}/default-ipv6-${label}.txt" \
		>"${run_dir}/default-ipv6-${label}.semantic.txt" || return 1
}

capture_slurm_state()
{
	label=$1
	"$scontrol" ping >"${run_dir}/controller-${label}.txt" 2>&1 || return 1
	"$scontrol" show node ubuntu >"${run_dir}/ubuntu-node-${label}.txt" || return 1
	"$scontrol" show node PC-210 >"${run_dir}/mac-node-${label}.txt" || return 1
	"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-${label}.txt" || return 1
}

trap cleanup_on_exit EXIT
trap 'exit 130' HUP INT TERM

[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Linux ] || fail 'this control script is for Ubuntu'
for required in "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
	"$scontrol" "$squeue"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_name in ip ping sha256sum systemctl awk cmp grep sed stat chmod mv rm cp; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done
ip link show dev "$interface" >/dev/null 2>&1 || fail "missing interface=$interface"
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done

umask 077
mkdir "$run_dir" || fail 'cannot create run directory'
printf 'mode=%s run_dir=%s interface=%s ubuntu_ula=%s/%s mac_ula=%s/%s\n' \
	"$mode" "$run_dir" "$interface" "$ubuntu_address" "$prefix_length" \
	"$mac_address" "$prefix_length"
export SLURM_CONF="$slurm_conf"

case "$mode" in
apply)
	[ ! -e "$state_file" ] || fail "active state already exists: $state_file"
	[ ! -L "$state_file" ] || fail "state path is a symbolic link: $state_file"
	sha256sum "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
		>"${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'
	systemctl show slurmctld slurmdbd slurmd \
		-p Id -p MainPID -p ActiveEnterTimestamp \
		>"${run_dir}/services-before.txt" || fail 'cannot capture service identities'
	capture_slurm_state before || fail 'cannot capture initial Slurm state'
	[ "$(node_field State "${run_dir}/ubuntu-node-before.txt")" = IDLE ] || \
		fail 'ubuntu is not IDLE'
	[ "$(node_field State "${run_dir}/mac-node-before.txt")" = IDLE ] || \
		fail 'PC-210 is not IDLE'
	[ "x$(node_field CPUAlloc "${run_dir}/ubuntu-node-before.txt")" = x0 ] || \
		fail 'ubuntu CPUAlloc is not zero'
	[ "x$(node_field AllocMem "${run_dir}/ubuntu-node-before.txt")" = x0 ] || \
		fail 'ubuntu AllocMem is not zero'
	[ ! -s "${run_dir}/queue-before.txt" ] || fail 'target nodes have active jobs'
	capture_default_routes before || fail 'cannot capture initial default routes'
	ip -6 addr show dev "$interface" >"${run_dir}/addresses-before.txt" || \
		fail 'cannot capture initial IPv6 addresses'
	if grep -Fq "${ubuntu_address}/${prefix_length}" "${run_dir}/addresses-before.txt"; then
		fail "candidate Ubuntu ULA already exists: $ubuntu_address"
	fi

	ip -6 addr add "${ubuntu_address}/${prefix_length}" dev "$interface" || \
		fail 'cannot add temporary Ubuntu ULA'
	address_added=1

	wait_count=0
	while :; do
		ip -6 -o addr show dev "$interface" >"${run_dir}/addresses-applied.txt" || \
			fail 'cannot capture applied IPv6 address'
		address_line=$(grep -F " ${ubuntu_address}/${prefix_length} " \
			"${run_dir}/addresses-applied.txt" || true)
		if [ -n "$address_line" ] && \
		    ! printf '%s\n' "$address_line" | grep -Eq 'tentative|dadfailed'; then
			break
		fi
		[ "$wait_count" -lt 20 ] || fail 'temporary Ubuntu ULA did not complete DAD'
		sleep 1
		wait_count=$((wait_count + 1))
	done
	ip -6 route get "$mac_address" >"${run_dir}/route-to-mac.txt" 2>&1 || \
		fail 'no IPv6 route to candidate Mac ULA'
	grep -Eq "dev[[:space:]]+${interface}([[:space:]]|$)" \
		"${run_dir}/route-to-mac.txt" || fail 'candidate route does not use br0'
	grep -Eq "src[[:space:]]+${ubuntu_address}([[:space:]]|$)" \
		"${run_dir}/route-to-mac.txt" || fail 'candidate route source is not Ubuntu ULA'
	if ping -6 -c 1 -W 1 "$mac_address" \
		>"${run_dir}/preexisting-peer-ping.out" \
		2>"${run_dir}/preexisting-peer-ping.err"; then
		fail "candidate Mac ULA is already responding: $mac_address"
	fi

	capture_default_routes applied || fail 'cannot recapture default routes'
	cmp -s "${run_dir}/default-ipv4-before.semantic.txt" \
		"${run_dir}/default-ipv4-applied.semantic.txt" || fail 'IPv4 default route changed'
	cmp -s "${run_dir}/default-ipv6-before.semantic.txt" \
		"${run_dir}/default-ipv6-applied.semantic.txt" || fail 'IPv6 default route changed'
	sha256sum "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
		>"${run_dir}/production-applied.sha256" || fail 'cannot rehash production inputs'
	cmp -s "${run_dir}/production-before.sha256" \
		"${run_dir}/production-applied.sha256" || fail 'production input changed'
	systemctl show slurmctld slurmdbd slurmd \
		-p Id -p MainPID -p ActiveEnterTimestamp \
		>"${run_dir}/services-applied.txt" || fail 'cannot recapture service identities'
	cmp -s "${run_dir}/services-before.txt" "${run_dir}/services-applied.txt" || \
		fail 'service identity changed'

	{
		printf 'run_dir=%s\n' "$run_dir"
		printf 'interface=%s\n' "$interface"
		printf 'ubuntu_address=%s\n' "$ubuntu_address"
		printf 'mac_address=%s\n' "$mac_address"
		printf 'prefix_length=%s\n' "$prefix_length"
	} >"${run_dir}/state.tmp" || fail 'cannot write temporary state'
	chmod 0600 "${run_dir}/state.tmp" || fail 'cannot protect temporary state'
	mv -T "${run_dir}/state.tmp" "$state_file" || fail 'cannot install temporary state'
	address_added=0
	printf 'SMD406_UBUNTU_ULA_APPLY_COMPLETE address=%s/%s interface=%s state=%s production_unchanged=PASS run_dir=%s\n' \
		"$ubuntu_address" "$prefix_length" "$interface" "$state_file" "$run_dir"
	printf '%s\n' \
		'NEXT_ON_MAC: run smd406_macos_ula_probe.sh, then run this script with restore on Ubuntu'
	;;
restore)
	[ -f "$state_file" ] || fail "missing active state: $state_file"
	[ ! -L "$state_file" ] || fail "state is a symbolic link: $state_file"
	[ "$(stat -c '%u:%a' "$state_file")" = 0:600 ] || \
		fail 'state owner/mode is not root:600'
	cp "$state_file" "${run_dir}/state-before-restore.txt" || fail 'cannot preserve state'
	grep -Fxq "interface=$interface" "$state_file" || fail 'state interface mismatch'
	grep -Fxq "ubuntu_address=$ubuntu_address" "$state_file" || fail 'state Ubuntu address mismatch'
	grep -Fxq "mac_address=$mac_address" "$state_file" || fail 'state Mac address mismatch'
	grep -Fxq "prefix_length=$prefix_length" "$state_file" || fail 'state prefix mismatch'
	state_run_dir=$(awk -F= '$1 == "run_dir" { print substr($0, index($0, "=") + 1); exit }' \
		"$state_file")
	[ -n "$state_run_dir" ] || fail 'state lacks run_dir'
	case "$state_run_dir" in
	/tmp/slurm-smd406-ubuntu-ula-apply-*) ;;
	*) fail "unexpected apply run_dir=$state_run_dir" ;;
	esac
	[ -d "$state_run_dir" ] || fail "missing apply evidence=$state_run_dir"
	ip -6 -o addr show dev "$interface" >"${run_dir}/addresses-before-restore.txt" || \
		fail 'cannot capture address before restore'
	grep -Fq " ${ubuntu_address}/${prefix_length} " \
		"${run_dir}/addresses-before-restore.txt" || fail 'temporary Ubuntu ULA is not present'

	ip -6 addr del "${ubuntu_address}/${prefix_length}" dev "$interface" || \
		fail 'cannot remove temporary Ubuntu ULA'
	ip -6 -o addr show dev "$interface" >"${run_dir}/addresses-restored.txt" || \
		fail 'cannot capture restored addresses'
	if grep -Fq " ${ubuntu_address}/${prefix_length} " \
		"${run_dir}/addresses-restored.txt"; then
		fail 'temporary Ubuntu ULA remains after restore'
	fi
	rm -f "$state_file"
	capture_default_routes restored || fail 'cannot capture restored default routes'
	cmp -s "${state_run_dir}/default-ipv4-before.semantic.txt" \
		"${run_dir}/default-ipv4-restored.semantic.txt" || fail 'IPv4 default route not restored'
	cmp -s "${state_run_dir}/default-ipv6-before.semantic.txt" \
		"${run_dir}/default-ipv6-restored.semantic.txt" || fail 'IPv6 default route not restored'
	sha256sum "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
		>"${run_dir}/production-restored.sha256" || fail 'cannot hash restored production inputs'
	cmp -s "${state_run_dir}/production-before.sha256" \
		"${run_dir}/production-restored.sha256" || fail 'production input changed'
	systemctl show slurmctld slurmdbd slurmd \
		-p Id -p MainPID -p ActiveEnterTimestamp \
		>"${run_dir}/services-restored.txt" || fail 'cannot recapture service identities'
	cmp -s "${state_run_dir}/services-before.txt" \
		"${run_dir}/services-restored.txt" || fail 'service identity changed'
	capture_slurm_state restored || fail 'cannot capture restored Slurm state'
	[ "$(node_field State "${run_dir}/ubuntu-node-restored.txt")" = IDLE ] || \
		fail 'ubuntu is not IDLE after restore'
	[ "$(node_field State "${run_dir}/mac-node-restored.txt")" = IDLE ] || \
		fail 'PC-210 is not IDLE after restore'
	[ ! -s "${run_dir}/queue-restored.txt" ] || fail 'target nodes have jobs after restore'
	printf 'SMD406_UBUNTU_ULA_RESTORE_COMPLETE removed=%s/%s interface=%s production_unchanged=PASS services_unchanged=PASS run_dir=%s apply_run_dir=%s\n' \
		"$ubuntu_address" "$prefix_length" "$interface" "$run_dir" "$state_run_dir"
	;;
esac
