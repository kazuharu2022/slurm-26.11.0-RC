#!/bin/sh

set -u

if [ "${SMD402_MIXED_ARCH_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD402_MIXED_ARCH_CONFIRMED=YES after both workers are idle' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
partition=smd402
linux_node=ubuntu
mac_node=PC-210
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd402-mixed-${run_stamp}
success_name=smd402-success-${run_stamp}
cancel_name=smd402-cancel-${run_stamp}
success_job=
cancel_job=
cancel_client_pid=
success=0

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

discover_job()
{
	job_name=$1
	"$squeue" -h -n "$job_name" -u "$test_user" -o '%A' 2>/dev/null |
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

cancel_if_active()
{
	job_id=$1
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id")
	if [ -n "$state" ]; then
		printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state" >&2
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ -z "$success_job" ]; then
		success_job=$(discover_job "$success_name")
	fi
	if [ -z "$cancel_job" ]; then
		cancel_job=$(discover_job "$cancel_name")
	fi
	cancel_if_active "$success_job"
	cancel_if_active "$cancel_job"
	if [ -n "$cancel_client_pid" ]; then
		kill "$cancel_client_pid" >/dev/null 2>&1 || true
	fi
	if [ "$success" -ne 1 ]; then
		printf 'recovery: production configuration was not changed; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

accounting_success()
{
	file=$1
	"$sacct" -j "$success_job" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	awk -F '|' -v job="$success_job" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" &&
		index($5, "PC-210") && index($5, "ubuntu") { job_ok = 1 }
		$1 == job ".0" && $3 == "COMPLETED" && $4 == "0:0" { step_ok = 1 }
		END { exit !(job_ok && step_ok) }
	' "$file"
}

accounting_cancel()
{
	file=$1
	"$sacct" -j "$cancel_job" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	awk -F '|' -v job="$cancel_job" -v user="$test_user" '
		$1 == job && $2 == user && index($3, "CANCELLED") == 1 &&
		index($5, "PC-210") && index($5, "ubuntu") { job_ok = 1 }
		$1 == job ".0" && (index($3, "CANCELLED") == 1 || $3 == "FAILED") {
			step_ok = 1
		}
		END { exit !(job_ok && step_ok) }
	' "$file"
}

wait_accounting()
{
	mode=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if [ "$mode" = success ]; then
			accounting_success "$file" && return 0
		else
			accounting_cancel "$file" && return 0
		fi
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

probe_pid_gone()
{
	node=$1
	pid=$2
	out=$3
	sudo -u "$test_user" -H env SLURM_CONF="$slurm_conf" \
		"$srun" --partition="$partition" --nodelist="$node" \
		--nodes=1 --ntasks=1 --time=00:01:00 --chdir=/tmp \
		/bin/sh -c '
			if /bin/kill -0 "$1" 2>/dev/null; then
				printf "residual=YES node=%s pid=%s\\n" "$SLURMD_NODENAME" "$1"
				exit 99
			fi
			printf "residual=NO node=%s pid=%s\\n" "$SLURMD_NODENAME" "$1"
		' smd402-probe "$pid" >"$out" 2>"${out%.out}.err"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Linux ] || fail 'run this driver on the Ubuntu controller'
for required in "$slurm_conf" "$scontrol" "$squeue" "$srun" \
	"$scancel" "$sacct"; do
	[ -e "$required" ] || fail "missing $required"
done
for command in awk date grep id kill mkdir sed sleep sudo uname wc; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command=$command"
done
[ "$(id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
trap cleanup EXIT HUP INT TERM
printf 'run_dir=%s partition=%s nodes=%s,%s\n' \
	"$run_dir" "$partition" "$linux_node" "$mac_node"

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || \
	fail 'controller ping failed'
grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show partition "$partition" >"${run_dir}/partition-before.txt" || \
	fail 'SMD-402 partition is missing'
grep -Eq 'Nodes=(PC-210,ubuntu|ubuntu,PC-210)' \
	"${run_dir}/partition-before.txt" || \
	fail 'SMD-402 partition node set mismatch'

for node in "$linux_node" "$mac_node"; do
	"$scontrol" show node "$node" >"${run_dir}/node-${node}-before.txt" || \
		fail "cannot read node=$node"
	[ "$(node_field State "${run_dir}/node-${node}-before.txt")" = IDLE ] || \
		fail "node=$node is not IDLE"
	[ "$(node_field CPUAlloc "${run_dir}/node-${node}-before.txt")" = 0 ] || \
		fail "node=$node CPUAlloc is not zero"
	[ "$(node_field AllocMem "${run_dir}/node-${node}-before.txt")" = 0 ] || \
		fail "node=$node AllocMem is not zero"
done
[ -z "$("$squeue" -h -w "$linux_node,$mac_node")" ] || \
	fail 'target nodes have active jobs'
linux_start_before=$(node_field SlurmdStartTime \
	"${run_dir}/node-${linux_node}-before.txt")
mac_start_before=$(node_field SlurmdStartTime \
	"${run_dir}/node-${mac_node}-before.txt")
[ -n "$linux_start_before" ] || fail 'missing Ubuntu SlurmdStartTime'
[ -n "$mac_start_before" ] || fail 'missing macOS SlurmdStartTime'

sudo -u "$test_user" -H env SLURM_CONF="$slurm_conf" \
	"$srun" --partition="$partition" --job-name="$success_name" \
	--nodes=2 --ntasks=2 --ntasks-per-node=1 --time=00:02:00 --chdir=/tmp \
	/bin/sh -c '
		printf "record=success job_id=%s step_id=%s procid=%s node=%s host=%s arch=%s uid=%s gid=%s\\n" \
			"$SLURM_JOB_ID" "$SLURM_STEP_ID" "$SLURM_PROCID" \
			"$SLURMD_NODENAME" "$(hostname)" "$(uname -m)" \
			"$(id -u)" "$(id -g)"
	' >"${run_dir}/success.out" 2>"${run_dir}/success.err" || \
	fail 'mixed-architecture success srun failed'
[ ! -s "${run_dir}/success.err" ] || fail 'success srun produced stderr'

success_job=$(sed -n 's/^record=success job_id=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/success.out" | sort -u)
case "$success_job" in
''|*[!0-9]*) fail "invalid success job id=$success_job" ;;
esac
[ "$(grep -c '^record=success ' "${run_dir}/success.out")" -eq 2 ] || \
	fail 'success output does not contain two ranks'
grep -Eq '^record=success .* procid=[01] node=ubuntu host=ubuntu2504 arch=x86_64 uid=3001 gid=3001$' \
	"${run_dir}/success.out" || fail 'Ubuntu rank output mismatch'
grep -Eq '^record=success .* procid=[01] node=PC-210 host=PC-210\.local arch=arm64 uid=3001 gid=3001$' \
	"${run_dir}/success.out" || fail 'macOS rank output mismatch'
[ "$(sed -n 's/^record=success .* procid=\([01]\) .*/\1/p' \
	"${run_dir}/success.out" | sort -u | tr '\n' ',' | sed 's/,$//')" = 0,1 ] || \
	fail 'success rank set mismatch'
wait_job_gone "$success_job" || fail 'success job remained queued'
wait_accounting success "${run_dir}/success-accounting.txt" || \
	fail 'success accounting mismatch'
printf 'mixed_success=PASS job_id=%s ranks=0,1 nodes=ubuntu:x86_64,PC-210:arm64\n' \
	"$success_job"

sudo -u "$test_user" -H env SLURM_CONF="$slurm_conf" \
	"$srun" --partition="$partition" --job-name="$cancel_name" \
	--nodes=2 --ntasks=2 --ntasks-per-node=1 --time=00:03:00 --chdir=/tmp \
	/bin/sh -c '
		/bin/sleep 180 &
		child_pid=$!
		trap '\''printf "record=signal procid=%s node=%s pid=%s\\n" \
			"$SLURM_PROCID" "$SLURMD_NODENAME" "$$"; exit 143'\'' HUP INT TERM
		printf "record=ready job_id=%s step_id=%s procid=%s node=%s host=%s arch=%s pid=%s child_pid=%s uid=%s gid=%s\\n" \
			"$SLURM_JOB_ID" "$SLURM_STEP_ID" "$SLURM_PROCID" \
			"$SLURMD_NODENAME" "$(hostname)" "$(uname -m)" "$$" "$child_pid" \
			"$(id -u)" "$(id -g)"
		wait "$child_pid"
	' >"${run_dir}/cancel.out" 2>"${run_dir}/cancel.err" &
cancel_client_pid=$!

attempt=0
while [ "$attempt" -lt 60 ]; do
	ready_count=$(grep -c '^record=ready ' "${run_dir}/cancel.out" 2>/dev/null || true)
	[ "$ready_count" -eq 2 ] && break
	sleep 1
	attempt=$((attempt + 1))
done
[ "$ready_count" -eq 2 ] || fail 'cancel step did not report two ready ranks'
cancel_job=$(sed -n 's/^record=ready job_id=\([0-9][0-9]*\).*/\1/p' \
	"${run_dir}/cancel.out" | sort -u)
case "$cancel_job" in
''|*[!0-9]*) fail "invalid cancel job id=$cancel_job" ;;
esac
[ "$(queue_state "$cancel_job")" = RUNNING ] || fail 'cancel job is not RUNNING'
grep -Eq '^record=ready .* node=ubuntu host=ubuntu2504 arch=x86_64 pid=[0-9]+ child_pid=[0-9]+ uid=3001 gid=3001$' \
	"${run_dir}/cancel.out" || fail 'Ubuntu cancel rank mismatch'
grep -Eq '^record=ready .* node=PC-210 host=PC-210\.local arch=arm64 pid=[0-9]+ child_pid=[0-9]+ uid=3001 gid=3001$' \
	"${run_dir}/cancel.out" || fail 'macOS cancel rank mismatch'

linux_pid=$(sed -n 's/^record=ready .* node=ubuntu .* pid=\([0-9][0-9]*\) .*/\1/p' \
	"${run_dir}/cancel.out")
mac_pid=$(sed -n 's/^record=ready .* node=PC-210 .* pid=\([0-9][0-9]*\) .*/\1/p' \
	"${run_dir}/cancel.out")
linux_child_pid=$(sed -n 's/^record=ready .* node=ubuntu .* child_pid=\([0-9][0-9]*\) .*/\1/p' \
	"${run_dir}/cancel.out")
mac_child_pid=$(sed -n 's/^record=ready .* node=PC-210 .* child_pid=\([0-9][0-9]*\) .*/\1/p' \
	"${run_dir}/cancel.out")
for pid in "$linux_pid" "$linux_child_pid" "$mac_pid" "$mac_child_pid"; do
	case "$pid" in
	''|*[!0-9]*) fail "invalid cancel pid=$pid" ;;
	esac
done

"$scancel" "$cancel_job" >"${run_dir}/scancel.out" \
	2>"${run_dir}/scancel.err" || fail 'cannot cancel mixed job'
wait "$cancel_client_pid"
cancel_client_rc=$?
cancel_client_pid=
case "$cancel_client_rc" in
1|130|137|143) ;;
*) fail "unexpected cancel client rc=$cancel_client_rc" ;;
esac
wait_job_gone "$cancel_job" || fail 'cancel job remained queued'
wait_accounting cancel "${run_dir}/cancel-accounting.txt" || \
	fail 'cancel accounting mismatch'
probe_pid_gone "$linux_node" "$linux_pid" "${run_dir}/probe-ubuntu.out" || \
	fail "Ubuntu payload pid=$linux_pid remains"
probe_pid_gone "$linux_node" "$linux_child_pid" \
	"${run_dir}/probe-ubuntu-child.out" || \
	fail "Ubuntu child pid=$linux_child_pid remains"
probe_pid_gone "$mac_node" "$mac_pid" "${run_dir}/probe-PC-210.out" || \
	fail "macOS payload pid=$mac_pid remains"
probe_pid_gone "$mac_node" "$mac_child_pid" \
	"${run_dir}/probe-PC-210-child.out" || \
	fail "macOS child pid=$mac_child_pid remains"
printf 'mixed_cancel=PASS job_id=%s client_rc=%s pids=%s,%s,%s,%s cleanup=PASS\n' \
	"$cancel_job" "$cancel_client_rc" "$linux_pid" "$linux_child_pid" \
	"$mac_pid" "$mac_child_pid"

for node in "$linux_node" "$mac_node"; do
	"$scontrol" show node "$node" >"${run_dir}/node-${node}-final.txt" || \
		fail "cannot read final node=$node"
	[ "$(node_field State "${run_dir}/node-${node}-final.txt")" = IDLE ] || \
		fail "final node=$node is not IDLE"
	[ "$(node_field CPUAlloc "${run_dir}/node-${node}-final.txt")" = 0 ] || \
		fail "final node=$node CPUAlloc is not zero"
	[ "$(node_field AllocMem "${run_dir}/node-${node}-final.txt")" = 0 ] || \
		fail "final node=$node AllocMem is not zero"
done
[ "$(node_field SlurmdStartTime "${run_dir}/node-${linux_node}-final.txt")" = \
	"$linux_start_before" ] || fail 'Ubuntu slurmd restarted during test'
[ "$(node_field SlurmdStartTime "${run_dir}/node-${mac_node}-final.txt")" = \
	"$mac_start_before" ] || fail 'macOS slurmd restarted during test'
[ -z "$("$squeue" -h -w "$linux_node,$mac_node")" ] || \
	fail 'target nodes have jobs after test'

success=1
trap - EXIT HUP INT TERM
printf 'SMD402_MIXED_ARCH_COMPLETE success_job=%s cancel_job=%s ranks=2 nodes=ubuntu:x86_64,PC-210:arm64 cancel_cleanup=PASS production_unchanged=PASS run_dir=%s\n' \
	"$success_job" "$cancel_job" "$run_dir"
