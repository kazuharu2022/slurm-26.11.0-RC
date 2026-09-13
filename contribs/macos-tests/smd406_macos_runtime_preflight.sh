#!/bin/sh

set -u

if [ "${SMD406_IPV6_RUNTIME_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD406_IPV6_RUNTIME_PREFLIGHT_CONFIRMED=YES after confirming a read-only runtime preflight' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
slurm_key=${prefix}/etc/slurm.key
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
pid_file=/var/run/slurmd.pid
service_target=system/org.schedmd.slurmd
node_name=PC-210
peer_node=ubuntu
controller_name=ubuntu2504
interface=en0
controller_ipv6=fd40:534d:4406:1::180
worker_ipv6=fd40:534d:4406:1::128
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd406-mac-runtime-preflight-${run_stamp}
candidate_conf=${run_dir}/slurm.conf

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
for required in "$slurm_conf" "$gres_conf" "$slurm_key" "$slurmd" "$scontrol" "$squeue" \
	"$plist" "$pid_file"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_path in /sbin/ifconfig /usr/sbin/netstat /usr/bin/dscacheutil \
	/usr/bin/nc /usr/sbin/lsof /usr/bin/awk /usr/bin/cmp /usr/bin/grep \
	/usr/bin/shasum /usr/bin/plutil /bin/launchctl /bin/cp /bin/mkdir; do
	[ -x "$command_path" ] || fail "required command is not executable: $command_path"
done

umask 077
/bin/mkdir "$run_dir" || fail 'cannot create run directory'
/usr/bin/printf 'mode=READ_ONLY_RUNTIME_PREFLIGHT run_dir=%s interface=%s\n' \
	"$run_dir" "$interface"
/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurmd" "$plist" \
	>"${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller.txt" || fail 'controller is not UP'
"$scontrol" show config >"${run_dir}/controller-config.txt" || \
	fail 'controller config readback failed'
"$scontrol" show node "$node_name" >"${run_dir}/mac-node.txt" || \
	fail 'Mac node readback failed'
"$scontrol" show node "$peer_node" >"${run_dir}/ubuntu-node.txt" || \
	fail 'Ubuntu node readback failed'
"$squeue" -h -w "$node_name,$peer_node" >"${run_dir}/queue.txt" || \
	fail 'queue readback failed'
[ "$(node_field State "${run_dir}/mac-node.txt")" = IDLE ] || fail 'PC-210 is not IDLE'
[ "$(node_field State "${run_dir}/ubuntu-node.txt")" = IDLE ] || fail 'ubuntu is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/mac-node.txt")" = 0 ] || fail 'PC-210 CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/mac-node.txt")" = 0 ] || fail 'PC-210 AllocMem is not zero'
[ ! -s "${run_dir}/queue.txt" ] || fail 'target nodes have active jobs'

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
/usr/bin/plutil -p "$plist" >"${run_dir}/launchd-plist.txt" || fail 'cannot inspect launchd plist'

/sbin/ifconfig "$interface" >"${run_dir}/ifconfig-interface.txt" || \
	fail "missing interface=$interface"
/usr/sbin/netstat -rn -f inet6 >"${run_dir}/route-ipv6.txt" 2>&1 || \
	fail 'cannot capture IPv6 routes'
/usr/bin/dscacheutil -q host -a name "$controller_name" \
	>"${run_dir}/controller-resolution.txt" 2>"${run_dir}/controller-resolution.err" || true
/usr/sbin/lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN \
	>"${run_dir}/slurmd-listeners.txt" 2>"${run_dir}/slurmd-listeners.err" || true
/usr/bin/nc -4 -vz -w 3 "$controller_name" 6817 \
	>"${run_dir}/controller-6817-ipv4.out" \
	2>"${run_dir}/controller-6817-ipv4.err" || fail 'current IPv4 controller path failed'

if /usr/bin/grep -Fq "inet6 ${worker_ipv6} " "${run_dir}/ifconfig-interface.txt"; then
	fail "temporary Mac ULA remains present: $worker_ipv6"
fi
if /usr/bin/grep -Eq '^[[:space:]]*CommunicationParameters[[:space:]]*=.*EnableIPv6' \
	"$slurm_conf"; then
	fail 'Mac local config already enables IPv6; review current state before runtime test'
fi
if /usr/bin/grep -Eq '^CommunicationParameters[[:space:]]*=.*EnableIPv6' \
	"${run_dir}/controller-config.txt"; then
	fail 'controller already enables IPv6; review current state before runtime test'
fi

/bin/cp "$gres_conf" "${run_dir}/gres.conf" || fail 'cannot stage candidate gres.conf'
/usr/bin/awk -v controller="$controller_ipv6" -v worker="$worker_ipv6" '
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

[ "$(/usr/bin/grep -Ec '^[[:space:]]*CommunicationParameters=' "$candidate_conf")" -eq 1 ] || \
	fail 'candidate CommunicationParameters count mismatch'
/usr/bin/grep -Eq '^CommunicationParameters=.*EnableIPv6' "$candidate_conf" || \
	fail 'candidate does not enable IPv6'
/usr/bin/grep -Fqx "SlurmctldHost=ubuntu2504(${controller_ipv6})" "$candidate_conf" || \
	fail 'candidate SlurmctldHost IPv6 address mismatch'
/usr/bin/grep -Fqx "AccountingStorageHost=${controller_ipv6}" "$candidate_conf" || \
	fail 'candidate AccountingStorageHost IPv6 address mismatch'
/usr/bin/grep -E '^NodeName=PC-210([[:space:]]|$)' "$candidate_conf" | \
	/usr/bin/grep -Fq "NodeAddr=${worker_ipv6}" || fail 'candidate Mac NodeAddr mismatch'
/usr/bin/grep -E '^NodeName=ubuntu([[:space:]]|$)' "$candidate_conf" | \
	/usr/bin/grep -Fq "NodeAddr=${controller_ipv6}" || fail 'candidate Ubuntu NodeAddr mismatch'

"$slurmd" -C -N "$node_name" -f "$candidate_conf" \
	>"${run_dir}/candidate-slurmd-C.out" \
	2>"${run_dir}/candidate-slurmd-C.err" || fail 'candidate slurmd -C parse failed'
[ -s "${run_dir}/candidate-slurmd-C.out" ] || fail 'candidate slurmd -C produced no topology'
SLURM_SACK_KEY="$slurm_key" "$slurmd" -G -f "$candidate_conf" \
	>"${run_dir}/candidate-slurmd-G.out" \
	2>"${run_dir}/candidate-slurmd-G.err" || fail 'candidate slurmd -G parse failed'
/usr/bin/grep -Eq 'Gres Name=gpu Type=apple Count=1' \
	"${run_dir}/candidate-slurmd-G.out" "${run_dir}/candidate-slurmd-G.err" || \
	fail 'candidate Apple GPU GRES validation missing'

/usr/bin/grep -E '^[[:space:]]*((AccountingStorageHost|CommunicationParameters|SlurmctldHost)=|NodeName=(PC-210|ubuntu)([[:space:]]|$))' \
	"$candidate_conf" >"${run_dir}/candidate-runtime-keys.txt"
/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurmd" "$plist" \
	>"${run_dir}/production-after.sha256" || fail 'cannot hash final production inputs'
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed during preflight'
[ "$(/bin/cat "$pid_file")" = "$pid" ] || fail 'slurmd PID changed during preflight'

/usr/bin/printf '%s\n' \
	"runtime_candidate=PARSE_PASS communication=EnableIPv6 controller=${controller_ipv6} worker=${worker_ipv6}" \
	'ipv4_policy=RETAINED DisableIPv4=NOT_SET' \
	'network_state=CLEAN temporary_ula=ABSENT' \
	"SMD406_MAC_RUNTIME_PREFLIGHT_COMPLETE slurmd_pid=$pid production_unchanged=PASS run_dir=$run_dir"
