#!/bin/sh

set -u

mode=${1:-}
if [ "$mode" != run ] && [ "$mode" != finalize ]; then
	/usr/bin/printf 'usage: %s run|finalize\n' "$0" >&2
	exit 64
fi
if [ "${SMD406_IPV6_RUNTIME_CHANGE_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD406_IPV6_RUNTIME_CHANGE_CONFIRMED=YES after approving the temporary IPv6 runtime change' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
slurm_key=${prefix}/etc/slurm.key
slurmd=${prefix}/sbin/slurmd
libslurmfull=${prefix}/lib/slurm/libslurmfull.dylib
wire_af_fix_hash=b037119a9187a189b6ba3a1efbd2b733f5f62802af6bd51f3ae8f0a3e5765d8c
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
srun=${prefix}/bin/srun
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
sacctmgr=${prefix}/bin/sacctmgr
mlx_job=${prefix}/share/macos-gpu-job/mlx_gpu_smoke.sbatch
plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_target=system/org.schedmd.slurmd
pid_file=/var/run/slurmd.pid
state_file=${prefix}/.smd406-ipv6-runtime.env
interface=en0
controller_ipv6=fd40:534d:4406:1::180
worker_ipv6=fd40:534d:4406:1::128
prefix_length=64
node_name=PC-210
peer_node=ubuntu
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd406-mac-runtime-${mode}-${run_stamp}
output_dir=${run_dir}/job-output
success=0
address_added=0
config_installed=0
tcpdump_pid=
active_job=
cpu_job=
gpu_job=
srun_job=

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
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null | /usr/bin/awk 'NR == 1 { print; exit }'
}

launchd_pid()
{
	/bin/launchctl print "$service_target" 2>/dev/null |
		/usr/bin/awk '/pid =/ { print $3; exit }'
}

is_running()
{
	case "$1" in
	''|*[!0-9]*) return 1 ;;
	esac
	/bin/kill -0 "$1" >/dev/null 2>&1
}

wait_process_stop()
{
	old_pid=$1
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		is_running "$old_pid" || return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_service_unloaded()
{
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		/bin/launchctl print "$service_target" >/dev/null 2>&1 || return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

restart_launchd()
{
	label=$1
	old_pid=$(launchd_pid)
	/bin/launchctl bootout "$service_target" >"${run_dir}/${label}-bootout.out" \
		2>"${run_dir}/${label}-bootout.err" || return 1
	wait_process_stop "$old_pid" || return 1
	wait_service_unloaded || return 1
	/bin/launchctl enable "$service_target" >/dev/null 2>&1 || return 1
	/bin/launchctl bootstrap system "$plist" >"${run_dir}/${label}-bootstrap.out" \
		2>"${run_dir}/${label}-bootstrap.err" || return 1
	return 0
}

wait_node_idle()
{
	label=$1
	old_pid=$2
	attempt=0
	while [ "$attempt" -lt 240 ]; do
		"$scontrol" show node "$node_name" >"${run_dir}/${label}-node.txt" \
			2>"${run_dir}/${label}-node.err" || true
		state=$(node_field State "${run_dir}/${label}-node.txt")
		pid=$(launchd_pid)
		if [ "$state" = IDLE ] && [ -n "$pid" ] && [ "$pid" != "$old_pid" ] && \
			is_running "$pid"; then
			/usr/bin/printf 'node_idle phase=%s pid=%s wait_seconds=%s\n' \
				"$label" "$pid" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

atomic_install()
{
	source_file=$1
	target_file=$2
	reference_file=$3
	tmp_file=${target_file}.smd406.$$
	owner=$(/usr/bin/stat -f '%Su' "$reference_file") || return 1
	group=$(/usr/bin/stat -f '%Sg' "$reference_file") || return 1
	file_mode=$(/usr/bin/stat -f '%Lp' "$reference_file") || return 1
	if ! /usr/bin/install -o "$owner" -g "$group" -m "$file_mode" \
		"$source_file" "$tmp_file"; then
		/bin/rm -f "$tmp_file"
		return 1
	fi
	if ! /bin/mv -f "$tmp_file" "$target_file"; then
		/bin/rm -f "$tmp_file"
		return 1
	fi
}

build_candidate()
{
	source_file=$1
	target_file=$2
	/usr/bin/awk -v controller="$controller_ipv6" -v worker="$worker_ipv6" '
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

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 240 ]; do
		if [ -z "$(queue_state "$job_id")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' "$job_id" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

accounting_complete()
{
	job_id=$1
	step_kind=$2
	expect_gpu=$3
	file=$4
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES%200,AllocTRES%200 \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" \
		-v step="$step_kind" -v gpu="$expect_gpu" '
	function has(value, item, n, fields, i) {
		n = split(value, fields, ",")
		for (i = 1; i <= n; i++) if (fields[i] == item) return 1
		return 0
	}
	$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" && $5 == "PC-210" {
		job_ok = 1
		if (!gpu || (has($6, "gres/gpu=1") && has($6, "gres/gpu:apple=1") &&
			has($7, "gres/gpu=1") && has($7, "gres/gpu:apple=1"))) gpu_ok = 1
	}
	$1 == job "." step && $3 == "COMPLETED" && $4 == "0:0" { step_ok = 1 }
	END { exit !(job_ok && step_ok && gpu_ok) }
	' "$file"
}

wait_accounting()
{
	job_id=$1
	step_kind=$2
	expect_gpu=$3
	file=$4
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		accounting_complete "$job_id" "$step_kind" "$expect_gpu" "$file" && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

cancel_active()
{
	[ -n "$active_job" ] || return 0
	state=$(queue_state "$active_job")
	[ -z "$state" ] || "$scancel" "$active_job" >/dev/null 2>&1 || true
	active_job=
}

stop_tcpdump()
{
	[ -n "$tcpdump_pid" ] || return 0
	if is_running "$tcpdump_pid"; then
		/bin/kill -INT "$tcpdump_pid" >/dev/null 2>&1 || true
	fi
	wait "$tcpdump_pid" 2>/dev/null || true
	tcpdump_pid=
}

write_state()
{
	phase_value=$1
	tmp_file=${state_file}.tmp.$$
	{
		/usr/bin/printf 'runtime_run_dir=%s\n' "$run_dir"
		/usr/bin/printf 'interface=%s\n' "$interface"
		/usr/bin/printf 'controller_ipv6=%s\n' "$controller_ipv6"
		/usr/bin/printf 'worker_ipv6=%s\n' "$worker_ipv6"
		/usr/bin/printf 'prefix_length=%s\n' "$prefix_length"
		/usr/bin/printf 'phase=%s\n' "$phase_value"
	} >"$tmp_file" || return 1
	/bin/chmod 0600 "$tmp_file" || return 1
	/bin/mv -f "$tmp_file" "$state_file" || return 1
}

restore_local_config()
{
	[ "$config_installed" -eq 1 ] || return 0
	old_pid=$(launchd_pid)
	atomic_install "${run_dir}/slurm.conf.before" "$slurm_conf" \
		"${run_dir}/slurm.conf.before" || return 1
	restart_launchd local-restore || return 1
	wait_node_idle local-restore "$old_pid" || return 1
	config_installed=0
	return 0
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	runtime_change_started=0
	if [ "$config_installed" -eq 1 ] || [ "$address_added" -eq 1 ]; then
		runtime_change_started=1
	fi
	cancel_active
	stop_tcpdump
	if [ "$success" -ne 1 ] && [ "$mode" = run ]; then
		if ! restore_local_config; then
			/usr/bin/printf 'fatal recovery: local slurm.conf or launchd restore failed; backup=%s\n' \
				"${run_dir}/slurm.conf.before" >&2
			rc=1
		fi
		if [ "$address_added" -eq 1 ]; then
			write_state FAILED_LOCAL_RESTORED_ULA_ACTIVE >/dev/null 2>&1 || true
		fi
		if [ "$runtime_change_started" -eq 1 ]; then
			/usr/bin/printf 'recovery: local config restore attempted; Mac ULA is retained until Ubuntu restore; inspect run_dir=%s state=%s\n' \
				"$run_dir" "$state_file" >&2
			/usr/bin/printf '%s\n' \
				'NEXT_ON_UBUNTU_RECOVERY: after confirming the Mac local config is restored and the node is IDLE, set SMD406_MAC_LOCAL_RECOVERY_READY=YES and run Ubuntu restore' >&2
		else
			/usr/bin/printf 'preflight: stopped before network/config/daemon/job mutation; run_dir=%s\n' \
				"$run_dir" >&2
		fi
	elif [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: finalize did not complete; inspect run_dir=%s state=%s\n' \
			"$run_dir" "$state_file" >&2
	fi
	exit "$rc"
}

trap cleanup EXIT HUP INT TERM

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'
for required in "$slurm_conf" "$gres_conf" "$slurm_key" "$slurmd" "$libslurmfull" "$scontrol" \
	"$squeue" "$sbatch" "$srun" "$scancel" "$sacct" "$sacctmgr" "$mlx_job" \
	"$plist" "$pid_file"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_path in /sbin/ifconfig /usr/bin/awk /usr/bin/cmp /usr/bin/grep \
	/usr/bin/env /usr/bin/install /usr/bin/nc /usr/bin/shasum /usr/bin/stat \
	/usr/bin/sudo /usr/sbin/chown /usr/sbin/lsof /usr/sbin/tcpdump /bin/cat \
	/bin/chmod /bin/cp /bin/date /bin/kill /bin/launchctl /bin/mkdir /bin/mv \
	/bin/rm /bin/sleep; do
	[ -x "$command_path" ] || fail "required command is not executable: $command_path"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'
[ "$(/usr/bin/shasum -a 256 "$libslurmfull" | /usr/bin/awk '{ print $1 }')" = \
	"$wire_af_fix_hash" ] || fail 'production libslurmfull lacks the wire AF fix'
umask 077
/bin/mkdir "$run_dir" || fail 'cannot create run directory'
/bin/chmod 0755 "$run_dir" || fail 'cannot make run directory traversable by testuser'
/usr/bin/printf 'mode=%s run_dir=%s controller=%s worker=%s\n' \
	"$mode" "$run_dir" "$controller_ipv6" "$worker_ipv6"
export SLURM_CONF="$slurm_conf"

case "$mode" in
run)
	[ ! -e "$state_file" ] || fail "active Mac runtime state already exists: $state_file"
	current_launchd_pid=$(launchd_pid)
	current_pid_file=$(/bin/cat "$pid_file")
	[ -n "$current_launchd_pid" ] && [ "$current_launchd_pid" = "$current_pid_file" ] && \
		is_running "$current_launchd_pid" || fail 'launchd and pidfile slurmd identity mismatch'
	[ -z "$("$squeue" -h -w "$node_name,$peer_node")" ] || fail 'target nodes have active jobs'
	if /sbin/ifconfig "$interface" | /usr/bin/grep -Fq "inet6 ${worker_ipv6} "; then
		fail 'temporary Mac ULA already exists'
	fi
	/bin/cp -p "$slurm_conf" "${run_dir}/slurm.conf.before" || fail 'cannot back up slurm.conf'
	/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurmd" "$libslurmfull" "$plist" \
		>"${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'
	build_candidate "$slurm_conf" "${run_dir}/slurm.conf.ipv6" || fail 'cannot build IPv6 config'
	/bin/cp "$gres_conf" "${run_dir}/gres.conf" || fail 'cannot stage candidate gres.conf'
	"$slurmd" -C -N "$node_name" -f "${run_dir}/slurm.conf.ipv6" \
		>"${run_dir}/candidate-C.out" 2>"${run_dir}/candidate-C.err" || \
		fail 'candidate slurmd -C failed'
	SLURM_SACK_KEY="$slurm_key" "$slurmd" -G -f "${run_dir}/slurm.conf.ipv6" \
		>"${run_dir}/candidate-G.out" 2>"${run_dir}/candidate-G.err" || \
		fail 'candidate slurmd -G failed'

	/sbin/ifconfig "$interface" inet6 "$worker_ipv6" prefixlen "$prefix_length" alias || \
		fail 'cannot add temporary Mac ULA'
	address_added=1
	/bin/sleep 2
	/usr/bin/nc -6 -vz -w 3 "$controller_ipv6" 6817 \
		>"${run_dir}/controller-6817.out" 2>"${run_dir}/controller-6817.err" || \
		fail 'controller IPv6 port 6817 is unreachable'
	/usr/bin/nc -6 -vz -w 3 "$controller_ipv6" 6819 \
		>"${run_dir}/controller-6819.out" 2>"${run_dir}/controller-6819.err" || \
		fail 'slurmdbd IPv6 port 6819 is unreachable'

	/usr/sbin/tcpdump -n -l -tttt -i "$interface" \
		'ip6 and (tcp port 6817 or tcp port 6818 or tcp port 6819)' \
		>"${run_dir}/ipv6-packets.txt" 2>"${run_dir}/tcpdump.err" &
	tcpdump_pid=$!
	/bin/sleep 1
	is_running "$tcpdump_pid" || fail 'tcpdump observer failed to start'

	old_pid=$(launchd_pid)
	atomic_install "${run_dir}/slurm.conf.ipv6" "$slurm_conf" "$slurm_conf" || \
		fail 'cannot install IPv6 slurm.conf'
	config_installed=1
	restart_launchd ipv6 || fail 'cannot restart slurmd with IPv6 config'
	wait_node_idle ipv6 "$old_pid" || fail 'Mac node did not become IDLE with IPv6 config'
	ipv6_pid=$(launchd_pid)
	/usr/sbin/lsof -nP -a -p "$ipv6_pid" -iTCP:6818 -sTCP:LISTEN \
		>"${run_dir}/slurmd-6818-listener.txt" 2>"${run_dir}/slurmd-6818-listener.err" || \
		fail 'cannot inspect slurmd listener'
	/usr/bin/grep -Fq 'IPv6' "${run_dir}/slurmd-6818-listener.txt" || \
		fail 'slurmd listener is not IPv6'
	"$sacctmgr" ping >"${run_dir}/sacctmgr-ping.txt" 2>"${run_dir}/sacctmgr-ping.err" || \
		fail 'slurmdbd ping over IPv6 config failed'
	/usr/bin/grep -q ' is UP$' "${run_dir}/sacctmgr-ping.txt" || fail 'slurmdbd is not UP'

	/bin/mkdir "$output_dir" || fail 'cannot create output directory'
	/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
	/bin/chmod 0700 "$output_dir" || fail 'cannot protect output directory'
	/usr/bin/printf '%s\n' '#!/bin/sh' \
		'printf "job_id=%s node=%s uid=%s gid=%s\\n" "$SLURM_JOB_ID" "$(/bin/hostname)" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)"' \
		>"${run_dir}/cpu.sh" || fail 'cannot write CPU payload'
	/bin/chmod 0755 "${run_dir}/cpu.sh" || fail 'cannot make CPU payload executable'
	active_job=$(/usr/bin/sudo -u "$test_user" -H /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodelist="$node_name" \
		--nodes=1 --ntasks=1 --cpus-per-task=1 --mem=64M --time=00:01:00 \
		--chdir=/tmp --output="${output_dir}/cpu-%j.out" \
		--error="${output_dir}/cpu-%j.err" "${run_dir}/cpu.sh") || fail 'CPU sbatch failed'
	cpu_job=$active_job
	/usr/bin/printf 'submitted cpu_job=%s\n' "$cpu_job"
	wait_job_gone "$cpu_job" || fail 'CPU job remained in queue'
	wait_accounting "$cpu_job" batch 0 "${run_dir}/cpu-accounting.txt" || \
		fail 'CPU job accounting mismatch'
	/usr/bin/awk -v job="$cpu_job" -v uid="$test_uid" -v gid="$test_gid" '
	$1 == "job_id=" job && $2 ~ /^node=PC-210([.]local)?$/ &&
	$3 == "uid=" uid && $4 == "gid=" gid { ok = 1 }
	END { exit !ok }
	' "${output_dir}/cpu-${cpu_job}.out" || fail 'CPU job output mismatch'
	active_job=

	/usr/bin/printf '%s\n' '#!/bin/sh' \
		'printf "job_id=%s step_id=%s node=%s uid=%s gid=%s\\n" "$SLURM_JOB_ID" "$SLURM_STEP_ID" "$(/bin/hostname)" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)"' \
		>"${run_dir}/srun.sh" || fail 'cannot write srun payload'
	/bin/chmod 0755 "${run_dir}/srun.sh" || fail 'cannot make srun payload executable'
	/usr/bin/sudo -u "$test_user" -H /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$srun" --job-name=smd406-v6-srun --partition="$partition" \
		--nodelist="$node_name" --nodes=1 --ntasks=1 --cpus-per-task=1 --mem=64M \
		--time=00:01:00 --chdir=/tmp "${run_dir}/srun.sh" \
		>"${run_dir}/srun.out" 2>"${run_dir}/srun.err" || fail 'direct srun failed'
	srun_job=$(/usr/bin/awk -F '[ =]' '/^job_id=/ { print $2; exit }' "${run_dir}/srun.out")
	case "$srun_job" in
	''|*[!0-9]*) fail "invalid direct srun job id=$srun_job" ;;
	esac
	/usr/bin/awk -v job="$srun_job" -v uid="$test_uid" -v gid="$test_gid" '
	$1 == "job_id=" job && $2 == "step_id=0" &&
	$3 ~ /^node=PC-210([.]local)?$/ && $4 == "uid=" uid && $5 == "gid=" gid { ok = 1 }
	END { exit !ok }
	' "${run_dir}/srun.out" || fail 'direct srun output mismatch'
	wait_accounting "$srun_job" 0 0 "${run_dir}/srun-accounting.txt" || \
		fail 'direct srun accounting mismatch'

	active_job=$(/usr/bin/sudo -u "$test_user" -H /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodelist="$node_name" \
		--gres=gpu:apple:1 \
		--output="${output_dir}/gpu-%j.out" --error="${output_dir}/gpu-%j.err" \
		"$mlx_job") || fail 'GPU sbatch failed'
	gpu_job=$active_job
	/usr/bin/printf 'submitted gpu_job=%s\n' "$gpu_job"
	wait_job_gone "$gpu_job" || fail 'GPU job remained in queue'
	wait_accounting "$gpu_job" batch 1 "${run_dir}/gpu-accounting.txt" || \
		fail 'GPU job accounting mismatch'
	/usr/bin/grep -Fqx 'gpu_smoke_test=PASS' "${output_dir}/gpu-${gpu_job}.out" || \
		fail 'GPU smoke marker missing'
	active_job=

	stop_tcpdump
	/usr/bin/grep -Fq "$worker_ipv6" "${run_dir}/ipv6-packets.txt" || \
		fail 'packet evidence lacks Mac ULA'
	/usr/bin/grep -Fq "$controller_ipv6" "${run_dir}/ipv6-packets.txt" || \
		fail 'packet evidence lacks Ubuntu ULA'
	for port in 6817 6818 6819; do
		/usr/bin/grep -Eq "\.${port}([: >]|$)" "${run_dir}/ipv6-packets.txt" || \
			fail "packet evidence lacks IPv6 Slurm port=$port"
	done

	restore_local_config || fail 'cannot restore local config after IPv6 tests'
	/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurmd" "$libslurmfull" "$plist" \
		>"${run_dir}/production-local-restored.sha256" || fail 'cannot hash restored production'
	/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
		"${run_dir}/production-local-restored.sha256" || fail 'local production hashes not restored'
	write_state TEST_COMPLETE_LOCAL_CONFIG_RESTORED_ULA_ACTIVE || \
		fail 'cannot write Mac runtime state'
	success=1
	/usr/bin/printf 'SMD406_MAC_IPV6_RUNTIME_COMPLETE cpu_job=%s srun_job=%s gpu_job=%s ipv6_packets=PASS local_config_restored=PASS mac_ula=ACTIVE slurmd_pid=%s state=%s run_dir=%s\n' \
		"$cpu_job" "$srun_job" "$gpu_job" "$(launchd_pid)" "$state_file" "$run_dir"
	/usr/bin/printf '%s\n' \
		'NEXT_ON_UBUNTU: run smd406_ubuntu_ipv6_runtime_control.sh restore before Mac finalize'
	;;
finalize)
	[ "${SMD406_UBUNTU_RUNTIME_RESTORED:-}" = YES ] || \
		fail 'set SMD406_UBUNTU_RUNTIME_RESTORED=YES only after the Ubuntu restore marker'
	[ -f "$state_file" ] || fail "missing Mac runtime state=$state_file"
	[ "$(/usr/bin/stat -f '%Su:%Lp' "$state_file")" = root:600 ] || \
		fail 'Mac runtime state owner/mode mismatch'
	. "$state_file"
	case "${runtime_run_dir:-}" in
	/tmp/slurm-smd406-mac-runtime-run-*) ;;
	*) fail "invalid saved runtime_run_dir=${runtime_run_dir:-}" ;;
	esac
	case "${phase:-}" in
	TEST_COMPLETE_LOCAL_CONFIG_RESTORED_ULA_ACTIVE)
		final_classification=RUNTIME_PASS
		;;
	FAILED_LOCAL_RESTORED_ULA_ACTIVE)
		final_classification=RECOVERY_ONLY
		;;
	*) fail "unexpected Mac runtime phase=${phase:-}" ;;
	esac
	"$scontrol" ping >"${runtime_run_dir}/final-controller-ping.txt" 2>&1 || \
		fail 'restored IPv4 controller is not reachable'
	"$scontrol" show config >"${runtime_run_dir}/final-controller-config.txt" || \
		fail 'cannot read restored controller config'
	if /usr/bin/grep -Eq '^CommunicationParameters[[:space:]]*=.*EnableIPv6' \
		"${runtime_run_dir}/final-controller-config.txt"; then
		fail 'controller still has EnableIPv6; do not remove Mac ULA'
	fi
	if /sbin/ifconfig "$interface" | /usr/bin/grep -Fq "inet6 ${worker_ipv6} "; then
		/sbin/ifconfig "$interface" inet6 "$worker_ipv6" -alias || \
			fail 'cannot remove temporary Mac ULA'
		ula_remove_state=REMOVED
	else
		ula_remove_state=ALREADY_ABSENT
	fi
	if /sbin/ifconfig "$interface" | /usr/bin/grep -Fq "inet6 ${worker_ipv6} "; then
		fail 'temporary Mac ULA remains after finalize'
	fi
	"$scontrol" show node "$node_name" >"${runtime_run_dir}/final-node.txt" || \
		fail 'cannot read final Mac node'
	[ "$(node_field State "${runtime_run_dir}/final-node.txt")" = IDLE ] || fail 'final Mac node is not IDLE'
	[ -z "$("$squeue" -h -w "$node_name,$peer_node")" ] || fail 'final target queue is not empty'
	final_output_dir=${runtime_run_dir}/final-output-${run_stamp}
	/bin/mkdir "$final_output_dir" || fail 'cannot create final smoke output directory'
	/usr/sbin/chown "$test_uid:$test_gid" "$final_output_dir" || \
		fail 'cannot chown final smoke output directory'
	/bin/chmod 0700 "$final_output_dir" || fail 'cannot protect final smoke output directory'
	final_smoke_script=${runtime_run_dir}/final-smoke-${run_stamp}.sh
	/usr/bin/printf '%s\n' '#!/bin/sh' \
		'printf "job_id=%s node=%s uid=%s gid=%s\\n" "$SLURM_JOB_ID" "$(/bin/hostname)" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)"' \
		>"$final_smoke_script" || fail 'cannot write final smoke payload'
	/bin/chmod 0755 "$final_smoke_script" || \
		fail 'cannot make final smoke payload executable'
	active_job=$(/usr/bin/sudo -u "$test_user" -H /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodelist="$node_name" \
		--nodes=1 --ntasks=1 --cpus-per-task=1 --mem=64M --time=00:01:00 \
		--chdir=/tmp --output="${final_output_dir}/smoke-%j.out" \
		--error="${final_output_dir}/smoke-%j.err" \
		"$final_smoke_script") || fail 'final IPv4 smoke submission failed'
	final_smoke_job=$active_job
	/usr/bin/printf 'submitted final_smoke_job=%s\n' "$final_smoke_job"
	wait_job_gone "$final_smoke_job" || fail 'final IPv4 smoke job remained in queue'
	wait_accounting "$final_smoke_job" batch 0 \
		"${runtime_run_dir}/final-smoke-accounting.txt" || \
		fail 'final IPv4 smoke accounting mismatch'
	/usr/bin/awk -v job="$final_smoke_job" -v uid="$test_uid" -v gid="$test_gid" '
	$1 == "job_id=" job && $2 ~ /^node=PC-210([.]local)?$/ &&
	$3 == "uid=" uid && $4 == "gid=" gid { ok = 1 }
	END { exit !ok }
	' "${final_output_dir}/smoke-${final_smoke_job}.out" || \
		fail 'final IPv4 smoke output mismatch'
	active_job=
	/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurmd" "$libslurmfull" "$plist" \
		>"${runtime_run_dir}/production-final.sha256" || fail 'cannot hash final production'
	/usr/bin/cmp -s "${runtime_run_dir}/production-before.sha256" \
		"${runtime_run_dir}/production-final.sha256" || fail 'final production hashes differ'
	/bin/rm -f "$state_file"
	success=1
	/usr/bin/printf 'SMD406_MAC_IPV6_FINALIZE_COMPLETE classification=%s mac_ula=%s node_state=IDLE queue=EMPTY final_ipv4_smoke_job=%s production_restored=PASS slurmd_pid=%s run_dir=%s\n' \
		"$final_classification" "$ula_remove_state" "$final_smoke_job" \
		"$(launchd_pid)" "$runtime_run_dir"
	;;
esac
