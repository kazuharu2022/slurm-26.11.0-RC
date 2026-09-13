#!/bin/sh

set -u

if [ "${SMD402_UBUNTU_WORKER_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD402_UBUNTU_WORKER_CONFIRMED=YES after approving the Ubuntu worker change' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
sacct=${prefix}/bin/sacct
unit_path=/etc/systemd/system/slurmd.service
node_name=ubuntu
node_addr=192.168.10.180
node_hostname=ubuntu2504
peer_node=PC-210
partition=smd402
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd402-provision-${run_stamp}
candidate_conf=${run_dir}/slurm.conf.candidate
candidate_unit=${run_dir}/slurmd.service
backup_conf=${slurm_conf}.smd402-${run_stamp}
smoke_out=${run_dir}/smoke.out
smoke_err=${run_dir}/smoke.err
config_installed=0
unit_installed=0
service_started=0
success=0
smoke_job=

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

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		awk 'NR == 1 { print; exit }'
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		[ -z "$(queue_state "$job_id")" ] && return 0
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

accounting_complete()
{
	file=$1
	"$sacct" -j "$smoke_job" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	awk -F '|' -v job="$smoke_job" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" &&
		$5 == "ubuntu" { job_ok = 1 }
		$1 == job ".0" && $3 == "COMPLETED" && $4 == "0:0" { step_ok = 1 }
		END { exit !(job_ok && step_ok) }
	' "$file"
}

wait_accounting()
{
	file=$1
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		accounting_complete "$file" && return 0
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

rollback()
{
	printf 'rollback_begin run_dir=%s\n' "$run_dir" >&2
	if [ "$service_started" -eq 1 ] || systemctl is-active --quiet slurmd; then
		systemctl stop slurmd >/dev/null 2>&1 || true
	fi
	if [ "$unit_installed" -eq 1 ]; then
		systemctl disable slurmd >/dev/null 2>&1 || true
		rm -f "$unit_path"
		systemctl daemon-reload >/dev/null 2>&1 || true
		systemctl reset-failed slurmd >/dev/null 2>&1 || true
	fi
	if [ "$config_installed" -eq 1 ] && [ -f "$backup_conf" ]; then
		cp -a "$backup_conf" "$slurm_conf"
		"$scontrol" reconfigure >/dev/null 2>&1 || true
	fi
	printf 'rollback_end backup=%s\n' "$backup_conf" >&2
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ]; then
		rollback
		printf 'recovery: inspect run_dir=%s backup=%s\n' \
			"$run_dir" "$backup_conf" >&2
	fi
	exit "$rc"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Linux ] || fail 'this provisioner is for the Ubuntu host'
[ "$(hostname -s)" = "$node_hostname" ] || \
	fail "unexpected hostname=$(hostname -s), expected $node_hostname"

for required in "$slurm_conf" "$slurmd" "$scontrol" "$squeue" \
	"$srun" "$sacct" "${prefix}/etc/slurm.key"; do
	[ -e "$required" ] || fail "missing $required"
done
for command in awk chmod chown cp date getent grep hostname id install ip mkdir rm \
	sed sleep ss stat sudo systemctl systemd-analyze uname; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command=$command"
done

[ "$(id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'
[ "$("$slurmd" -V)" = 'slurm 26.11.0-0rc1' ] || fail 'slurmd version mismatch'
[ "$(systemctl is-active slurmctld)" = active ] || fail 'slurmctld is not active'
[ "$(systemctl is-active slurmdbd)" = active ] || fail 'slurmdbd is not active'
[ ! -e "$unit_path" ] || fail "refusing to replace existing $unit_path"
if systemctl cat slurmd.service >/dev/null 2>&1; then
	fail 'slurmd.service already exists'
fi
[ -z "$(ss -ltnH 'sport = :6818')" ] || fail 'TCP port 6818 is already in use'
[ -f /sys/fs/cgroup/cgroup.controllers ] || fail 'cgroup v2 is not mounted'
for controller in cpu cpuset io memory pids; do
	grep -qw "$controller" /sys/fs/cgroup/cgroup.controllers || \
		fail "missing cgroup v2 controller=$controller"
done
for setting in ConstrainCores=yes ConstrainDevices=yes ConstrainRAMSpace=yes \
	ConstrainSwapSpace=yes; do
	grep -Fqx "$setting" "${prefix}/etc/cgroup.conf" || \
		fail "missing cgroup setting=$setting"
done
grep -Fqx 'ProctrackType=proctrack/cgroup' "$slurm_conf" || \
	fail 'ProctrackType is not proctrack/cgroup'
grep -Fqx 'TaskPlugin=task/affinity' "$slurm_conf" || \
	fail 'TaskPlugin is not task/affinity'
grep -Fqx 'JobAcctGatherType=jobacct_gather/cgroup' "$slurm_conf" || \
	fail 'JobAcctGatherType is not jobacct_gather/cgroup'
[ "$(stat -c '%U:%G:%a' "${prefix}/etc/slurm.key")" = slurm:slurm:600 ] || \
	fail 'slurm.key owner or mode mismatch'

actual_addr=$(ip -4 -o addr show dev br0 scope global |
	awk 'NR == 1 { split($4, a, "/"); print a[1] }')
[ "$actual_addr" = "$node_addr" ] || \
	fail "br0 address=$actual_addr expected=$node_addr"
route_src=$(ip route get 192.168.10.128 |
	awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
[ "$route_src" = "$node_addr" ] || \
	fail "route source=$route_src expected=$node_addr"

mkdir -m 0700 "$run_dir" || fail 'cannot create run directory'
trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || \
	fail 'controller ping failed'
grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$peer_node" >"${run_dir}/peer-before.txt" || \
	fail 'cannot read PC-210'
[ "$(node_field State "${run_dir}/peer-before.txt")" = IDLE ] || \
	fail 'PC-210 is not IDLE'
[ -z "$("$squeue" -h -w "$peer_node,$node_name")" ] || \
	fail 'target nodes have active jobs'

"$slurmd" -C >"${run_dir}/slurmd-C.txt" 2>"${run_dir}/slurmd-C.err" || \
	fail 'slurmd -C failed'
grep -Eq '^NodeName=ubuntu2504 CPUs=8 Boards=1 SocketsPerBoard=1 CoresPerSocket=4 ThreadsPerCore=2 RealMemory=64024([[:space:]]|$)' \
	"${run_dir}/slurmd-C.txt" || fail 'hardware topology changed from approved preflight'

[ "$(grep -Ec '^[[:space:]]*NodeName=ubuntu([[:space:]]|$)' "$slurm_conf")" -eq 1 ] || \
	fail 'expected exactly one NodeName=ubuntu definition'
[ "$(grep -Ec '^[[:space:]]*PartitionName=smd402([[:space:]]|$)' "$slurm_conf")" -eq 0 ] || \
	fail 'PartitionName=smd402 already exists'

awk '
	$1 == "NodeName=ubuntu" {
		print "NodeName=ubuntu NodeAddr=192.168.10.180 NodeHostName=ubuntu2504 CPUs=8 Boards=1 SocketsPerBoard=1 CoresPerSocket=4 ThreadsPerCore=2 RealMemory=64024"
		found = 1
		next
	}
	{ print }
	END {
		if (!found) exit 1
		print "PartitionName=smd402 Nodes=PC-210,ubuntu Default=NO MaxTime=00:10:00 State=UP"
	}
' "$slurm_conf" >"$candidate_conf" || fail 'cannot create candidate slurm.conf'

[ "$(grep -Ec '^[[:space:]]*NodeName=ubuntu([[:space:]]|$)' "$candidate_conf")" -eq 1 ] || \
	fail 'candidate node definition count mismatch'
[ "$(grep -Ec '^[[:space:]]*PartitionName=smd402([[:space:]]|$)' "$candidate_conf")" -eq 1 ] || \
	fail 'candidate partition definition count mismatch'
grep -Fqx 'NodeName=PC-210 Name=gpu Type=apple File=/dev/null' \
	"${prefix}/etc/gres.conf" || fail 'production Apple GRES line changed'

cat >"$candidate_unit" <<EOF
[Unit]
Description=Slurm node daemon (SMD-402 Ubuntu worker)
After=network-online.target remote-fs.target slurmctld.service
Wants=network-online.target
ConditionPathExists=${slurm_conf}

[Service]
Type=notify
RuntimeDirectory=slurm
RuntimeDirectoryMode=0755
ExecStart=${slurmd} --systemd -f ${slurm_conf}
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
LimitNOFILE=131072
LimitMEMLOCK=infinity
LimitSTACK=infinity
Delegate=yes
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF

systemd-analyze verify "$candidate_unit" >"${run_dir}/unit-verify.out" \
	2>"${run_dir}/unit-verify.err" || fail 'candidate systemd unit verification failed'

conf_uid=$(stat -c '%u' "$slurm_conf")
conf_gid=$(stat -c '%g' "$slurm_conf")
conf_mode=$(stat -c '%a' "$slurm_conf")
chown "$conf_uid:$conf_gid" "$candidate_conf"
chmod "$conf_mode" "$candidate_conf"
cp -a "$slurm_conf" "$backup_conf" || fail 'cannot back up slurm.conf'
config_installed=1
cp -a "$candidate_conf" "$slurm_conf" || fail 'cannot install candidate slurm.conf'
"$scontrol" reconfigure >"${run_dir}/reconfigure.out" \
	2>"${run_dir}/reconfigure.err" || fail 'controller reconfigure failed'
"$scontrol" show partition "$partition" >"${run_dir}/partition-after.txt" || \
	fail 'new partition readback failed'
grep -Eq 'Nodes=(PC-210,ubuntu|ubuntu,PC-210)' \
	"${run_dir}/partition-after.txt" || \
	fail 'new partition node set mismatch'

install -d -o root -g root -m 0755 /var/spool/slurmd
install -d -o slurm -g slurm -m 0755 /var/log/slurm
unit_installed=1
install -o root -g root -m 0644 "$candidate_unit" "$unit_path" || \
	fail 'cannot install slurmd.service'
systemctl daemon-reload || fail 'systemd daemon-reload failed'
systemctl start slurmd || fail 'slurmd.service failed to start'
service_started=1

attempt=0
while [ "$attempt" -lt 90 ]; do
	"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" 2>/dev/null || true
	state=$(node_field State "${run_dir}/node-after.txt")
	[ "$state" = IDLE ] && break
	sleep 1
	attempt=$((attempt + 1))
done
[ "$state" = IDLE ] || fail "ubuntu node did not become IDLE, state=$state"
grep -Fq 'NodeAddr=192.168.10.180' "${run_dir}/node-after.txt" || \
	fail 'registered NodeAddr mismatch'
grep -Fq 'NodeHostName=ubuntu2504' "${run_dir}/node-after.txt" || \
	fail 'registered NodeHostName mismatch'
grep -Fq 'CPUTot=8' "${run_dir}/node-after.txt" || fail 'registered CPU count mismatch'
grep -Fq 'RealMemory=64024' "${run_dir}/node-after.txt" || \
	fail 'registered memory mismatch'

"$slurmd" -G -f "$slurm_conf" >"${run_dir}/slurmd-G.out" \
	2>"${run_dir}/slurmd-G.err" || fail 'slurmd -G failed after spool creation'
if grep -E '(^|[[:space:]])Name=gpu([[:space:]]|$)' "${run_dir}/slurmd-G.out" \
	"${run_dir}/slurmd-G.err" >/dev/null; then
	fail 'Ubuntu unexpectedly registered a GPU GRES in CPU-only SMD-402 scope'
fi

sudo -u "$test_user" -H env SLURM_CONF="$slurm_conf" \
	"$srun" --partition="$partition" --nodelist="$node_name" \
	--nodes=1 --ntasks=1 --time=00:01:00 --chdir=/tmp \
	/bin/sh -c 'printf "job_id=%s node=%s host=%s arch=%s uid=%s gid=%s\\n" \
	"$SLURM_JOB_ID" "$SLURMD_NODENAME" "$(hostname)" "$(uname -m)" \
	"$(id -u)" "$(id -g)"' \
	>"$smoke_out" 2>"$smoke_err" || fail 'Ubuntu worker smoke srun failed'
smoke_job=$(sed -n 's/^job_id=\([0-9][0-9]*\).*/\1/p' "$smoke_out")
case "$smoke_job" in
''|*[!0-9]*) fail "invalid smoke job id=$smoke_job" ;;
esac
grep -Eq "^job_id=${smoke_job} node=ubuntu host=ubuntu2504 arch=x86_64 uid=3001 gid=3001$" \
	"$smoke_out" || fail 'Ubuntu smoke output mismatch'
wait_job_gone "$smoke_job" || fail 'Ubuntu smoke job remained queued'
wait_accounting "${run_dir}/smoke-accounting.txt" || fail 'Ubuntu smoke accounting mismatch'

systemctl enable slurmd >"${run_dir}/enable.out" 2>"${run_dir}/enable.err" || \
	fail 'cannot enable slurmd.service'
systemctl is-enabled slurmd >"${run_dir}/enabled.txt" || fail 'slurmd is not enabled'
systemctl status slurmd --no-pager -l >"${run_dir}/service-final.txt" || \
	fail 'slurmd service is not active'
"$scontrol" show node "$peer_node" >"${run_dir}/peer-final.txt" || \
	fail 'cannot read final PC-210 state'
[ "$(node_field State "${run_dir}/peer-final.txt")" = IDLE ] || \
	fail 'PC-210 is not IDLE after provisioning'
[ -z "$("$squeue" -h -w "$peer_node,$node_name")" ] || \
	fail 'target nodes have jobs after provisioning'

success=1
trap - EXIT HUP INT TERM
printf 'SMD402_UBUNTU_WORKER_READY node=%s addr=%s host=%s smoke_job=%s service=active_enabled backup=%s run_dir=%s\n' \
	"$node_name" "$node_addr" "$node_hostname" "$smoke_job" "$backup_conf" "$run_dir"
