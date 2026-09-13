#!/bin/sh

set -u

mode=${1:-}
if [ "$mode" != apply ] && [ "$mode" != restore ]; then
	printf 'usage: %s apply|restore\n' "$0" >&2
	exit 64
fi
if [ "${SMD406_IPV6_RUNTIME_CHANGE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD406_IPV6_RUNTIME_CHANGE_CONFIRMED=YES after approving the temporary IPv6 runtime change' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmdbd_conf=${prefix}/etc/slurmdbd.conf
gres_conf=${prefix}/etc/gres.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sacctmgr=${prefix}/bin/sacctmgr
interface=br0
ubuntu_address=fd40:534d:4406:1::180
mac_address=fd40:534d:4406:1::128
prefix_length=64
state_file=${prefix}/.smd406-ipv6-runtime.env
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd406-ubuntu-runtime-${mode}-${run_stamp}
success=0
address_added=0
slurm_conf_installed=0
slurmdbd_conf_installed=0

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

atomic_install()
{
	source_file=$1
	target_file=$2
	reference_file=$3
	tmp_file=${target_file}.smd406.$$
	uid=$(stat -c '%u' "$reference_file") || return 1
	gid=$(stat -c '%g' "$reference_file") || return 1
	file_mode=$(stat -c '%a' "$reference_file") || return 1
	if ! install -o "$uid" -g "$gid" -m "$file_mode" "$source_file" "$tmp_file"; then
		rm -f "$tmp_file"
		return 1
	fi
	if ! mv -f "$tmp_file" "$target_file"; then
		rm -f "$tmp_file"
		return 1
	fi
}

build_slurm_candidate()
{
	source_file=$1
	target_file=$2
	awk -v controller="$ubuntu_address" -v worker="$mac_address" '
	function set_field(line, key, value, count, field, i, found, output) {
		count = split(line, field, /[[:space:]]+/)
		found = 0
		output = ""
		for (i = 1; i <= count; i++) {
			if (field[i] == "") continue
			if (index(field[i], key "=") == 1) {
				field[i] = key "=" value
				found = 1
			}
			output = output (output == "" ? "" : " ") field[i]
		}
		if (!found) output = output " " key "=" value
		return output
	}
	/^[[:space:]]*CommunicationParameters=/ {
		if ($0 !~ /EnableIPv6/) $0 = $0 ",EnableIPv6"
		seen_communication = 1
		print
		next
	}
	/^[[:space:]]*SlurmctldHost=/ {
		print "SlurmctldHost=ubuntu2504(" controller ")"
		next
	}
	/^[[:space:]]*AccountingStorageHost=/ {
		print "AccountingStorageHost=" controller
		next
	}
	/^[[:space:]]*NodeName=PC-210([[:space:]]|$)/ {
		print set_field($0, "NodeAddr", worker)
		next
	}
	/^[[:space:]]*NodeName=ubuntu([[:space:]]|$)/ {
		line = set_field($0, "NodeAddr", controller)
		print set_field(line, "NodeHostName", "ubuntu2504")
		next
	}
	{ print }
	END { if (!seen_communication) print "CommunicationParameters=EnableIPv6" }
	' "$source_file" >"$target_file"
}

build_dbd_candidate()
{
	source_file=$1
	target_file=$2
	awk -v controller="$ubuntu_address" '
	/^[[:space:]]*CommunicationParameters=/ {
		if ($0 !~ /EnableIPv6/) $0 = $0 ",EnableIPv6"
		seen_communication = 1
		print
		next
	}
	/^[[:space:]]*DbdAddr=/ {
		print "DbdAddr=" controller
		seen_dbd_addr = 1
		next
	}
	{ print }
	END {
		if (!seen_communication) print "CommunicationParameters=EnableIPv6"
		if (!seen_dbd_addr) print "DbdAddr=" controller
	}
	' "$source_file" >"$target_file"
}

restart_stack()
{
	label=$1
	systemctl restart slurmdbd >"${run_dir}/${label}-slurmdbd.out" \
		2>"${run_dir}/${label}-slurmdbd.err" || return 1
	systemctl restart slurmctld >"${run_dir}/${label}-slurmctld.out" \
		2>"${run_dir}/${label}-slurmctld.err" || return 1
	systemctl restart slurmd >"${run_dir}/${label}-slurmd.out" \
		2>"${run_dir}/${label}-slurmd.err" || return 1
	for service in slurmdbd slurmctld slurmd; do
		[ "$(systemctl is-active "$service")" = active ] || return 1
	done
	return 0
}

wait_control_plane()
{
	label=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$scontrol" ping >"${run_dir}/${label}-controller-ping.txt" 2>&1 &&
		"$sacctmgr" ping >"${run_dir}/${label}-dbd-ping.txt" 2>&1 && return 0
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_node_idle()
{
	label=$1
	node=$2
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$scontrol" show node "$node" >"${run_dir}/${label}-${node}.txt" 2>/dev/null || true
		state=$(node_field State "${run_dir}/${label}-${node}.txt")
		if [ "$state" = IDLE ]; then
			printf 'node_idle phase=%s node=%s wait_seconds=%s\n' \
				"$label" "$node" "$attempt"
			return 0
		fi
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

write_state()
{
	apply_run_dir=$1
	tmp_file=${state_file}.tmp.$$
	{
		printf 'apply_run_dir=%s\n' "$apply_run_dir"
		printf 'interface=%s\n' "$interface"
		printf 'ubuntu_address=%s\n' "$ubuntu_address"
		printf 'mac_address=%s\n' "$mac_address"
		printf 'prefix_length=%s\n' "$prefix_length"
		printf 'phase=APPLIED_AWAITING_MAC_RUNTIME\n'
	} >"$tmp_file" || return 1
	chmod 0600 "$tmp_file" || return 1
	mv -f "$tmp_file" "$state_file" || return 1
}

rollback_apply()
{
	printf 'rollback_begin run_dir=%s\n' "$run_dir" >&2
	if [ "$slurm_conf_installed" -eq 1 ]; then
		[ ! -f "${run_dir}/slurm.conf.before" ] || \
			atomic_install "${run_dir}/slurm.conf.before" "$slurm_conf" \
				"${run_dir}/slurm.conf.before" || true
	fi
	if [ "$slurmdbd_conf_installed" -eq 1 ]; then
		[ ! -f "${run_dir}/slurmdbd.conf.before" ] || \
			atomic_install "${run_dir}/slurmdbd.conf.before" "$slurmdbd_conf" \
				"${run_dir}/slurmdbd.conf.before" || true
	fi
	if [ "$slurm_conf_installed" -eq 1 ] || [ "$slurmdbd_conf_installed" -eq 1 ]; then
		restart_stack rollback >/dev/null 2>&1 || true
	fi
	if [ "$address_added" -eq 1 ]; then
		ip -6 addr del "${ubuntu_address}/${prefix_length}" dev "$interface" \
			>/dev/null 2>&1 || true
	fi
	rm -f "$state_file"
	printf 'rollback_end\n' >&2
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$mode" = apply ]; then
		rollback_apply
		printf 'recovery: original Ubuntu config/service/network restore attempted; inspect run_dir=%s\n' \
			"$run_dir" >&2
	elif [ "$success" -ne 1 ]; then
		printf 'recovery: restore did not complete; preserve state=%s and inspect run_dir=%s\n' \
			"$state_file" "$run_dir" >&2
	fi
	exit "$rc"
}

trap cleanup EXIT HUP INT TERM

[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Linux ] || fail 'this control script is for Ubuntu'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
for required in "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
	"$scontrol" "$squeue" "$sacctmgr"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_name in ip ss systemctl sha256sum awk grep stat install mv cp chmod cmp rm sleep; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done
ip link show dev "$interface" >/dev/null 2>&1 || fail "missing interface=$interface"
umask 077
mkdir "$run_dir" || fail 'cannot create run directory'
printf 'mode=%s run_dir=%s ubuntu_ula=%s/%s mac_ula=%s/%s\n' \
	"$mode" "$run_dir" "$ubuntu_address" "$prefix_length" "$mac_address" "$prefix_length"
export SLURM_CONF="$slurm_conf"

case "$mode" in
apply)
	[ ! -e "$state_file" ] || fail "active state already exists: $state_file"
	for service in slurmdbd slurmctld slurmd; do
		[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
	done
	"$scontrol" show node ubuntu >"${run_dir}/before-ubuntu.txt" || fail 'cannot read Ubuntu node'
	"$scontrol" show node PC-210 >"${run_dir}/before-mac.txt" || fail 'cannot read Mac node'
	"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/before-queue.txt" || fail 'cannot read queue'
	[ "$(node_field State "${run_dir}/before-ubuntu.txt")" = IDLE ] || fail 'ubuntu is not IDLE'
	[ "$(node_field State "${run_dir}/before-mac.txt")" = IDLE ] || fail 'PC-210 is not IDLE'
	[ ! -s "${run_dir}/before-queue.txt" ] || fail 'target nodes have active jobs'
	if ip -6 -o addr show dev "$interface" | grep -Fq " ${ubuntu_address}/${prefix_length} "; then
		fail 'temporary Ubuntu ULA already exists'
	fi
	cp -p "$slurm_conf" "${run_dir}/slurm.conf.before" || fail 'cannot back up slurm.conf'
	cp -p "$slurmdbd_conf" "${run_dir}/slurmdbd.conf.before" || fail 'cannot back up slurmdbd.conf'
	sha256sum "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
		>"${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'
	build_slurm_candidate "$slurm_conf" "${run_dir}/slurm.conf.ipv6" || \
		fail 'cannot build IPv6 slurm.conf'
	build_dbd_candidate "$slurmdbd_conf" "${run_dir}/slurmdbd.conf.ipv6" || \
		fail 'cannot build IPv6 slurmdbd.conf'
	cp -p "$gres_conf" "${run_dir}/gres.conf" || fail 'cannot stage gres.conf'
	chmod 0600 "${run_dir}/slurmdbd.conf.ipv6" || fail 'cannot protect candidate slurmdbd.conf'
	"$slurmd" -C -N ubuntu -f "${run_dir}/slurm.conf.ipv6" \
		>"${run_dir}/candidate-C.out" 2>"${run_dir}/candidate-C.err" || \
		fail 'candidate slurm.conf parse failed'
	grep -Eq '^CommunicationParameters=.*EnableIPv6' "${run_dir}/slurm.conf.ipv6" || \
		fail 'candidate slurm.conf lacks EnableIPv6'
	grep -Eq '^CommunicationParameters=.*EnableIPv6' "${run_dir}/slurmdbd.conf.ipv6" || \
		fail 'candidate slurmdbd.conf lacks EnableIPv6'
	grep -Fqx "DbdAddr=${ubuntu_address}" "${run_dir}/slurmdbd.conf.ipv6" || \
		fail 'candidate slurmdbd.conf DbdAddr mismatch'

	ip -6 addr add "${ubuntu_address}/${prefix_length}" dev "$interface" || \
		fail 'cannot add temporary Ubuntu ULA'
	address_added=1
	sleep 2
	ip -6 -o addr show dev "$interface" >"${run_dir}/address-applied.txt" || \
		fail 'cannot capture applied ULA'
	grep -Fq " ${ubuntu_address}/${prefix_length} " "${run_dir}/address-applied.txt" || \
		fail 'temporary Ubuntu ULA not present'
	atomic_install "${run_dir}/slurmdbd.conf.ipv6" "$slurmdbd_conf" "$slurmdbd_conf" || \
		fail 'cannot install IPv6 slurmdbd.conf'
	slurmdbd_conf_installed=1
	atomic_install "${run_dir}/slurm.conf.ipv6" "$slurm_conf" "$slurm_conf" || \
		fail 'cannot install IPv6 slurm.conf'
	slurm_conf_installed=1
	restart_stack ipv6 || fail 'cannot restart Ubuntu Slurm stack with IPv6 config'
	wait_control_plane ipv6 || fail 'IPv6 control plane did not become ready'
	wait_node_idle ipv6 ubuntu || fail 'Ubuntu worker did not become IDLE'
	ss -6 -ltnp >"${run_dir}/listeners-ipv6.txt" || fail 'cannot capture IPv6 listeners'
	for port in 6817 6818 6819; do
		grep -Eq ":${port}([[:space:]]|$)" "${run_dir}/listeners-ipv6.txt" || \
			fail "missing IPv6 listener port=$port"
	done
	"$scontrol" show config >"${run_dir}/controller-config-ipv6.txt" || \
		fail 'cannot read IPv6 controller config'
	grep -Eq '^CommunicationParameters[[:space:]]*=.*EnableIPv6' \
		"${run_dir}/controller-config-ipv6.txt" || fail 'effective config lacks EnableIPv6'
	write_state "$run_dir" || fail 'cannot write active runtime state'
	address_added=0
	slurm_conf_installed=0
	slurmdbd_conf_installed=0
	success=1
	printf 'SMD406_UBUNTU_IPV6_APPLY_COMPLETE controller=%s worker=%s listeners=6817,6818,6819 ubuntu_state=IDLE state=%s run_dir=%s\n' \
		"$ubuntu_address" "$mac_address" "$state_file" "$run_dir"
	printf '%s\n' \
		'NEXT_ON_MAC: run smd406_macos_ipv6_runtime_driver.sh run; do not restore Ubuntu first'
	;;
restore)
	if [ "${SMD406_MAC_RUNTIME_COMPLETE:-}" != YES ] && \
		[ "${SMD406_MAC_LOCAL_RECOVERY_READY:-}" != YES ]; then
		fail 'set SMD406_MAC_RUNTIME_COMPLETE=YES after PASS, or SMD406_MAC_LOCAL_RECOVERY_READY=YES after verified Mac local-config recovery'
	fi
	[ -f "$state_file" ] || fail "missing active state=$state_file"
	[ "$(stat -c '%U:%G:%a' "$state_file")" = root:root:600 ] || fail 'state owner/mode mismatch'
	. "$state_file"
	case "${apply_run_dir:-}" in
	/tmp/slurm-smd406-ubuntu-runtime-apply-*) ;;
	*) fail "invalid apply_run_dir=${apply_run_dir:-}" ;;
	esac
	[ -f "${apply_run_dir}/slurm.conf.before" ] || fail 'missing original slurm.conf backup'
	[ -f "${apply_run_dir}/slurmdbd.conf.before" ] || fail 'missing original slurmdbd.conf backup'
	cp "$state_file" "${run_dir}/state-before-restore.txt" || fail 'cannot preserve state evidence'
	atomic_install "${apply_run_dir}/slurmdbd.conf.before" "$slurmdbd_conf" \
		"${apply_run_dir}/slurmdbd.conf.before" || fail 'cannot restore slurmdbd.conf'
	atomic_install "${apply_run_dir}/slurm.conf.before" "$slurm_conf" \
		"${apply_run_dir}/slurm.conf.before" || fail 'cannot restore slurm.conf'
	restart_stack restore || fail 'cannot restart Ubuntu Slurm stack with original config'
	wait_control_plane restored || fail 'restored control plane did not become ready'
	wait_node_idle restored ubuntu || fail 'Ubuntu did not become IDLE after restore'
	wait_node_idle restored PC-210 || fail 'Mac did not become IDLE after controller restore'
	if ip -6 -o addr show dev "$interface" | grep -Fq " ${ubuntu_address}/${prefix_length} "; then
		ip -6 addr del "${ubuntu_address}/${prefix_length}" dev "$interface" || \
			fail 'cannot remove temporary Ubuntu ULA'
	fi
	if ip -6 -o addr show dev "$interface" | grep -Fq " ${ubuntu_address}/${prefix_length} "; then
		fail 'temporary Ubuntu ULA remains after restore'
	fi
	sha256sum "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
		>"${run_dir}/production-restored.sha256" || fail 'cannot hash restored production'
	cmp -s "${apply_run_dir}/production-before.sha256" \
		"${run_dir}/production-restored.sha256" || fail 'production hashes were not restored'
	"$scontrol" show node PC-210 >"${run_dir}/restored-mac.txt" || true
	[ "$(node_field State "${run_dir}/restored-mac.txt")" = IDLE ] || \
		fail 'Mac did not remain IDLE after Ubuntu ULA removal'
	"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/restored-queue.txt" || \
		fail 'cannot read restored queue'
	[ ! -s "${run_dir}/restored-queue.txt" ] || fail 'target queue is not empty after restore'
	rm -f "$state_file"
	success=1
	printf 'SMD406_UBUNTU_IPV6_RESTORE_COMPLETE controller_config=IPv4_ORIGINAL ubuntu_ula=REMOVED services=ACTIVE production_restored=PASS run_dir=%s apply_run_dir=%s\n' \
		"$run_dir" "$apply_run_dir"
	printf '%s\n' \
		'NEXT_ON_MAC: run smd406_macos_ipv6_runtime_driver.sh finalize to remove the Mac ULA'
	;;
esac
