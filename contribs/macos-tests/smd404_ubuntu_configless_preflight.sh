#!/bin/sh

set -u

if [ "${SMD404_UBUNTU_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD404_UBUNTU_PREFLIGHT_CONFIRMED=YES after confirming a read-only preflight' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
node_name=ubuntu
peer_node=PC-210
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd404-ubuntu-preflight-${run_stamp}
candidate_conf=${run_dir}/slurm.conf.portable-candidate

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
[ "$(uname -s)" = Linux ] || fail 'this preflight is for ubuntu2504'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
for required in "$slurm_conf" "$gres_conf" "$slurmd" "$scontrol" "$squeue"; do
	[ -e "$required" ] || fail "missing $required"
done
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
done

mkdir -m 0700 "$run_dir" || fail 'cannot create run directory'
printf 'mode=READ_ONLY_PRODUCTION run_dir=%s\n' "$run_dir"
sha256sum "$slurm_conf" "$gres_conf" "$slurmd" \
	>"${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
grep -q ' is UP$' "${run_dir}/controller.txt" || fail 'controller is not UP'
"$scontrol" show config >"${run_dir}/controller-config.txt" || \
	fail 'controller config readback failed'
"$scontrol" show node "$node_name" >"${run_dir}/ubuntu-node.txt" || \
	fail 'Ubuntu node readback failed'
"$scontrol" show node "$peer_node" >"${run_dir}/mac-node.txt" || \
	fail 'Mac node readback failed'
[ "$(node_field State "${run_dir}/ubuntu-node.txt")" = IDLE ] || fail 'ubuntu is not IDLE'
[ "$(node_field State "${run_dir}/mac-node.txt")" = IDLE ] || fail 'PC-210 is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/ubuntu-node.txt")" = 0 ] || fail 'ubuntu CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/ubuntu-node.txt")" = 0 ] || fail 'ubuntu AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name,$peer_node")" ] || fail 'target nodes have active jobs'

grep -Fqx 'ProctrackType=proctrack/cgroup' "$slurm_conf" || \
	fail 'source ProctrackType is not proctrack/cgroup'
grep -Fqx 'TaskPlugin=task/affinity' "$slurm_conf" || \
	fail 'source TaskPlugin is not task/affinity'
grep -Fqx 'JobAcctGatherType=jobacct_gather/cgroup' "$slurm_conf" || \
	fail 'source JobAcctGatherType is not jobacct_gather/cgroup'
grep -Eq '^SlurmctldParameters=.*enable_configless' "$slurm_conf" || \
	fail 'controller configless mode is not enabled'
grep -Fqx 'NodeName=PC-210 Name=gpu Type=apple File=/dev/null' "$gres_conf" || \
	fail 'controller gres.conf does not contain the Mac Apple GRES record'

for plugin in cgroup_v2.so proctrack_cgroup.so; do
	[ -f "${prefix}/lib/slurm/$plugin" ] || fail "missing Linux plugin=$plugin"
	file "${prefix}/lib/slurm/$plugin" >"${run_dir}/${plugin}.file" || \
		fail "cannot inspect plugin=$plugin"
	grep -Fq 'ELF 64-bit LSB shared object, x86-64' "${run_dir}/${plugin}.file" || \
		fail "plugin architecture mismatch=$plugin"
done

awk '
	/^[[:space:]]*ProctrackType=/ { next }
	/^[[:space:]]*TaskPlugin=/ { next }
	/^[[:space:]]*JobAcctGatherType=/ { next }
	{ print }
' "$slurm_conf" >"$candidate_conf" || fail 'cannot build portable candidate config'
[ "$(grep -Ec '^[[:space:]]*(ProctrackType|TaskPlugin|JobAcctGatherType)=' "$candidate_conf")" -eq 0 ] || \
	fail 'portable candidate still has a platform-specific plugin line'

"$slurmd" -C -N "$node_name" -f "$candidate_conf" \
	>"${run_dir}/candidate-slurmd-C.txt" \
	2>"${run_dir}/candidate-slurmd-C.err" || fail 'portable candidate slurmd -C failed'
grep -Eq '^NodeName=ubuntu2504 CPUs=8 Boards=1 SocketsPerBoard=1 CoresPerSocket=4 ThreadsPerCore=2 RealMemory=64024([[:space:]]|$)' \
	"${run_dir}/candidate-slurmd-C.txt" || fail 'portable candidate topology changed'

sha256sum "$slurm_conf" "$gres_conf" "$slurmd" \
	>"${run_dir}/production-after.sha256" || fail 'cannot hash final production inputs'
cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed during preflight'
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || fail "$service changed state during preflight"
done

printf '%s\n' \
	'controller_configless=ENABLED' \
	'current_profile=CONFIRMED proctrack/cgroup task/affinity jobacct_gather/cgroup' \
	'portable_candidate=PARSE_PASS global ProctrackType/TaskPlugin/JobAcctGatherType omitted' \
	'platform_default_design=Linux_WITH_CGROUP_to_cgroup macOS_without_cgroup_to_pgid' \
	'ubuntu_regression_required=task_binding_and_jobacct_temporarily_disabled' \
	"SMD404_UBUNTU_PREFLIGHT_COMPLETE production_unchanged=PASS run_dir=$run_dir"
