#!/bin/sh

set -u

source_root=${SMD_SOURCE_ROOT:-/Users/tera/dev/slurm.26-05}
host_helper=${source_root}/contribs/macos-tests/smd001_nodeaddr_host_apply.sh
local_prefix=/opt/slurm/26.11.0
local_conf=${local_prefix}/etc/slurm.conf
local_scontrol=${local_prefix}/bin/scontrol
local_squeue=${local_prefix}/bin/squeue
local_pid_file=/var/run/slurmd.pid
remote_host=192.168.10.180
remote_user=tera
remote_login=${remote_user}@${remote_host}
remote_prefix=/usr/local/slurm/26.11.0
remote_conf=${remote_prefix}/etc/slurm.conf
remote_scontrol=${remote_prefix}/bin/scontrol
ssh_key=/Users/tera/.ssh/id_ed25519
known_hosts=/Users/tera/.ssh/known_hosts
node_name=PC-210
node_addr=192.168.10.128
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd001-nodeaddr-fix-${run_stamp}
local_backup=${local_prefix}/.smd001-nodeaddr-backup-${run_stamp}
remote_backup=${remote_prefix}/.smd001-nodeaddr-backup-${run_stamp}
local_applied=0
remote_applied=0
success=0

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

remote()
{
	/usr/bin/ssh -i "$ssh_key" -o BatchMode=yes \
		-o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" \
		-o ConnectTimeout=10 "$remote_login" "$@"
}

remote_host_action()
{
	action=$1
	remote "sudo /usr/bin/env SMD001_TARGET_CONF=${remote_conf} SMD001_SLURM_PREFIX=${remote_prefix} SMD001_BACKUP_DIR=${remote_backup} SMD001_NODE_NAME=${node_name} SMD001_NODE_ADDR=${node_addr} SMD001_HOST_LABEL=ubuntu /bin/sh -s -- ${action}" <"$host_helper"
}

local_host_action()
{
	action=$1
	/usr/bin/env SMD001_TARGET_CONF="$local_conf" \
		SMD001_SLURM_PREFIX="$local_prefix" \
		SMD001_BACKUP_DIR="$local_backup" \
		SMD001_NODE_NAME="$node_name" SMD001_NODE_ADDR="$node_addr" \
		SMD001_HOST_LABEL=mac /bin/sh "$host_helper" "$action"
}

wait_cluster_idle()
{
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if "$local_scontrol" ping >"${run_dir}/controller-current.txt" 2>&1 &&
			"$local_scontrol" show node "$node_name" \
				>"${run_dir}/node-current.txt" 2>"${run_dir}/node-current.err" &&
			/usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-current.txt" &&
			/usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-current.txt" &&
			[ -z "$("$local_squeue" -h -o '%i|%T|%u|%j|%N')" ]; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

restore_both()
{
	if [ "$local_applied" -ne 1 ] && [ "$remote_applied" -ne 1 ]; then
		return 0
	fi
	printf 'recovery: restoring both production configs\n' >&2
	if [ "$local_applied" -eq 1 ]; then
		local_host_action restore >"${run_dir}/local-restore.txt" 2>&1 || true
	fi
	if [ "$remote_applied" -eq 1 ]; then
		remote_host_action restore >"${run_dir}/remote-restore.txt" 2>&1 || true
	fi
	remote "sudo ${remote_scontrol} reconfigure" \
		>"${run_dir}/recovery-reconfigure.txt" 2>&1 || true
	wait_cluster_idle || true
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ]; then
		restore_both
		printf 'recovery: inspect %s\n' "$run_dir" >&2
	fi
	exit "$rc"
}

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
	fail 'run as root'
fi
if [ "${SMD001_NODEADDR_FIX_CONFIRMED:-}" != YES ]; then
	printf 'error: rerun with SMD001_NODEADDR_FIX_CONFIRMED=YES\n' >&2
	exit 75
fi

for required in "$host_helper" "$local_conf" "$local_scontrol" "$local_squeue" \
	"$local_pid_file" "$ssh_key" "$known_hosts"; do
	[ -e "$required" ] || fail "missing $required"
done

/bin/mkdir -m 0755 "$run_dir" || exit 1
trap cleanup EXIT HUP INT TERM

current_addr=$(/usr/sbin/ipconfig getifaddr en0) || fail 'unable to read en0 address'
[ "$current_addr" = "$node_addr" ] ||
	fail "en0 address changed: expected=$node_addr observed=$current_addr"

"$local_scontrol" ping >"${run_dir}/controller-before.txt" || exit 1
"$local_scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || exit 1
if ! /usr/bin/grep -q 'State=IDLE ' "${run_dir}/node-before.txt" ||
	! /usr/bin/grep -q 'CPUAlloc=0' "${run_dir}/node-before.txt"; then
	fail 'PC-210 is not IDLE before NodeAddr fix'
fi
queue_before=$("$local_squeue" -h -o '%i|%T|%u|%j|%N') || exit 1
[ -z "$queue_before" ] || fail "queue is not empty: $queue_before"

local_pid_before=$(/bin/cat "$local_pid_file")
/bin/ps -p "$local_pid_before" -o user=,pid=,ppid=,lstart=,command= \
	>"${run_dir}/local-slurmd-before.txt" || exit 1
/usr/bin/shasum -a 256 "$local_conf" >"${run_dir}/local-config-before.sha256" || exit 1

remote "hostname; getent hosts ${node_name}; sudo systemctl is-active slurmctld slurmdbd slurmd; sudo systemctl show -p MainPID --value slurmctld slurmdbd slurmd; sudo sha256sum ${remote_conf}; ${remote_scontrol} ping; ${remote_scontrol} show node ${node_name}; ${remote_prefix}/bin/squeue -h -o '%i|%T|%u|%j|%N'" \
	>"${run_dir}/remote-preflight.txt" || fail 'remote preflight failed'

remote_host_action stage >"${run_dir}/remote-stage.txt" || exit 1
local_host_action stage >"${run_dir}/local-stage.txt" || exit 1

local_applied=1
local_host_action apply >"${run_dir}/local-apply.txt" || exit 1
remote_applied=1
remote_host_action apply >"${run_dir}/remote-apply.txt" || exit 1

remote "sudo ${remote_scontrol} reconfigure" \
	>"${run_dir}/reconfigure.out" 2>"${run_dir}/reconfigure.err" ||
	fail 'controller reconfigure failed'
wait_cluster_idle || fail 'cluster did not return to stable IDLE after reconfigure'

local_host_action verify >"${run_dir}/local-verify.txt" || exit 1
remote_host_action verify >"${run_dir}/remote-verify.txt" || exit 1

"$local_scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || exit 1
/usr/bin/grep -q "NodeAddr=${node_addr}" "${run_dir}/node-after.txt" ||
	fail 'controller NodeAddr readback mismatch'
"$local_squeue" -h -o '%i|%T|%u|%j|%N' >"${run_dir}/queue-after.txt" || exit 1
[ ! -s "${run_dir}/queue-after.txt" ] || fail 'queue is not empty after reconfigure'
local_pid_after=$(/bin/cat "$local_pid_file")
[ "$local_pid_after" = "$local_pid_before" ] ||
	fail "Mac slurmd PID changed: ${local_pid_before}->${local_pid_after}"

remote "sudo systemctl is-active slurmctld slurmdbd slurmd; sudo systemctl show -p MainPID --value slurmctld slurmdbd slurmd; sudo sha256sum ${remote_conf}; ${remote_scontrol} ping; ${remote_scontrol} show node ${node_name}; ${remote_prefix}/bin/squeue -h -o '%i|%T|%u|%j|%N'" \
	>"${run_dir}/remote-readback.txt" || fail 'remote readback failed'

success=1
trap - EXIT HUP INT TERM
printf 'SMD001_NODEADDR_PRODUCTION_FIX_COMPLETE address=%s mac_pid=%s node=IDLE queue=EMPTY local_backup=%s remote_backup=%s run_dir=%s\n' \
	"$node_addr" "$local_pid_before" "$local_backup" "$remote_backup" "$run_dir"
