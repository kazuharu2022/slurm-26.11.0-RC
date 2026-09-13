#!/bin/sh

set -u

if [ "${SMD404_CONFIGLESS_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD404_CONFIGLESS_PREFLIGHT_CONFIRMED=YES after confirming a read-only preflight' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
source_root=/Users/REDACTED_USER/dev/slurm.26-05
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
pid_file=/var/run/slurmd.pid
plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_target=system/org.schedmd.slurmd
node_name=PC-210
peer_node=ubuntu
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd404-preflight-${run_stamp}

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
	"$pid_file" "$plist" "${source_root}/src/common/sack_api.h" \
	"${source_root}/src/common/read_config.c" \
	"${source_root}/src/slurmd/slurmd/slurmd.c" \
	"${source_root}/src/slurmd/slurmd/.libs/slurmd" \
	"${source_root}/src/api/.libs/libslurmfull.dylib"; do
	[ -e "$required" ] || fail "missing $required"
done

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/usr/bin/printf 'mode=READ_ONLY_PRODUCTION run_dir=%s\n' "$run_dir"

/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$plist" "$slurmd" \
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
[ "$(node_field State "${run_dir}/mac-node.txt")" = IDLE ] || fail 'PC-210 is not IDLE'
[ "$(node_field State "${run_dir}/ubuntu-node.txt")" = IDLE ] || fail 'ubuntu is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/mac-node.txt")" = 0 ] || fail 'PC-210 CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/mac-node.txt")" = 0 ] || fail 'PC-210 AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name,$peer_node")" ] || fail 'target nodes have active jobs'

/usr/bin/grep -Fqx 'ProctrackType=proctrack/pgid' "$slurm_conf" || \
	fail 'Mac local ProctrackType is not proctrack/pgid'
/usr/bin/grep -Fqx 'JobAcctGatherType=jobacct_gather/none' "$slurm_conf" || \
	fail 'Mac local JobAcctGatherType is not jobacct_gather/none'
if /usr/bin/grep -Eq '^[[:space:]]*TaskPlugin=' "$slurm_conf"; then
	fail 'Mac local TaskPlugin must remain unset'
fi
/usr/bin/grep -Eq '^SlurmctldParameters=.*enable_configless' "$slurm_conf" || \
	fail 'enable_configless is absent from the Mac local copy'

/usr/bin/grep -Eq '^[[:space:]]*ProctrackType[[:space:]]*=[[:space:]]*proctrack/cgroup[[:space:]]*$' \
	"${run_dir}/controller-config.txt" || fail 'controller ProctrackType evidence changed'
/usr/bin/grep -Eq '^[[:space:]]*TaskPlugin[[:space:]]*=[[:space:]]*task/affinity[[:space:]]*$' \
	"${run_dir}/controller-config.txt" || fail 'controller TaskPlugin evidence changed'
/usr/bin/grep -Eq '^[[:space:]]*JobAcctGatherType[[:space:]]*=[[:space:]]*jobacct_gather/cgroup[[:space:]]*$' \
	"${run_dir}/controller-config.txt" || fail 'controller JobAcctGatherType evidence changed'
/usr/bin/grep -Eq 'SlurmctldParameters[[:space:]]*=.*enable_configless' \
	"${run_dir}/controller-config.txt" || fail 'controller configless mode is not enabled'

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
/usr/bin/grep -Fq -- '-f' "${run_dir}/launchd.txt" || fail 'production launchd is not local-config mode'

/usr/bin/file "${prefix}/lib/slurm/proctrack_pgid.so" \
	>"${run_dir}/proctrack-pgid.file" || fail 'cannot inspect proctrack/pgid plugin'
/usr/bin/grep -Fq 'Mach-O 64-bit bundle arm64' "${run_dir}/proctrack-pgid.file" || \
	fail 'proctrack/pgid plugin is not arm64 Mach-O'
[ ! -e "${prefix}/lib/slurm/proctrack_cgroup.so" ] || \
	fail 'unexpected proctrack/cgroup plugin on macOS'

/sbin/mount >"${run_dir}/mount.txt" || fail 'cannot capture mount state'
/usr/bin/grep -Eq ' on / \(apfs, .*read-only' "${run_dir}/mount.txt" || \
	fail 'root filesystem is not the expected read-only APFS mount'
[ ! -e /run ] || fail '/run unexpectedly exists; review runtime path assumptions'
[ -d /var/run ] || fail '/var/run is not available'

/usr/bin/grep -Fq '#define SLURM_SACK_RUN_DIR "/var/run"' \
	"${source_root}/src/common/sack_api.h" || fail 'macOS runtime path source fix is absent'
/usr/bin/grep -Fq 'SLURM_CONFIGLESS_CONF_FILE' \
	"${source_root}/src/common/read_config.c" || fail 'client cache lookup source fix is absent'
/usr/bin/grep -Fq 'SLURM_CONFIGLESS_CONF_DIR' \
	"${source_root}/src/slurmd/slurmd/slurmd.c" || fail 'slurmd cache-link source fix is absent'
/usr/bin/strings "${source_root}/src/slurmd/slurmd/.libs/slurmd" \
	>"${run_dir}/candidate-slurmd.strings"
/usr/bin/grep -Fqx '/var/run/slurm/conf' "${run_dir}/candidate-slurmd.strings" || \
	fail 'candidate slurmd lacks /var/run configless link path'
/usr/bin/strings "${source_root}/src/api/.libs/libslurmfull.dylib" \
	>"${run_dir}/candidate-lib.strings"
/usr/bin/grep -Fqx '/var/run/slurm/conf/slurm.conf' "${run_dir}/candidate-lib.strings" || \
	fail 'candidate client library lacks macOS cache lookup path'

/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$plist" "$slurmd" \
	>"${run_dir}/production-after.sha256" || fail 'cannot hash final production inputs'
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed during preflight'
[ "$(/bin/cat "$pid_file")" = "$pid" ] || fail 'slurmd PID changed during preflight'

/usr/bin/printf '%s\n' \
	'configless_precedence=CONFIRMED conf_server_over_local_file' \
	'controller_profile=INCOMPATIBLE proctrack/cgroup task/affinity jobacct_gather/cgroup' \
	'mac_profile=CONFIRMED proctrack/pgid task/unset jobacct_gather/none' \
	'runtime_path_defect=FIX_BUILT root=/run-unavailable cache_link=/var/run/slurm/conf' \
	'portable_profile_requirement=REMOVE_GLOBAL_PROCTRACK_TASK_JOBACCT_LINES' \
	"SMD404_MAC_PREFLIGHT_COMPLETE slurmd_pid=$pid production_unchanged=PASS run_dir=$run_dir"
