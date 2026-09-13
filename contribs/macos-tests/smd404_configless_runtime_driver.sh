#!/bin/sh

set -u

if [ "${SMD404_CONFIGLESS_RUNTIME_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD404_CONFIGLESS_RUNTIME_CONFIRMED=YES after approving the SMD-404 production runtime test' >&2
	exit 64
fi

source_root=/Users/REDACTED_USER/dev/slurm.26-05
prefix=/opt/slurm/26.11.0
candidate_slurmd=${source_root}/src/slurmd/slurmd/.libs/slurmd
candidate_lib=${source_root}/src/api/.libs/libslurmfull.dylib
production_slurmd=${prefix}/sbin/slurmd
production_lib=${prefix}/lib/slurm/libslurmfull.dylib
local_conf=${prefix}/etc/slurm.conf
local_gres=${prefix}/etc/gres.conf
plist=/Library/LaunchDaemons/org.schedmd.slurmd.plist
service_target=system/org.schedmd.slurmd
pid_file=/var/run/slurmd.pid
cache_link=/var/run/slurm/conf
cache_dir=/var/spool/slurmd/conf-cache
hook_name=smd404_configless_prolog.sh
hook_log=/tmp/smd404-configless-hook-events.log
controller=192.168.10.180:6817
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
mlx_job=${prefix}/share/macos-gpu-job/mlx_gpu_smoke.sbatch
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
approved_conf_hash=9c7021e4c794fd9ec4e76af0b7cd5c574d1cd058b9ba9c60c849103f0a7577a2
approved_gres_hash=08d31ac718b61395b0a452bb6700c1143352357cf505b3791c0285f55f43f1d0
approved_slurmd_hash=a3df64dde33256a7dff621854ff56501e854cc51ffab2ebb6f91ec5a92d94d72
approved_lib_hash=cbe62a38946a3f0a17f2bcf8840638ff31120d626dbbdffdf7f89a36ab852fae
approved_plist_hash=5db42efbc0f476ae54968a397961807a6061eea2d53fb131c12329c6e611ede9
candidate_slurmd_hash=4229c1ab380c19525308e9c935cf0ff3776e37c5369f3dae600fc00475d824dd
candidate_lib_hash=d88213bcc3db6856266d1202f1e6804a634f2b3654b6b82bef710788450d7b89
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd404-runtime-${run_stamp}
backup_dir=${prefix}/.smd404-backup-${run_stamp}
output_dir=${run_dir}/output
candidate_plist=${run_dir}/org.schedmd.slurmd.configless.plist
local_client_conf=${run_dir}/slurm-local-client.conf
success=0
takeover_started=0
local_restored=0
active_job=
old_pid=
configless_pid=
restored_pid=
old_start=
configless_start=

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
}

launchd_loaded()
{
	/bin/launchctl print "$service_target" >/dev/null 2>&1
}

launchd_pid()
{
	/bin/launchctl print "$service_target" 2>/dev/null | /usr/bin/awk '
		/pid =/ { print $3; exit }
	'
}

is_running()
{
	pid=$1
	case "$pid" in
	''|*[!0-9]*) return 1 ;;
	esac
	/bin/kill -0 "$pid" >/dev/null 2>&1
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

local_client()
{
	/usr/bin/env SLURM_CONF="$local_conf" "$@"
}

rescue_client()
{
	if [ -f "$local_conf" ]; then
		/usr/bin/env SLURM_CONF="$local_conf" "$@"
	else
		/usr/bin/env SLURM_CONF="${backup_dir}/slurm.conf" "$@"
	fi
}

cache_client()
{
	/usr/bin/env -u SLURM_CONF "$@"
}

queue_state()
{
	rescue_client "$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }'
}

cancel_if_active()
{
	[ -n "$active_job" ] || return 0
	state=$(queue_state "$active_job")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$active_job" "$state" >&2
		rescue_client "$scancel" "$active_job" >/dev/null 2>&1 || true
	fi
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ -z "$(queue_state "$job_id")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' "$job_id" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_process_stop()
{
	pid=$1
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		is_running "$pid" || return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_node_idle()
{
	mode=$1
	old_pid_value=$2
	old_start_value=$3
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ "$mode" = cache ]; then
			cache_client "$scontrol" show node "$node_name" \
				>"${run_dir}/node-${mode}.txt" 2>"${run_dir}/node-${mode}.err" || true
		else
			local_client "$scontrol" show node "$node_name" \
				>"${run_dir}/node-${mode}.txt" 2>"${run_dir}/node-${mode}.err" || true
		fi
		state=$(node_field State "${run_dir}/node-${mode}.txt")
		start=$(node_field SlurmdStartTime "${run_dir}/node-${mode}.txt")
		pid=$(launchd_pid)
		if [ "$state" = IDLE ] && [ -n "$start" ] && [ "$start" != None ] &&
			[ "$pid" != "$old_pid_value" ] && [ "$start" != "$old_start_value" ] &&
			is_running "$pid"; then
			case "$mode" in
			cache) configless_pid=$pid; configless_start=$start ;;
			local) restored_pid=$pid ;;
			esac
			/usr/bin/printf 'node_ready mode=%s pid=%s start=%s wait_seconds=%s\n' \
				"$mode" "$pid" "$start" "$attempt"
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
	file=$2
	expect_gpu=$3
	rescue_client "$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList,ReqTRES%200,AllocTRES%200 \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" -v gpu="$expect_gpu" '
	function has(value, item, n, fields, i) {
		n = split(value, fields, ",")
		for (i = 1; i <= n; i++) if (fields[i] == item) return 1
		return 0
	}
	$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" &&
	$5 == "PC-210" {
		job_ok = 1
		if (!gpu || (has($6, "gres/gpu=1") &&
				has($6, "gres/gpu:apple=1") &&
				has($7, "gres/gpu=1") &&
				has($7, "gres/gpu:apple=1"))) gpu_ok = 1
	}
	$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" { step_ok = 1 }
	END { exit !(job_ok && step_ok && gpu_ok) }
	' "$file"
}

wait_accounting()
{
	job_id=$1
	file=$2
	expect_gpu=$3
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		accounting_complete "$job_id" "$file" "$expect_gpu" && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_hook_event()
{
	version=$1
	job_id=$2
	attempt=0
	while [ "$attempt" -lt 30 ]; do
		if [ -f "$hook_log" ] &&
			/usr/bin/grep -Eq "^version=${version} job_id=${job_id} node=PC-210 uid=0 gid=0 context=prolog_slurmd$" \
			"$hook_log"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

submit_cpu()
{
	phase=$1
	payload=${run_dir}/cpu-${phase}.sh
	out=${output_dir}/cpu-${phase}-%j.out
	err=${output_dir}/cpu-${phase}-%j.err
	cat >"$payload" <<EOF
#!/bin/sh
printf 'phase=${phase} job_id=%s node=%s arch=%s uid=%s gid=%s\\n' \\
	"\${SLURM_JOB_ID:-unknown}" "\${SLURMD_NODENAME:-unknown}" \\
	"\$(uname -m)" "\$(id -u)" "\$(id -g)"
EOF
	/bin/chmod 0755 "$payload" || return 1
	active_job=$(/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env -u SLURM_CONF \
		"$sbatch" --parsable --partition="$partition" --nodelist="$node_name" \
		--nodes=1 --ntasks=1 --time=00:01:00 --chdir=/tmp \
		--output="$out" --error="$err" "$payload") || return 1
	active_job=$(/usr/bin/printf '%s\n' "$active_job" | /usr/bin/sed 's/;.*//')
	case "$active_job" in
	''|*[!0-9]*) return 1 ;;
	esac
	job_id=$active_job
	/usr/bin/printf 'submitted phase=%s cpu_job=%s\n' "$phase" "$job_id"
	wait_job_gone "$job_id" || return 1
	wait_accounting "$job_id" "${run_dir}/cpu-${phase}-accounting.txt" 0 || return 1
	/usr/bin/grep -Eq \
		"^phase=${phase} job_id=${job_id} node=PC-210 arch=arm64 uid=3001 gid=3001$" \
		"${output_dir}/cpu-${phase}-${job_id}.out" || return 1
	wait_hook_event "${phase#v}" "$job_id" || return 1
	active_job=
	last_cpu_job=$job_id
	return 0
}

submit_gpu()
{
	out=${output_dir}/gpu-%j.out
	err=${output_dir}/gpu-%j.err
	active_job=$(/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env -u SLURM_CONF \
		"$sbatch" --parsable --partition="$partition" --nodelist="$node_name" \
		--gres=gpu:apple:1 --output="$out" --error="$err" "$mlx_job") || return 1
	active_job=$(/usr/bin/printf '%s\n' "$active_job" | /usr/bin/sed 's/;.*//')
	case "$active_job" in
	''|*[!0-9]*) return 1 ;;
	esac
	job_id=$active_job
	/usr/bin/printf 'submitted gpu_job=%s\n' "$job_id"
	wait_job_gone "$job_id" || return 1
	wait_accounting "$job_id" "${run_dir}/gpu-accounting.txt" 1 || return 1
	/usr/bin/grep -Fqx 'gpu_smoke_test=PASS' "${output_dir}/gpu-${job_id}.out" || return 1
	/usr/bin/grep -Fqx 'slurm_job_gpus=0' "${output_dir}/gpu-${job_id}.out" || return 1
	wait_hook_event 1 "$job_id" || return 1
	active_job=
	gpu_job=$job_id
	return 0
}

atomic_install()
{
	source=$1
	target=$2
	owner=$3
	group=$4
	file_mode=$5
	tmp=${target}.smd404.$$
	/usr/bin/install -o "$owner" -g "$group" -m "$file_mode" "$source" "$tmp" ||
		return 1
	/bin/mv -f "$tmp" "$target" || return 1
}

restore_local()
{
	[ "$takeover_started" -eq 1 ] || return 0
	/usr/bin/printf 'restore_local_mode begin=yes\n' >&2
	cancel_if_active
	current_pid=$(launchd_pid)
	if launchd_loaded; then
		/bin/launchctl bootout "$service_target" >/dev/null 2>&1 || return 1
		wait_process_stop "$current_pid" || return 1
	fi
	[ -f "$local_conf" ] || /bin/mv "${backup_dir}/slurm.conf" "$local_conf" || return 1
	atomic_install "${backup_dir}/slurmd" "$production_slurmd" root wheel 0755 || return 1
	atomic_install "${backup_dir}/libslurmfull.dylib" "$production_lib" root wheel 0755 || return 1
	atomic_install "${backup_dir}/org.schedmd.slurmd.plist" "$plist" root wheel 0644 || return 1
	/bin/launchctl enable "$service_target" >/dev/null 2>&1 || return 1
	/bin/launchctl bootstrap system "$plist" >"${run_dir}/bootstrap-local.out" \
		2>"${run_dir}/bootstrap-local.err" || return 1
	wait_node_idle local "$configless_pid" "$configless_start" || return 1
	if [ -L "$cache_link" ]; then
		/bin/rm "$cache_link" || return 1
	elif [ -e "$cache_link" ]; then
		return 1
	fi
	if [ -d "$cache_dir" ]; then
		/bin/mv "$cache_dir" "${run_dir}/conf-cache-final" || return 1
	fi
	/usr/bin/shasum -a 256 "$production_slurmd" "$production_lib" "$plist" "$local_conf" \
		>"${run_dir}/production-after.sha256" || return 1
	/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
		"${run_dir}/production-after.sha256" || return 1
	local_restored=1
	takeover_started=0
	/usr/bin/printf 'restore_local_mode=PASS pid=%s\n' "$restored_pid"
	return 0
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if ! restore_local; then
		/usr/bin/printf 'fatal recovery: manual restore required from backup=%s\n' \
			"$backup_dir" >&2
		rc=1
	fi
	if [ -f "$hook_log" ]; then
		/bin/mv "$hook_log" "${run_dir}/hook-events-recovery.txt" 2>/dev/null || true
	fi
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: Mac local-mode restore attempted; controller portable profile remains active; inspect run_dir=%s backup=%s\n' \
			"$run_dir" "$backup_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'
for required in "$candidate_slurmd" "$candidate_lib" "$production_slurmd" \
	"$production_lib" "$local_conf" "$local_gres" "$plist" "$scontrol" \
	"$squeue" "$sbatch" "$scancel" "$sacct" "$mlx_job" "$pid_file"; do
	[ -e "$required" ] || fail "missing $required"
done
for command in /usr/bin/awk /usr/bin/cmp /usr/bin/dscacheutil /usr/bin/file /usr/bin/grep \
	/usr/bin/install /usr/bin/otool /usr/bin/plutil /usr/bin/shasum \
	/usr/bin/sudo /usr/libexec/PlistBuddy /bin/launchctl /bin/mkdir /bin/mv \
	/bin/rm /bin/sleep /usr/sbin/ipconfig; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'
launchd_loaded || fail "launchd service is not loaded=$service_target"
[ ! -e "$cache_link" ] || fail "pre-existing configless cache link=$cache_link"
[ ! -e "$cache_dir" ] || fail "pre-existing configless cache directory=$cache_dir"
[ ! -e "$hook_log" ] || fail "pre-existing hook log=$hook_log"

[ "$(/usr/bin/shasum -a 256 "$local_conf" | /usr/bin/awk '{ print $1 }')" = "$approved_conf_hash" ] ||
	fail 'Mac slurm.conf changed after approved preflight'
[ "$(/usr/bin/shasum -a 256 "$local_gres" | /usr/bin/awk '{ print $1 }')" = "$approved_gres_hash" ] ||
	fail 'Mac gres.conf changed after approved preflight'
[ "$(/usr/bin/shasum -a 256 "$production_slurmd" | /usr/bin/awk '{ print $1 }')" = "$approved_slurmd_hash" ] ||
	fail 'production slurmd changed after approved preflight'
[ "$(/usr/bin/shasum -a 256 "$production_lib" | /usr/bin/awk '{ print $1 }')" = "$approved_lib_hash" ] ||
	fail 'production libslurmfull changed after approved preflight'
[ "$(/usr/bin/shasum -a 256 "$plist" | /usr/bin/awk '{ print $1 }')" = "$approved_plist_hash" ] ||
	fail 'production launchd plist changed after approved preflight'
[ "$(/usr/bin/shasum -a 256 "$candidate_slurmd" | /usr/bin/awk '{ print $1 }')" = "$candidate_slurmd_hash" ] ||
	fail 'candidate slurmd hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$candidate_lib" | /usr/bin/awk '{ print $1 }')" = "$candidate_lib_hash" ] ||
	fail 'candidate libslurmfull hash mismatch'

/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0700 "$backup_dir" || fail 'cannot create backup directory'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
/usr/bin/printf 'run_dir=%s backup=%s controller=%s\n' "$run_dir" "$backup_dir" "$controller"

local_client "$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
local_client "$scontrol" show config >"${run_dir}/controller-config-portable.txt" ||
	fail 'cannot read portable controller config'
/usr/bin/grep -Fq "$hook_name" "${run_dir}/controller-config-portable.txt" ||
	fail 'controller portable profile does not contain SMD-404 Prolog'
! /usr/bin/grep -Eq '^TaskPlugin[[:space:]]*=[[:space:]]*task/affinity$' \
	"${run_dir}/controller-config-portable.txt" || fail 'controller still has task/affinity'
! /usr/bin/grep -Eq '^JobAcctGatherType[[:space:]]*=[[:space:]]*jobacct_gather/cgroup$' \
	"${run_dir}/controller-config-portable.txt" || fail 'controller still has jobacct_gather/cgroup'
local_client "$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'cannot read node'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'PC-210 is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'PC-210 CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'PC-210 AllocMem is not zero'
[ -z "$(local_client "$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'

/usr/bin/file "$candidate_slurmd" "$candidate_lib" >"${run_dir}/candidate-file.txt" || fail 'cannot inspect candidates'
[ "$(/usr/bin/grep -c 'Mach-O 64-bit.*arm64' "${run_dir}/candidate-file.txt")" -eq 2 ] ||
	fail 'candidate architecture mismatch'
/usr/bin/otool -L "$candidate_slurmd" >"${run_dir}/candidate-otool.txt" || fail 'cannot inspect candidate dependencies'
/usr/bin/strings "$candidate_slurmd" "$candidate_lib" >"${run_dir}/candidate-strings.txt" || fail 'cannot inspect candidate strings'
/usr/bin/grep -Fq '/var/run/slurm/conf' "${run_dir}/candidate-strings.txt" ||
	fail 'candidate lacks macOS configless runtime path'

old_pid=$(launchd_pid)
old_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")
is_running "$old_pid" || fail 'current launchd slurmd PID is invalid'
/usr/bin/shasum -a 256 "$production_slurmd" "$production_lib" "$plist" "$local_conf" \
	>"${run_dir}/production-before.sha256" || fail 'cannot hash production files'
/bin/cp -p "$production_slurmd" "${backup_dir}/slurmd" || fail 'cannot back up slurmd'
/bin/cp -p "$production_lib" "${backup_dir}/libslurmfull.dylib" || fail 'cannot back up library'
/bin/cp -p "$plist" "${backup_dir}/org.schedmd.slurmd.plist" || fail 'cannot back up plist'

/bin/cp -p "$plist" "$candidate_plist" || fail 'cannot stage candidate plist'
/usr/libexec/PlistBuddy -c 'Delete :ProgramArguments' "$candidate_plist" || fail 'cannot replace ProgramArguments'
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$candidate_plist" || fail 'cannot create ProgramArguments'
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $production_slurmd" "$candidate_plist" || exit 1
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string -D' "$candidate_plist" || exit 1
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string --conf-server=$controller" "$candidate_plist" || exit 1
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:3 string -N' "$candidate_plist" || exit 1
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string $node_name" "$candidate_plist" || exit 1
/usr/libexec/PlistBuddy -c 'Delete :EnvironmentVariables:SLURM_CONF' "$candidate_plist" ||
	fail 'cannot remove SLURM_CONF from candidate plist'
/usr/bin/plutil -lint "$candidate_plist" >"${run_dir}/plist-lint.txt" 2>&1 || fail 'candidate plist is invalid'

trap cleanup EXIT HUP INT TERM
takeover_started=1
/bin/launchctl bootout "$service_target" >"${run_dir}/bootout-local.out" \
	2>"${run_dir}/bootout-local.err" || fail 'cannot stop local-mode launchd service'
wait_process_stop "$old_pid" || fail 'local-mode slurmd did not stop'
atomic_install "$candidate_slurmd" "$production_slurmd" root wheel 0755 || fail 'cannot install candidate slurmd'
atomic_install "$candidate_lib" "$production_lib" root wheel 0755 || fail 'cannot install candidate library'
atomic_install "$candidate_plist" "$plist" root wheel 0644 || fail 'cannot install configless plist'
/bin/mv "$local_conf" "${backup_dir}/slurm.conf" || fail 'cannot move local config out of precedence path'
/bin/launchctl enable "$service_target" >/dev/null 2>&1 || fail 'cannot enable configless service'
/bin/launchctl bootstrap system "$plist" >"${run_dir}/bootstrap-configless.out" \
	2>"${run_dir}/bootstrap-configless.err" || fail 'cannot bootstrap configless service'
wait_node_idle cache "$old_pid" "$old_start" || fail 'configless slurmd did not become IDLE'

[ -L "$cache_link" ] || fail 'configless cache link was not created'
[ "$(/usr/bin/readlink "$cache_link")" = "$cache_dir" ] || fail 'configless cache link target mismatch'
for cached in slurm.conf gres.conf "$hook_name"; do
	[ -f "${cache_dir}/${cached}" ] || fail "missing cached file=$cached"
done
/usr/bin/grep -Fqx 'NodeName=PC-210 Name=gpu Type=apple File=/dev/null' \
	"${cache_dir}/gres.conf" || fail 'cached Apple GRES record mismatch'
/usr/bin/grep -Fqx 'SMD404_HOOK_VERSION=1' "${cache_dir}/${hook_name}" || fail 'cached hook v1 mismatch'
[ "$(/usr/bin/grep -Ec '^[[:space:]]*(ProctrackType|TaskPlugin|JobAcctGatherType)=' "${cache_dir}/slurm.conf")" -eq 0 ] ||
	fail 'cached portable profile still has platform-specific plugin settings'

/bin/launchctl print "$service_target" >"${run_dir}/launchd-configless.txt" 2>&1 || fail 'cannot read configless launchd state'
/usr/bin/grep -Fq -- "--conf-server=$controller" "${run_dir}/launchd-configless.txt" || fail 'launchd lacks conf-server argument'
! /usr/bin/grep -Fq "$local_conf" "${run_dir}/launchd-configless.txt" || fail 'launchd still exposes local SLURM_CONF'
cache_client "$scontrol" show node "$node_name" >"${run_dir}/node-cache-client.txt" ||
	fail 'client could not discover cached slurm.conf without SLURM_CONF'

submit_cpu v1 || fail 'configless CPU/hook-v1 job failed'
cpu_v1_job=$last_cpu_job
submit_gpu || fail 'configless GPU job failed'
/usr/bin/printf 'configless_initial=PASS pid=%s cpu_job=%s gpu_job=%s cache=%s\n' \
	"$configless_pid" "$cpu_v1_job" "$gpu_job" "$cache_link"
/usr/bin/printf 'SMD404_WAITING_FOR_CONTROLLER_UPDATE hook=v2 max_wait_seconds=600\n'
/usr/bin/printf 'On ubuntu2504 run: sudo env SMD404_CONFIGLESS_CHANGE_CONFIRMED=YES /bin/sh /tmp/smd404_ubuntu_configless_control.sh update\n'

hook_v1_hash=$(/usr/bin/shasum -a 256 "${cache_dir}/${hook_name}" | /usr/bin/awk '{ print $1 }')
attempt=0
while [ "$attempt" -lt 600 ]; do
	if /usr/bin/grep -Fqx 'SMD404_HOOK_VERSION=2' "${cache_dir}/${hook_name}" 2>/dev/null; then
		break
	fi
	/bin/sleep 1
	attempt=$((attempt + 1))
done
[ "$attempt" -lt 600 ] || fail 'controller hook-v2 update was not observed'
[ "$(launchd_pid)" = "$configless_pid" ] || fail 'slurmd PID changed during configless reconfigure'
hook_v2_hash=$(/usr/bin/shasum -a 256 "${cache_dir}/${hook_name}" | /usr/bin/awk '{ print $1 }')
[ "$hook_v1_hash" != "$hook_v2_hash" ] || fail 'cached hook hash did not change'
submit_cpu v2 || fail 'configless hook-v2 job failed'
cpu_v2_job=$last_cpu_job
/usr/bin/printf 'configless_update=PASS pid=%s hook_hash=%s->%s cpu_job=%s wait_seconds=%s\n' \
	"$configless_pid" "$hook_v1_hash" "$hook_v2_hash" "$cpu_v2_job" "$attempt"

/bin/mv "$hook_log" "${run_dir}/hook-events.txt" || fail 'cannot preserve hook evidence'
restore_local || fail 'cannot restore Mac local-mode production'
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
		found_addr = 0
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^NodeAddr=/) {
				$i = "NodeAddr=" addr
				found_addr = 1
			}
		}
		if (!found_addr)
			$0 = $0 " NodeAddr=" addr
		found_node = 1
	}
	{ print }
	END { if (!found_node) exit 1 }
' "$local_conf" >"$local_client_conf" || fail 'cannot create numeric NodeAddr client config'
/bin/chmod 0644 "$local_client_conf" || fail 'cannot set local client config mode'
/usr/bin/printf 'local_smoke_client_addr=%s client_config=%s\n' \
	"$node_ipv4" "$local_client_conf"
local_smoke_out=${output_dir}/local-smoke.out
local_smoke_err=${output_dir}/local-smoke.err
local_client /usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$local_client_conf" \
	"${prefix}/bin/srun" --partition="$partition" --nodelist="$node_name" \
	--nodes=1 --ntasks=1 --time=00:01:00 --chdir=/tmp /bin/hostname \
	>"$local_smoke_out" 2>"$local_smoke_err" || fail 'local-mode recovery smoke failed'
/usr/bin/grep -Fqx 'PC-210.local' "$local_smoke_out" || fail 'local recovery smoke output mismatch'
[ -z "$(local_client "$squeue" -h -w "$node_name")" ] || fail 'node has jobs after local restore'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD404_MAC_RUNTIME_COMPLETE cpu_v1_job=%s gpu_job=%s cpu_v2_job=%s old_pid=%s configless_pid=%s restored_pid=%s local_restore=PASS run_dir=%s backup=%s\n' \
	"$cpu_v1_job" "$gpu_job" "$cpu_v2_job" "$old_pid" "$configless_pid" \
	"$restored_pid" "$run_dir" "$backup_dir"
/usr/bin/printf 'NEXT_ON_UBUNTU: sudo env SMD404_CONFIGLESS_CHANGE_CONFIRMED=YES SMD404_MAC_LOCAL_RESTORED=YES /bin/sh /tmp/smd404_ubuntu_configless_control.sh restore\n'
