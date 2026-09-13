#!/bin/sh

set -u

mode=${1:-}
case "$mode" in
run|finalize) ;;
*) /usr/bin/printf 'usage: %s run|finalize\n' "$0" >&2; exit 64 ;;
esac
if [ "${SMD407_TLS_RUNTIME_CHANGE_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD407_TLS_RUNTIME_CHANGE_CONFIRMED=YES after approving the coordinated TLS runtime change' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
slurm_key=${prefix}/etc/slurm.key
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
srun=${prefix}/bin/srun
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
plugin=${prefix}/lib/slurm/tls_s2n.so
s2n_prefix=${prefix}/lib/slurm-s2n-1.7.9
ca=${prefix}/etc/ca_cert.pem
slurmd_cert=${prefix}/etc/slurmd_cert.pem
slurmd_key=${prefix}/etc/slurmd_cert_key.pem
inactive_state=${prefix}/.smd407-mac-tls-inactive.env
runtime_state=${prefix}/.smd407-mac-tls-runtime.env
plugin_hash=f1b17c47b94c6ea3a86478a4f35493b30dff1f2d0941a45490e63381dd23cfa3
libs2n_hash=b0d957ad211cdeaaa996795b04c2dbe3238575b1b37f17719758b75c434c894a
service_target=system/org.schedmd.slurmd
pid_file=/var/run/slurmd.pid
mlx_job=${prefix}/share/macos-gpu-job/mlx_gpu_smoke.sbatch
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-mac-tls-runtime-${mode}-${run_stamp}
output_dir=${run_dir}/job-output
success=0
config_installed=0
local_restored=0
active_job=
cpu_job=
srun_job=
gpu_job=
mixed_job=

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

state_value()
{
	key=$1
	file=$2
	/usr/bin/awk -F= -v wanted="$key" \
		'$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null | /usr/bin/awk 'NR == 1 { print; exit }'
}

is_running()
{
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	/bin/kill -0 "$1" >/dev/null 2>&1
}

managed_slurmd_pid()
{
	[ -f "$pid_file" ] || return 1
	candidate=$(/bin/cat "$pid_file")
	is_running "$candidate" || return 1
	/bin/launchctl procinfo "$candidate" 2>/dev/null | \
		/usr/bin/grep -Fq "$service_target = {" || return 1
	/usr/bin/printf '%s\n' "$candidate"
}

restart_launchd()
{
	label=$1
	old_pid=$(managed_slurmd_pid) || return 1
	/bin/launchctl kickstart -k "$service_target" \
		>"${run_dir}/${label}-kickstart.out" 2>"${run_dir}/${label}-kickstart.err" || return 1
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		new_pid=$(managed_slurmd_pid 2>/dev/null || true)
		if [ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ]; then
			/usr/bin/printf 'slurmd_restarted phase=%s old_pid=%s new_pid=%s wait_seconds=%s\n' \
				"$label" "$old_pid" "$new_pid" "$attempt"
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
	tmp_file=${target_file}.smd407.$$
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
	/usr/bin/awk -v prefix="$prefix" '
	/^[[:space:]]*CommunicationParameters=/ {
		if (tolower($0) !~ /disable_http/) $0 = $0 ",disable_http"
		seen_communication = 1
		print
		next
	}
	{ print }
	END {
		if (!seen_communication) print "CommunicationParameters=disable_http"
		print "TLSType=tls/s2n"
		print "TLSParameters=ca_cert_file=" prefix "/etc/ca_cert.pem,slurmd_cert_file=" prefix "/etc/slurmd_cert.pem,slurmd_cert_key_file=" prefix "/etc/slurmd_cert_key.pem"
	}
	' "$source_file" >"$target_file"
}

wait_node_idle()
{
	label=$1
	node=$2
	attempt=0
	while [ "$attempt" -lt 240 ]; do
		"$scontrol" show node "$node" >"${run_dir}/${label}-${node}.txt" 2>/dev/null || true
		state=$(node_field State "${run_dir}/${label}-${node}.txt")
		if [ "$state" = IDLE ]; then
			/usr/bin/printf 'node_idle phase=%s node=%s wait_seconds=%s\n' \
				"$label" "$node" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
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

wait_mixed_accounting()
{
	job_id=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		"$sacct" -j "$job_id" -n -P \
			--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES%200,AllocTRES%200 \
			>"$file" 2>"${file%.txt}.err" || true
		if /usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" &&
			$5 == "PC-210,ubuntu" { job_ok = 1 }
		$1 == job ".0" && $3 == "COMPLETED" && $4 == "0:0" &&
			$5 == "PC-210,ubuntu" { step_ok = 1 }
		END { exit !(job_ok && step_ok) }
		' "$file"; then
			return 0
		fi
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

restore_local_config()
{
	[ "$config_installed" -eq 1 ] || return 0
	atomic_install "${run_dir}/slurm.conf.before" "$slurm_conf" \
		"${run_dir}/slurm.conf.before" || return 1
	restart_launchd local-restore || return 1
	config_installed=0
	local_restored=1
	return 0
}

write_runtime_state()
{
	phase_value=$1
	{
		/usr/bin/printf 'runtime_run_dir=%s\n' "$run_dir"
		/usr/bin/printf 'phase=%s\n' "$phase_value"
		/usr/bin/printf 'cpu_job=%s\n' "$cpu_job"
		/usr/bin/printf 'srun_job=%s\n' "$srun_job"
		/usr/bin/printf 'gpu_job=%s\n' "$gpu_job"
		/usr/bin/printf 'mixed_job=%s\n' "$mixed_job"
	} >"${runtime_state}.tmp" || return 1
	/bin/chmod 0600 "${runtime_state}.tmp" || return 1
	/usr/sbin/chown root:wheel "${runtime_state}.tmp" || return 1
	/bin/mv -f "${runtime_state}.tmp" "$runtime_state" || return 1
}

cleanup_on_exit()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_active
	if [ "$success" -ne 1 ] && [ "$mode" = run ]; then
		if [ "$config_installed" -eq 1 ]; then
			if restore_local_config; then
				write_runtime_state FAILED_LOCAL_TLS_NONE_RESTORED >/dev/null 2>&1 || true
				/usr/bin/printf 'recovery: Mac local TLS-none config restored; Ubuntu TLS remains active; inspect run_dir=%s state=%s\n' \
					"$run_dir" "$runtime_state" >&2
				/usr/bin/printf '%s\n' \
					'NEXT_ON_UBUNTU_RECOVERY: run Ubuntu restore with SMD407_MAC_TLS_LOCAL_RESTORED=YES' >&2
			else
				/usr/bin/printf 'fatal recovery: Mac local config or launchd restore failed; backup=%s\n' \
					"${run_dir}/slurm.conf.before" >&2
			fi
		elif [ "$local_restored" -eq 1 ]; then
			write_runtime_state FAILED_LOCAL_TLS_NONE_RESTORED >/dev/null 2>&1 || true
			/usr/bin/printf 'recovery: Mac local TLS-none config is already restored; Ubuntu TLS remains active; inspect run_dir=%s state=%s\n' \
				"$run_dir" "$runtime_state" >&2
			/usr/bin/printf '%s\n' \
				'NEXT_ON_UBUNTU_RECOVERY: run Ubuntu restore with SMD407_MAC_TLS_LOCAL_RESTORED=YES' >&2
		else
			/usr/bin/printf 'preflight: stopped before Mac config/daemon/job mutation; run_dir=%s\n' \
				"$run_dir" >&2
		fi
	elif [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: finalize did not complete; preserve state=%s run_dir=%s\n' \
			"$runtime_state" "$run_dir" >&2
	fi
	exit "$rc"
}

trap cleanup_on_exit EXIT HUP INT TERM

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for macOS'
[ "$(/bin/hostname -s)" = PC-210 ] || fail "unexpected host=$(/bin/hostname -s)"
for required in "$slurm_conf" "$gres_conf" "$slurm_key" "$slurmd" "$scontrol" \
	"$squeue" "$sbatch" "$srun" "$scancel" "$sacct" "$plugin" \
	"$s2n_prefix/lib/libs2n.dylib" "$ca" "$slurmd_cert" "$slurmd_key" \
	"$inactive_state" "$pid_file" "$mlx_job"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_path in /bin/cat /bin/chmod /bin/cp /bin/date /bin/hostname \
	/bin/kill /bin/launchctl /bin/mkdir /bin/mv /bin/rm /bin/sleep \
	/usr/bin/awk /usr/bin/cmp /usr/bin/env /usr/bin/grep /usr/bin/id \
	/usr/bin/install /usr/bin/nc /usr/bin/shasum /usr/bin/stat /usr/bin/sudo \
	/usr/bin/uname /usr/sbin/chown; do
	[ -x "$command_path" ] || fail "missing command=$command_path"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'
[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$inactive_state")" = root:wheel:600 ] || \
	fail 'inactive state metadata mismatch'
[ "$(state_value phase "$inactive_state")" = MAC_INACTIVE_INSTALLED ] || \
	fail 'unexpected inactive state phase'
[ "$(/usr/bin/shasum -a 256 "$plugin" | /usr/bin/awk '{print $1}')" = \
	"$plugin_hash" ] || fail 'installed plugin hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$s2n_prefix/lib/libs2n.dylib" | /usr/bin/awk '{print $1}')" = \
	"$libs2n_hash" ] || fail 'installed libs2n hash mismatch'
umask 077
/bin/mkdir "$run_dir" || fail 'cannot create run directory'
/bin/chmod 0755 "$run_dir" || fail 'cannot make run directory traversable'
/usr/bin/printf 'mode=%s run_dir=%s\n' "$mode" "$run_dir"
export SLURM_CONF="$slurm_conf"

case "$mode" in
run)
	[ ! -e "$runtime_state" ] || fail "runtime state already exists=$runtime_state"
	initial_pid=$(managed_slurmd_pid) || fail 'slurmd launchd identity mismatch'
	/usr/bin/nc -vz -w 3 192.168.10.180 6817 \
		>"${run_dir}/controller-port.out" 2>"${run_dir}/controller-port.err" || \
		fail 'controller port 6817 is unreachable'
	if /usr/bin/grep -Eq '^[[:space:]]*(TLSType|TLSParameters)=' "$slurm_conf"; then
		fail 'Mac production slurm.conf already has TLS keys'
	fi
	/bin/cp -p "$slurm_conf" "${run_dir}/slurm.conf.before" || fail 'cannot back up slurm.conf'
	/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurmd" "$plugin" \
		"$s2n_prefix/lib/libs2n.dylib" "$ca" "$slurmd_cert" "$slurmd_key" \
		>"${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'
	build_candidate "$slurm_conf" "${run_dir}/slurm.conf.tls" || fail 'cannot build TLS config'
	/bin/cp "$gres_conf" "${run_dir}/gres.conf" || fail 'cannot stage candidate gres.conf'
	/bin/chmod 0600 "${run_dir}/slurm.conf.tls" || fail 'cannot protect candidate config'
	SLURM_SACK_KEY="$slurm_key" "$slurmd" -G -f "${run_dir}/slurm.conf.tls" \
		>"${run_dir}/candidate-G.out" 2>"${run_dir}/candidate-G.err" || \
		fail 'TLS candidate slurmd -G failed'
	/usr/bin/grep -Eq 'Gres Name=gpu Type=apple Count=1 .*File=/dev/null' \
		"${run_dir}/candidate-G.out" "${run_dir}/candidate-G.err" || \
		fail 'candidate Apple GPU GRES validation missing'
	atomic_install "${run_dir}/slurm.conf.tls" "$slurm_conf" "$slurm_conf" || \
		fail 'cannot install Mac TLS config'
	config_installed=1
	restart_launchd tls || fail 'cannot restart Mac slurmd with TLS config'
	"$scontrol" ping >"${run_dir}/controller-tls.txt" 2>&1 || fail 'TLS controller ping failed'
	/usr/bin/grep -q ' is UP$' "${run_dir}/controller-tls.txt" || fail 'TLS controller is not UP'
	wait_node_idle tls PC-210 || fail 'PC-210 did not become IDLE with TLS'
	wait_node_idle tls ubuntu || fail 'Ubuntu is not IDLE with TLS'
	"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-tls.txt" || fail 'cannot read TLS queue'
	[ ! -s "${run_dir}/queue-tls.txt" ] || fail 'target queue is not empty'
	/bin/mkdir "$output_dir" || fail 'cannot create job output directory'
	/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown job output directory'
	/bin/chmod 0700 "$output_dir" || fail 'cannot protect job output directory'
	/usr/bin/printf '%s\n' '#!/bin/sh' \
		'printf "job_id=%s node=%s uid=%s gid=%s\n" "$SLURM_JOB_ID" "$(/bin/hostname)" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)"' \
		>"${run_dir}/cpu.sh" || fail 'cannot write CPU payload'
	/bin/chmod 0755 "${run_dir}/cpu.sh" || fail 'cannot make CPU payload executable'
	active_job=$(/usr/bin/sudo -u "$test_user" -H /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition=debug --nodelist=PC-210 --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=64M --time=00:01:00 --chdir=/tmp \
		--output="${output_dir}/cpu-%j.out" --error="${output_dir}/cpu-%j.err" \
		"${run_dir}/cpu.sh") || fail 'TLS CPU sbatch failed'
	cpu_job=$active_job
	/usr/bin/printf 'submitted cpu_job=%s\n' "$cpu_job"
	wait_job_gone "$cpu_job" || fail 'CPU job remained in queue'
	wait_accounting "$cpu_job" batch 0 "${run_dir}/cpu-accounting.txt" || fail 'CPU accounting mismatch'
	/usr/bin/awk -v job="$cpu_job" -v uid="$test_uid" -v gid="$test_gid" '
	$1 == "job_id=" job && $2 == "node=PC-210.local" &&
		$3 == "uid=" uid && $4 == "gid=" gid { ok = 1 }
	END { exit !ok }
	' "${output_dir}/cpu-${cpu_job}.out" || fail 'CPU payload output mismatch'
	[ ! -s "${output_dir}/cpu-${cpu_job}.err" ] || fail 'CPU payload stderr is not empty'
	active_job=
	/usr/bin/sudo -u "$test_user" -H /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$srun" --job-name=smd407-tls-srun --partition=debug --nodelist=PC-210 \
		--nodes=1 --ntasks=1 --cpus-per-task=1 --mem=64M --time=00:01:00 \
		/bin/sh -c 'printf "job_id=%s step_id=%s node=%s uid=%s gid=%s\n" "$SLURM_JOB_ID" "$SLURM_STEP_ID" "$(/bin/hostname)" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)"' \
		>"${run_dir}/srun.out" 2>"${run_dir}/srun.err" || fail 'TLS direct srun failed'
	srun_job=$(/usr/bin/awk -F '[ =]' '/^job_id=/ { print $2; exit }' "${run_dir}/srun.out")
	case "$srun_job" in ''|*[!0-9]*) fail "invalid srun job id=$srun_job" ;; esac
	/usr/bin/awk -v job="$srun_job" -v uid="$test_uid" -v gid="$test_gid" '
	$1 == "job_id=" job && $2 ~ /^step_id=0$/ && $3 == "node=PC-210.local" &&
		$4 == "uid=" uid && $5 == "gid=" gid { ok = 1 }
	END { exit !ok }
	' "${run_dir}/srun.out" || fail 'srun payload output mismatch'
	[ ! -s "${run_dir}/srun.err" ] || fail 'srun stderr is not empty'
	wait_accounting "$srun_job" 0 0 "${run_dir}/srun-accounting.txt" || fail 'srun accounting mismatch'
	active_job=$(/usr/bin/sudo -u "$test_user" -H /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition=debug --nodelist=PC-210 --gres=gpu:apple:1 \
		--output="${output_dir}/gpu-%j.out" --error="${output_dir}/gpu-%j.err" "$mlx_job") || \
		fail 'TLS GPU sbatch failed'
	gpu_job=$active_job
	/usr/bin/printf 'submitted gpu_job=%s\n' "$gpu_job"
	wait_job_gone "$gpu_job" || fail 'GPU job remained in queue'
	wait_accounting "$gpu_job" batch 1 "${run_dir}/gpu-accounting.txt" || fail 'GPU accounting mismatch'
	/usr/bin/grep -Fqx 'gpu_smoke_test=PASS' "${output_dir}/gpu-${gpu_job}.out" || \
		fail 'GPU smoke marker missing'
	active_job=
	/usr/bin/sudo -u "$test_user" -H /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$srun" --job-name=smd407-tls-mixed --partition=smd402 --nodes=2 --ntasks=2 \
		--ntasks-per-node=1 --cpus-per-task=1 --mem=64M --time=00:01:00 --label \
		/bin/sh -c 'printf "%s|%s|%s\n" "$SLURM_JOB_ID" "$SLURM_PROCID" "$(/usr/bin/uname -m)"' \
		>"${run_dir}/mixed.out" 2>"${run_dir}/mixed.err" || \
		fail 'TLS mixed-architecture srun failed'
	mixed_job=$(/usr/bin/awk -F '|' '
	NR == 1 { sub(/^[0-9]+:[[:space:]]*/, "", $1); print $1; exit }
	' "${run_dir}/mixed.out")
	case "$mixed_job" in ''|*[!0-9]*) fail "invalid mixed job id=$mixed_job" ;; esac
	/usr/bin/awk -F '|' -v job="$mixed_job" '
	{
		sub(/^[0-9]+:[[:space:]]*/, "", $1)
		if ($1 != job) next
		if ($2 == 0 && $3 == "arm64") arm = 1
		if ($2 == 1 && $3 == "x86_64") x86 = 1
	}
	END { exit !(arm && x86) }
	' "${run_dir}/mixed.out" || fail 'mixed rank or architecture output mismatch'
	[ ! -s "${run_dir}/mixed.err" ] || fail 'mixed srun stderr is not empty'
	wait_mixed_accounting "$mixed_job" "${run_dir}/mixed-accounting.txt" || fail 'mixed accounting mismatch'
	tls_none_rc=0
	SLURM_CONF="${run_dir}/slurm.conf.before" "$scontrol" ping \
		>"${run_dir}/tls-none-client.out" 2>"${run_dir}/tls-none-client.err" || \
		tls_none_rc=$?
	[ "$tls_none_rc" -ne 0 ] || fail 'tls/none client unexpectedly reached TLS controller'
	if /usr/bin/grep -q ' is UP$' "${run_dir}/tls-none-client.out"; then
		fail 'tls/none client reported controller UP'
	fi
	/usr/bin/printf 'tls_none_client_rc=%s\n' "$tls_none_rc" >"${run_dir}/tls-none-client.rc"
	restore_local_config || fail 'cannot restore Mac TLS-none config'
	/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurmd" "$plugin" \
		"$s2n_prefix/lib/libs2n.dylib" "$ca" "$slurmd_cert" "$slurmd_key" \
		>"${run_dir}/production-local-restored.sha256" || fail 'cannot hash local restored state'
	/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
		"${run_dir}/production-local-restored.sha256" || fail 'Mac local production hash mismatch'
	write_runtime_state TEST_COMPLETE_LOCAL_TLS_NONE_RESTORED || fail 'cannot write runtime state'
	success=1
	/usr/bin/printf 'SMD407_MAC_TLS_RUNTIME_COMPLETE cpu_job=%s srun_job=%s gpu_job=%s mixed_job=%s tls_none_rejected=PASS local_tls_none_restored=PASS slurmd_pid=%s state=%s run_dir=%s\n' \
		"$cpu_job" "$srun_job" "$gpu_job" "$mixed_job" "$(managed_slurmd_pid)" \
		"$runtime_state" "$run_dir"
	/usr/bin/printf '%s\n' 'NEXT_ON_UBUNTU: run verify, then restore before Mac finalize'
	;;
finalize)
	[ "${SMD407_UBUNTU_TLS_RESTORED:-}" = YES ] || \
		fail 'set SMD407_UBUNTU_TLS_RESTORED=YES only after the Ubuntu restore marker'
	[ -f "$runtime_state" ] || fail "missing runtime state=$runtime_state"
	phase=$(state_value phase "$runtime_state")
	case "$phase" in
	TEST_COMPLETE_LOCAL_TLS_NONE_RESTORED) classification=RUNTIME_PASS ;;
	FAILED_LOCAL_TLS_NONE_RESTORED) classification=RECOVERY_ONLY ;;
	*) fail "unexpected runtime phase=$phase" ;;
	esac
	runtime_run_dir=$(state_value runtime_run_dir "$runtime_state")
	case "$runtime_run_dir" in /tmp/slurm-smd407-mac-tls-runtime-run-*) ;; *) fail 'invalid runtime run directory' ;; esac
	"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'restored controller ping failed'
	for node in ubuntu PC-210; do wait_node_idle final "$node" || fail "node=$node is not IDLE"; done
	"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue.txt" || fail 'cannot read final queue'
	[ ! -s "${run_dir}/queue.txt" ] || fail 'final queue is not empty'
	final_output=${run_dir}/final-output
	/bin/mkdir "$final_output" || fail 'cannot create final output directory'
	/usr/sbin/chown "$test_uid:$test_gid" "$final_output" || fail 'cannot chown final output directory'
	/bin/chmod 0700 "$final_output" || fail 'cannot protect final output directory'
	active_job=$(/usr/bin/sudo -u "$test_user" -H /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition=debug --nodelist=PC-210 --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=64M --time=00:01:00 --chdir=/tmp \
		--output="${final_output}/smoke-%j.out" --error="${final_output}/smoke-%j.err" \
		--wrap='/bin/hostname') || fail 'final TLS-none smoke submission failed'
	final_job=$active_job
	/usr/bin/printf 'submitted final_smoke_job=%s\n' "$final_job"
	wait_job_gone "$final_job" || fail 'final smoke remained in queue'
	wait_accounting "$final_job" batch 0 "${run_dir}/final-accounting.txt" || \
		fail 'final smoke accounting mismatch'
	active_job=
	/usr/bin/shasum -a 256 "$plugin" "$s2n_prefix/lib/libs2n.dylib" "$ca" \
		"$slurmd_cert" "$slurmd_key" >"${run_dir}/removed-inputs.sha256" || \
		fail 'cannot preserve cleanup hashes'
	/bin/rm -f "$plugin" "$ca" "$slurmd_cert" "$slurmd_key"
	/bin/rm -rf "$s2n_prefix"
	/bin/rm -f "$inactive_state" "$runtime_state"
	for removed in "$plugin" "$s2n_prefix" "$ca" "$slurmd_cert" "$slurmd_key" \
		"$inactive_state" "$runtime_state"; do
		[ ! -e "$removed" ] || fail "cleanup target remains=$removed"
	done
	success=1
	/usr/bin/printf 'SMD407_MAC_TLS_FINALIZE_COMPLETE classification=%s tls=tls/none artifacts=REMOVED certificates=REMOVED state=ABSENT final_smoke_job=%s nodes=IDLE queue=EMPTY production_restored=PASS slurmd_pid=%s run_dir=%s\n' \
		"$classification" "$final_job" "$(managed_slurmd_pid)" "$runtime_run_dir"
	;;
esac
