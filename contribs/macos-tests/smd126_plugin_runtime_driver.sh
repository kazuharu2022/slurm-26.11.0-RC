#!/bin/sh

set -u

if [ "${SMD126_PLUGIN_RUNTIME_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD126_PLUGIN_RUNTIME_CONFIRMED=YES after confirming PC-210 is idle' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
slurmd_log=/var/log/slurm/slurmd.log
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd126-runtime-${run_stamp}
output_dir=${run_dir}/output
client_conf=${run_dir}/slurm-client.conf
step_payload=${run_dir}/step-payload.sh
gres_payload=${run_dir}/gres-payload.sh
step_job=
gres_job=
slurmd_pid=
log_size_before=0
success=0

export SLURM_CONF="$slurm_conf"

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

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }'
}

cancel_if_active()
{
	job_id=$1
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state" >&2
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ -z "$(queue_state "$job_id")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' \
				"$job_id" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

accounting_complete_step()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { job_ok = 1 }
		$1 == job ".0" && $3 == "COMPLETED" && $4 == "0:0" { step_ok = 1 }
		END { exit !(job_ok && step_ok) }
	' "$file"
}

accounting_complete_batch()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,AllocTRES \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { job_ok = 1 }
		$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" { batch_ok = 1 }
		END { exit !(job_ok && batch_ok) }
	' "$file"
}

wait_accounting()
{
	kind=$1
	job_id=$2
	file=$3
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if [ "$kind" = step ]; then
			accounting_complete_step "$job_id" "$file" && return 0
		else
			accounting_complete_batch "$job_id" "$file" && return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$step_job"
	cancel_if_active "$gres_job"
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: no production configuration was changed; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$scontrol" "$squeue" "$srun" \
	"$sbatch" "$scancel" "$sacct" "$pid_file" "$slurmd_log"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done
for command in /usr/bin/awk /usr/bin/dscacheutil /usr/bin/grep \
	/usr/bin/id /usr/bin/pgrep /usr/bin/sed /usr/bin/shasum \
	/usr/bin/sort /usr/bin/sudo /usr/bin/tail /usr/bin/tr /usr/bin/wc \
	/usr/sbin/chown /usr/sbin/ipconfig /bin/cat /bin/chmod /bin/date \
	/bin/kill /bin/mkdir /bin/ps; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'

/bin/cat >"$step_payload" <<'EOF'
#!/bin/sh
/usr/bin/printf 'record=step job_id=%s step_id=%s procid=%s localid=%s uid=%s gid=%s node=%s\n' \
	"${SLURM_JOB_ID:-unset}" "${SLURM_STEP_ID:-unset}" \
	"${SLURM_PROCID:-unset}" "${SLURM_LOCALID:-unset}" \
	"$(/usr/bin/id -u)" "$(/usr/bin/id -g)" "$(/bin/hostname)"
exit 0
EOF
/bin/cat >"$gres_payload" <<'EOF'
#!/bin/sh
/usr/bin/printf 'record=gres job_id=%s uid=%s gid=%s job_gpus=%s node=%s\n' \
	"${SLURM_JOB_ID:-unset}" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)" \
	"${SLURM_JOB_GPUS:-unset}" "$(/bin/hostname)"
exit 0
EOF
/bin/chmod 0555 "$step_payload" "$gres_payload" || fail 'cannot set payload modes'
/usr/sbin/chown 0:0 "$step_payload" "$gres_payload" || fail 'cannot set payload owners'
/usr/bin/printf 'run_dir=%s\n' "$run_dir"

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
/usr/bin/grep -Fq 'Gres=gpu:apple:1' "${run_dir}/node-before.txt" || fail 'gpu:apple:1 is not registered'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail "slurmd pid=$slurmd_pid is not running"

node_ipv4=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || true)
case "$node_ipv4" in
''|*[!0-9.]*) fail "invalid en0 IPv4 address=$node_ipv4" ;;
esac
/usr/bin/dscacheutil -q host -a name "${node_name}.local" \
	>"${run_dir}/node-address-readback.txt" 2>"${run_dir}/node-address-readback.err" || \
	fail "cannot resolve ${node_name}.local"
/usr/bin/grep -Fqx "ip_address: ${node_ipv4}" "${run_dir}/node-address-readback.txt" || \
	fail "${node_name}.local does not resolve to en0 address $node_ipv4"

/usr/bin/awk -v node="$node_name" -v addr="$node_ipv4" '
	$1 == "NodeName=" node {
		for (i = 1; i <= NF; i++) if ($i ~ /^NodeAddr=/) found_addr = 1
		if (!found_addr) $0 = $0 " NodeAddr=" addr
		found_node = 1
	}
	{ print }
	END { if (!found_node) exit 1 }
' "$slurm_conf" >"$client_conf" || fail 'cannot create numeric NodeAddr client config'
/bin/chmod 0644 "$client_conf" || fail 'cannot set client config mode'
/usr/bin/shasum -a 256 "$slurm_conf" >"${run_dir}/production-config.sha256"
/usr/bin/shasum -a 256 "$client_conf" >"${run_dir}/client-config.sha256"
log_size_before=$(/usr/bin/wc -c <"$slurmd_log" | /usr/bin/tr -d ' ')
case "$log_size_before" in
''|*[!0-9]*) fail "invalid initial log size=$log_size_before" ;;
esac

/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env \
	SLURM_CONF="$client_conf" \
	"$srun" --partition="$partition" --nodes=1 --ntasks=2 \
	--cpus-per-task=1 --mem=256M --time=00:01:00 --chdir=/tmp \
	--mpi=none --job-name=smd126-step "$step_payload" \
	>"${run_dir}/srun.out" 2>"${run_dir}/srun.err"
srun_rc=$?
/usr/bin/printf 'step_srun_rc=%s\n' "$srun_rc"
[ "$srun_rc" -eq 0 ] || fail "runtime srun failed rc=$srun_rc"

step_job=$(/usr/bin/awk '
	$1 == "record=step" {
		for (i = 1; i <= NF; i++) if ($i ~ /^job_id=/) {
			sub(/^job_id=/, "", $i); print $i
		}
	}' "${run_dir}/srun.out" | /usr/bin/sort -u)
case "$step_job" in
''|*[!0-9]*) fail "invalid or non-unique step job id=$step_job" ;;
esac
[ "$(/usr/bin/grep -c '^record=step ' "${run_dir}/srun.out")" = 2 ] || \
	fail 'step payload count is not 2'
for proc_id in 0 1; do
	/usr/bin/grep -Eq \
		"^record=step job_id=${step_job} step_id=0 procid=${proc_id} localid=${proc_id} uid=${test_uid} gid=${test_gid} node=" \
		"${run_dir}/srun.out" || fail "step payload mismatch procid=$proc_id"
done
wait_job_gone "$step_job" || fail 'step job remained in queue'
wait_accounting step "$step_job" "${run_dir}/step-sacct.txt" || \
	fail 'step job accounting did not reach COMPLETED 0:0'
/usr/bin/printf 'step_runtime=PASS job_id=%s tasks=2 mpi=none identity=%s:%s\n' \
	"$step_job" "$test_uid" "$test_gid"

gres_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=256M --gres=gpu:apple:1 --time=00:01:00 \
		--chdir=/tmp --job-name=smd126-gres \
		--output="${output_dir}/gres-%j.out" --error="${output_dir}/gres-%j.err" \
		"$gres_payload"
) || fail 'GRES batch submission failed'
gres_job=${gres_job%%;*}
case "$gres_job" in
''|*[!0-9]*) fail "invalid GRES job id=$gres_job" ;;
esac
/usr/bin/printf 'submitted gres_job=%s\n' "$gres_job"
wait_job_gone "$gres_job" || fail 'GRES job remained in queue'
wait_accounting batch "$gres_job" "${run_dir}/gres-sacct.txt" || \
	fail 'GRES job accounting did not reach COMPLETED 0:0'
/usr/bin/grep -Eq \
	"^record=gres job_id=${gres_job} uid=${test_uid} gid=${test_gid} job_gpus=0 node=" \
	"${output_dir}/gres-${gres_job}.out" || fail 'GRES payload environment mismatch'
[ ! -s "${output_dir}/gres-${gres_job}.err" ] || fail 'GRES payload stderr is not empty'
/usr/bin/printf 'gres_runtime=PASS job_id=%s resource=gpu:apple:1 job_gpus=0 identity=%s:%s\n' \
	"$gres_job" "$test_uid" "$test_gid"

log_size_after=$(/usr/bin/wc -c <"$slurmd_log" | /usr/bin/tr -d ' ')
case "$log_size_after" in
''|*[!0-9]*) fail "invalid final log size=$log_size_after" ;;
esac
[ "$log_size_after" -ge "$log_size_before" ] || fail 'slurmd log rotated during SMD-126 Phase B'
/usr/bin/tail -c "+$((log_size_before + 1))" "$slurmd_log" \
	>"${run_dir}/slurmd-log-delta.txt"
loader_pattern='symbol not found|Couldn.t load specified plugin|Dlopen of plugin file failed|cannot create .* context|failed to initialize .* plugin'
/usr/bin/grep -Ein "$loader_pattern" "${run_dir}/srun.err" \
	"${output_dir}/gres-${gres_job}.err" "${run_dir}/slurmd-log-delta.txt" \
	>"${run_dir}/loader-errors.txt" || true
loader_error_count=$(/usr/bin/wc -l <"${run_dir}/loader-errors.txt" | /usr/bin/tr -d ' ')
[ "$loader_error_count" -eq 0 ] || fail "plugin loader errors=$loader_error_count"

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final node queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed during runtime test'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-after.txt" 2>/dev/null; then
	fail 'slurmstepd remains after jobs completed'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-after.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-after.txt" \
	>"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'test payload process remains'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD126_PHASE_B_COMPLETE step_job=%s gres_job=%s loader_errors=0 slurmd_pid=%s run_dir=%s\n' \
	"$step_job" "$gres_job" "$slurmd_pid" "$run_dir"
