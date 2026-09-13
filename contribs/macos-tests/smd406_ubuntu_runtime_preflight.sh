#!/bin/sh

set -u

if [ "${SMD406_IPV6_RUNTIME_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD406_IPV6_RUNTIME_PREFLIGHT_CONFIRMED=YES after confirming a read-only runtime preflight' >&2
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
peer_node=PC-210
interface=br0
controller_ipv6=fd40:534d:4406:1::180
worker_ipv6=fd40:534d:4406:1::128
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd406-ubuntu-runtime-preflight-${run_stamp}
candidate_conf=${run_dir}/slurm.conf
candidate_dbd_conf=${run_dir}/slurmdbd.conf.candidate

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
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
for required in "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
	"$scontrol" "$squeue"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_name in ip getent ss nc sha256sum systemctl awk cmp grep stat sed; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done

umask 077
mkdir "$run_dir" || fail 'cannot create run directory'
printf 'mode=READ_ONLY_RUNTIME_PREFLIGHT run_dir=%s interface=%s\n' \
	"$run_dir" "$interface"
sha256sum "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
	>"${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-before.txt" || fail 'cannot capture service identities'

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
grep -q ' is UP$' "${run_dir}/controller.txt" || fail 'controller is not UP'
"$scontrol" show config >"${run_dir}/controller-config.txt" || \
	fail 'controller config readback failed'
"$scontrol" show node "$node_name" >"${run_dir}/ubuntu-node.txt" || \
	fail 'Ubuntu node readback failed'
"$scontrol" show node "$peer_node" >"${run_dir}/mac-node.txt" || \
	fail 'Mac node readback failed'
"$squeue" -h -w "$node_name,$peer_node" >"${run_dir}/queue.txt" || \
	fail 'queue readback failed'
[ "$(node_field State "${run_dir}/ubuntu-node.txt")" = IDLE ] || fail 'ubuntu is not IDLE'
[ "$(node_field State "${run_dir}/mac-node.txt")" = IDLE ] || fail 'PC-210 is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/ubuntu-node.txt")" = 0 ] || fail 'ubuntu CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/ubuntu-node.txt")" = 0 ] || fail 'ubuntu AllocMem is not zero'
[ ! -s "${run_dir}/queue.txt" ] || fail 'target nodes have active jobs'

ip -6 -o addr show dev "$interface" >"${run_dir}/addresses.txt" || \
	fail 'cannot capture IPv6 addresses'
ip -6 route show table all >"${run_dir}/routes.txt" || fail 'cannot capture IPv6 routes'
getent ahostsv4 "$node_name" >"${run_dir}/ubuntu-resolution-v4.txt" 2>&1 || true
getent ahostsv4 "$peer_node" >"${run_dir}/mac-resolution-v4.txt" 2>&1 || true
getent ahostsv6 "$node_name" >"${run_dir}/ubuntu-resolution-v6.txt" 2>&1 || true
getent ahostsv6 "$peer_node" >"${run_dir}/mac-resolution-v6.txt" 2>&1 || true
ss -ltnp >"${run_dir}/listeners.txt" || fail 'cannot capture TCP listeners'
grep -E ':(6817|6818|6819)[[:space:]]' "${run_dir}/listeners.txt" \
	>"${run_dir}/slurm-listeners.txt" || true
nc -4 -vz -w 3 192.168.10.128 6818 \
	>"${run_dir}/mac-6818-ipv4.out" 2>"${run_dir}/mac-6818-ipv4.err" || \
	fail 'current IPv4 worker path failed'
if ip -6 -o addr show dev "$interface" | grep -Fq " ${controller_ipv6}/64 "; then
	fail "temporary Ubuntu ULA remains present: $controller_ipv6"
fi
if [ -e /run/smd406-ubuntu-ula.env ]; then
	fail 'temporary Ubuntu ULA state file remains present'
fi
if grep -Eq '^CommunicationParameters[[:space:]]*=.*EnableIPv6' \
	"${run_dir}/controller-config.txt"; then
	fail 'controller already enables IPv6; review current state before runtime test'
fi
if grep -Eq '^[[:space:]]*CommunicationParameters[[:space:]]*=.*EnableIPv6' \
	"$slurmdbd_conf"; then
	fail 'slurmdbd already enables IPv6; review current state before runtime test'
fi

stat -c '%U:%G:%a %n' "$slurm_conf" "$slurmdbd_conf" "$gres_conf" \
	>"${run_dir}/config-permissions.txt" || fail 'cannot capture config permissions'
awk -F= '
	/^[[:space:]]*(AuthType|CommunicationParameters|DbdAddr|DbdHost|DbdPort|LogFile|PidFile|PluginDir|SlurmUser|StorageHost|StorageLoc|StoragePort|StorageType|StorageUser)[[:space:]]*=/ {
		key = $1
		gsub(/[[:space:]]/, "", key)
		value = substr($0, index($0, "=") + 1)
		print key "=" value
	}
' "$slurmdbd_conf" >"${run_dir}/slurmdbd-nonsecret-keys.txt" || \
	fail 'cannot capture non-secret slurmdbd keys'
if grep -Eiq '(^|[^A-Za-z])(StoragePass|Password)[[:space:]]*=' \
	"${run_dir}/slurmdbd-nonsecret-keys.txt"; then
	fail 'secret key leaked into evidence'
fi

cp "$gres_conf" "${run_dir}/gres.conf" || fail 'cannot stage candidate gres.conf'
awk -v controller="$controller_ipv6" -v worker="$worker_ipv6" '
	function set_field(line, key, value, count, field, i, found, output) {
		count = split(line, field, /[[:space:]]+/)
		found = 0
		output = ""
		for (i = 1; i <= count; i++) {
			if (field[i] == "")
				continue
			if (index(field[i], key "=") == 1) {
				field[i] = key "=" value
				found = 1
			}
			output = output (output == "" ? "" : " ") field[i]
		}
		if (!found)
			output = output " " key "=" value
		return output
	}
	/^[[:space:]]*CommunicationParameters=/ {
		if ($0 !~ /(^|,)EnableIPv6(,|$)/)
			$0 = $0 ",EnableIPv6"
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
	END {
		if (!seen_communication)
			print "CommunicationParameters=EnableIPv6"
	}
' "$slurm_conf" >"$candidate_conf" || fail 'cannot build candidate slurm.conf'

awk -v controller="$controller_ipv6" '
	/^[[:space:]]*CommunicationParameters=/ {
		if ($0 !~ /(^|,)EnableIPv6(,|$)/)
			$0 = $0 ",EnableIPv6"
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
		if (!seen_communication)
			print "CommunicationParameters=EnableIPv6"
		if (!seen_dbd_addr)
			print "DbdAddr=" controller
	}
' "$slurmdbd_conf" >"$candidate_dbd_conf" || fail 'cannot build candidate slurmdbd.conf'
chmod 0600 "$candidate_dbd_conf" || fail 'cannot protect candidate slurmdbd.conf'

[ "$(grep -Ec '^[[:space:]]*CommunicationParameters=' "$candidate_conf")" -eq 1 ] || \
	fail 'candidate slurm.conf CommunicationParameters count mismatch'
[ "$(grep -Ec '^[[:space:]]*CommunicationParameters=' "$candidate_dbd_conf")" -eq 1 ] || \
	fail 'candidate slurmdbd.conf CommunicationParameters count mismatch'
[ "$(grep -Ec '^[[:space:]]*DbdAddr=' "$candidate_dbd_conf")" -eq 1 ] || \
	fail 'candidate DbdAddr count mismatch'
grep -Eq '^CommunicationParameters=.*EnableIPv6' "$candidate_conf" || \
	fail 'candidate slurm.conf does not enable IPv6'
grep -Eq '^CommunicationParameters=.*EnableIPv6' "$candidate_dbd_conf" || \
	fail 'candidate slurmdbd.conf does not enable IPv6'
grep -Fqx "DbdAddr=${controller_ipv6}" "$candidate_dbd_conf" || \
	fail 'candidate DbdAddr IPv6 mismatch'
grep -Fqx "SlurmctldHost=ubuntu2504(${controller_ipv6})" "$candidate_conf" || \
	fail 'candidate SlurmctldHost IPv6 mismatch'
grep -Fqx "AccountingStorageHost=${controller_ipv6}" "$candidate_conf" || \
	fail 'candidate AccountingStorageHost IPv6 mismatch'
grep -E '^NodeName=PC-210([[:space:]]|$)' "$candidate_conf" | \
	grep -Fq "NodeAddr=${worker_ipv6}" || fail 'candidate Mac NodeAddr mismatch'
grep -E '^NodeName=ubuntu([[:space:]]|$)' "$candidate_conf" | \
	grep -Fq "NodeAddr=${controller_ipv6}" || fail 'candidate Ubuntu NodeAddr mismatch'

"$slurmd" -C -N "$node_name" -f "$candidate_conf" \
	>"${run_dir}/candidate-slurmd-C.out" \
	2>"${run_dir}/candidate-slurmd-C.err" || fail 'candidate slurmd -C parse failed'
[ -s "${run_dir}/candidate-slurmd-C.out" ] || fail 'candidate slurmd -C produced no topology'
grep -E '^[[:space:]]*((AccountingStorageHost|CommunicationParameters|SlurmctldHost)=|NodeName=(PC-210|ubuntu)([[:space:]]|$))' \
	"$candidate_conf" >"${run_dir}/candidate-runtime-keys.txt"
grep -E '^[[:space:]]*(CommunicationParameters|DbdAddr|DbdHost|DbdPort)=' \
	"$candidate_dbd_conf" >"${run_dir}/candidate-dbd-runtime-keys.txt"

sha256sum "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
	>"${run_dir}/production-after.sha256" || fail 'cannot hash final production inputs'
cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed during preflight'
systemctl show slurmctld slurmdbd slurmd \
	-p Id -p MainPID -p ActiveEnterTimestamp -p ExecStart \
	>"${run_dir}/services-after.txt" || fail 'cannot recapture service identities'
cmp -s "${run_dir}/services-before.txt" "${run_dir}/services-after.txt" || \
	fail 'service identity changed during preflight'

printf '%s\n' \
	"runtime_candidate=SLURM_CONF_PARSE_PASS communication=EnableIPv6 controller=${controller_ipv6} worker=${worker_ipv6}" \
	'slurmdbd_candidate=STATIC_KEYS_PASS daemon_parse=NOT_RUN_TO_AVOID_DATABASE_SIDE_EFFECTS' \
	'ipv4_policy=RETAINED DisableIPv4=NOT_SET' \
	'network_state=CLEAN temporary_ula=ABSENT state_file=ABSENT' \
	"SMD406_UBUNTU_RUNTIME_PREFLIGHT_COMPLETE production_unchanged=PASS services_unchanged=PASS run_dir=$run_dir"
