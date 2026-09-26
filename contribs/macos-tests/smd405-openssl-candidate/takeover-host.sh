#!/bin/sh

# Candidate-only SMD-405 two-controller isolated takeover regression.
# Run manually as root on each Linux controller. Historical passwordless-sudo
# orchestration remains retired and must not be re-enabled.

set -eu
umask 077

if [ "${SMD405_OPENSSL_CANDIDATE_TAKEOVER_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_OPENSSL_CANDIDATE_TAKEOVER_CONFIRMED=YES after reviewing the isolated scope' >&2
	exit 64
fi

mode=${MODE:-}
run_stamp=${RUN_STAMP:-}
runtime_variant=${SMD405_RUNTIME_VARIANT:-full_candidate}
case "$mode" in
preflight|prepare|start|takeover|collect|cleanup|postflight) ;;
*) printf 'error: unsupported MODE=%s\n' "$mode" >&2; exit 64 ;;
esac
case "$runtime_variant" in
full_candidate|production_binary_three_artifact_overlay) ;;
*) printf 'error: unsupported SMD405_RUNTIME_VARIANT=%s\n' "$runtime_variant" >&2; exit 64 ;;
esac
case "$run_stamp" in
''|*[!0-9T]*) printf 'error: invalid RUN_STAMP=%s\n' "$run_stamp" >&2; exit 64 ;;
esac

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

host=$(hostname -s)
case "$host" in
ubuntu2504) role=primary ;;
slurmctld-bak) role=backup ;;
*) printf 'error: unexpected hostname=%s\n' "$host" >&2; exit 64 ;;
esac

production_prefix=/usr/local/slurm/26.11.0
production_binary=${production_prefix}/sbin/slurmctld
production_scontrol=${production_prefix}/bin/scontrol
production_squeue=${production_prefix}/bin/squeue
production_conf=${production_prefix}/etc/slurm.conf
production_key=${production_prefix}/etc/slurm.key
production_lib_path=${production_prefix}/lib/slurm:${production_prefix}/lib
backup_private_lib=/usr/local/slurm/26.11.0/lib/smd405-runtime/lib

candidate_stage_prefix=${SMD405_CANDIDATE_STAGE_PREFIX:-}
expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_production_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
expected_candidate_binary=8ca849849bbaafd25a85f3d21506f82bb0cd50c0370c631331e2334801668cee
expected_candidate_libslurmfull=791fa00eff4b949cfbb667fc250fc9b40e2e096f7494ad0d763138d62fea9391
expected_candidate_auth=536b07689bedad94cc8e663682b85db0d4e42391a86cc499e4f5895247ff3ee9
expected_candidate_auth_jwt=686057ecdca7c6476ddf44fefdb3b90014bf208fde39e759f2cf0c55e15f7167
expected_key=70a580ae6b21d7ddc32f41e3959b024ea180e70e5a2244fb22774dcb45c55e7b
if [ "$runtime_variant" = full_candidate ]; then
	expected_runtime_binary=$expected_candidate_binary
else
	expected_runtime_binary=$expected_production_binary
fi

isolated_port=16947
isolated_slurmd_port=16948
active_marker=/var/tmp/smd405-openssl-candidate-takeover-active
run_dir=/var/tmp/smd405-openssl-candidate-takeover-${run_stamp}
candidate_prefix=${run_dir}/candidate
candidate_lib_path=${candidate_prefix}/lib/slurm:${candidate_prefix}/lib
if [ "$role" = backup ]; then
	candidate_lib_path=${candidate_lib_path}:${backup_private_lib}:${production_prefix}/lib
fi
binary=${candidate_prefix}/sbin/slurmctld
sackd_binary=${candidate_prefix}/sbin/sackd
scontrol_binary=${candidate_prefix}/bin/scontrol
isolated_conf=${run_dir}/conf/slurm.conf
isolated_key=${run_dir}/conf/slurm.key
local_dir=${run_dir}/local
log_dir=${run_dir}/daemon-log
pid_file=${local_dir}/slurmctld.pid
daemon_log=${log_dir}/slurmctld.log
state=/var/spool/slurm/slurmctld/smd405-openssl-candidate-takeover-${run_stamp}
gdb_commands=${run_dir}/gdb.commands
gdb_log=${log_dir}/gdb.txt
gdb_rc_file=${local_dir}/gdb.rc
sack_runtime=/run/slurm-smd405-candidate-takeover-${run_stamp}
sack_socket=${sack_runtime}/sack.socket
sack_log=${run_dir}/sackd.txt
takeover_log=${run_dir}/takeover.txt

fail()
{
	printf 'SMD405_OPENSSL_CANDIDATE_TAKEOVER_FAILED host=%s role=%s mode=%s error=%s run_dir=%s\n' \
		"$host" "$role" "$mode" "$1" "$run_dir" >&2
	exit 1
}

port_in_use()
{
	ss -H -ltn | awk -v port=":${1}" \
		'$4 ~ port "$" { found = 1 } END { exit !found }'
}

production_command()
{
	env \
		PATH=${production_prefix}/bin:${production_prefix}/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
		LD_LIBRARY_PATH=$production_lib_path \
		SLURM_CONF=$production_conf \
		"$@"
}

socket_metadata()
{
	stat -c '%d:%i:%f:%u:%g:%s:%Y' /run/slurmctld/sack.socket
}

production_health_primary()
{
	[ "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)" = \
		active,active,active ] || return 1
	[ "$(sha256sum "$production_conf" | awk '{print $1}')" = \
		"$expected_config" ] || return 1
	[ "$(sha256sum "$production_binary" | awk '{print $1}')" = \
		"$expected_production_binary" ] || return 1
	[ "$(sha256sum "$production_key" | awk '{print $1}')" = \
		"$expected_key" ] || return 1
	ping_output=$(production_command "$production_scontrol" ping 2>&1) || return 1
	printf '%s\n' "$ping_output" | \
		grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' || return 1
	printf '%s\n' "$ping_output" | \
		grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' || return 1
	[ -z "$(production_command "$production_squeue" -h)" ] || return 1
	for node in ubuntu PC-210; do
		node_output=$(production_command "$production_scontrol" show node "$node") || \
			return 1
		printf '%s\n' "$node_output" | grep -Eq \
			'(^|[[:space:]])State=IDLE([[:space:]]|$)' || return 1
		printf '%s\n' "$node_output" | grep -Eq \
			'(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' || return 1
	done
	[ -S /run/slurmctld/sack.socket ] || return 1
}

production_health_backup()
{
	[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = active ] || return 1
	[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || return 1
	[ "$(sha256sum "$production_conf" | awk '{print $1}')" = \
		"$expected_config" ] || return 1
	[ "$(sha256sum "$production_binary" | awk '{print $1}')" = \
		"$expected_production_binary" ] || return 1
	[ "$(sha256sum "$production_key" | awk '{print $1}')" = \
		"$expected_key" ] || return 1
	[ -d "$backup_private_lib" ] || return 1
	[ "$(findmnt -T /var/spool/slurm/slurmctld -no FSTYPE)" = nfs4 ] || return 1
	findmnt -T /var/spool/slurm/slurmctld -no SOURCE | \
		grep -Fx '192.168.10.180:/var/spool/slurm/slurmctld' >/dev/null || \
		return 1
}

production_health()
{
	if [ "$role" = primary ]; then
		production_health_primary
	else
		production_health_backup
	fi
}

candidate_stage_health()
{
	[ -n "$candidate_stage_prefix" ] || return 1
	[ -x "${candidate_stage_prefix}/sbin/slurmctld" ] || return 1
	[ -x "${candidate_stage_prefix}/sbin/sackd" ] || return 1
	[ -x "${candidate_stage_prefix}/bin/scontrol" ] || return 1
	[ -f "${candidate_stage_prefix}/lib/slurm/libslurmfull.so" ] || return 1
	[ -f "${candidate_stage_prefix}/lib/slurm/auth_slurm.so" ] || return 1
	[ -f "${candidate_stage_prefix}/lib/slurm/auth_jwt.so" ] || return 1
	[ "$(sha256sum "${candidate_stage_prefix}/sbin/slurmctld" | awk '{print $1}')" = \
		"$expected_runtime_binary" ] || return 1
	[ "$(sha256sum "${candidate_stage_prefix}/lib/slurm/libslurmfull.so" | awk '{print $1}')" = \
		"$expected_candidate_libslurmfull" ] || return 1
	[ "$(sha256sum "${candidate_stage_prefix}/lib/slurm/auth_slurm.so" | awk '{print $1}')" = \
		"$expected_candidate_auth" ] || return 1
	[ "$(sha256sum "${candidate_stage_prefix}/lib/slurm/auth_jwt.so" | awk '{print $1}')" = \
		"$expected_candidate_auth_jwt" ] || return 1
}

find_conf_pids()
{
	process_name=$1
	for candidate_pid in $(pgrep -x "$process_name" 2>/dev/null || true); do
		[ -r "/proc/${candidate_pid}/cmdline" ] || continue
		if tr '\000' ' ' <"/proc/${candidate_pid}/cmdline" | \
			grep -Fq "$isolated_conf"; then
			printf '%s\n' "$candidate_pid"
		fi
	done
}

stop_exact_processes()
{
	process_name=$1
	signal=$2
	pids=$(find_conf_pids "$process_name")
	[ -n "$pids" ] || return 0
	for isolated_pid in $pids; do
		kill "-${signal}" "$isolated_pid" 2>/dev/null || true
	done
	i=0
	while [ "$i" -lt 15 ]; do
		i=$((i + 1))
		[ -z "$(find_conf_pids "$process_name")" ] && return 0
		sleep 1
	done
	for isolated_pid in $(find_conf_pids "$process_name"); do
		kill -KILL "$isolated_pid" 2>/dev/null || true
	done
}

stop_recorded_launcher()
{
	launcher_file=$1
	[ -f "$launcher_file" ] || return 0
	launcher_pid=$(sed -n '1p' "$launcher_file")
	case "$launcher_pid" in
	''|*[!0-9]*) return 0 ;;
	esac
	[ -r "/proc/${launcher_pid}/cmdline" ] || return 0
	if tr '\000' ' ' <"/proc/${launcher_pid}/cmdline" | grep -Fq "$run_dir"; then
		kill -TERM "$launcher_pid" 2>/dev/null || true
	else
		printf 'SECURITY_STOP: launcher PID %s does not match run directory; it was not signaled\n' \
			"$launcher_pid" >&2
		return 1
	fi
}

write_isolated_config()
{
	cat >"$isolated_conf" <<EOF
# SMD-405 OpenSSL candidate two-controller isolated takeover
ClusterName=smd405-openssl-candidate-takeover
SlurmctldHost=ubuntu2504(192.168.10.180)
SlurmctldHost=slurmctld-bak(192.168.10.118)
SlurmUser=slurm
SlurmctldPort=${isolated_port}
SlurmdPort=${isolated_slurmd_port}
SlurmctldPidFile=${pid_file}
SlurmdPidFile=${local_dir}/slurmd.pid
StateSaveLocation=${state}
SlurmdSpoolDir=${local_dir}/slurmd-spool
SlurmctldLogFile=${daemon_log}
SlurmdLogFile=${log_dir}/slurmd.log
SlurmctldDebug=debug2
PluginDir=${candidate_prefix}/lib/slurm
SlurmctldTimeout=10
AuthType=auth/slurm
AuthInfo=disable_sack
CredType=cred/slurm
TLSType=tls/none
AccountingStorageType=accounting_storage/none
JobAcctGatherType=jobacct_gather/none
JobCompType=jobcomp/none
SelectType=select/cons_tres
MailProg=/bin/true
NodeName=validate NodeAddr=127.0.0.1 CPUs=1 RealMemory=1024 State=FUTURE
PartitionName=validate Nodes=validate Default=YES MaxTime=INFINITE State=UP
EOF
	chown root:slurm "$isolated_conf"
	chmod 0640 "$isolated_conf"
}

validate_runtime_candidate()
{
	[ "$(sha256sum "$binary" | awk '{print $1}')" = \
		"$expected_runtime_binary" ] || return 1
	[ "$(sha256sum "${candidate_prefix}/lib/slurm/libslurmfull.so" | awk '{print $1}')" = \
		"$expected_candidate_libslurmfull" ] || return 1
	[ "$(sha256sum "${candidate_prefix}/lib/slurm/auth_slurm.so" | awk '{print $1}')" = \
		"$expected_candidate_auth" ] || return 1
	[ "$(sha256sum "${candidate_prefix}/lib/slurm/auth_jwt.so" | awk '{print $1}')" = \
		"$expected_candidate_auth_jwt" ] || return 1
	/usr/sbin/runuser -u slurm -- /usr/bin/test -x "$binary" || return 1
	/usr/sbin/runuser -u slurm -- /usr/bin/test -x "$sackd_binary" || return 1
	/usr/sbin/runuser -u slurm -- /usr/bin/test -x "$scontrol_binary" || return 1
	/usr/sbin/runuser -u slurm -- /usr/bin/test -r \
		"${candidate_prefix}/lib/slurm/libslurmfull.so" || return 1
	/usr/sbin/runuser -u slurm -- /usr/bin/test -r \
		"${candidate_prefix}/lib/slurm/auth_slurm.so" || return 1
	/usr/sbin/runuser -u slurm -- /usr/bin/test -r \
		"${candidate_prefix}/lib/slurm/auth_jwt.so" || return 1
}

validate_runtime_dependencies()
{
	dependency_log=${run_dir}/runtime-dependencies.txt
	{
		printf '%s\n' 'candidate_slurmctld_dependencies'
		env LD_LIBRARY_PATH="$candidate_lib_path" ldd "$binary"
		printf '%s\n' 'candidate_auth_and_cred_slurm_dependencies'
		env LD_LIBRARY_PATH="$candidate_lib_path" ldd \
			"${candidate_prefix}/lib/slurm/auth_slurm.so"
	} >"$dependency_log" 2>&1 || return 1
	if grep -Fq 'not found' "$dependency_log"; then
		return 1
	fi
	grep -Fq "libslurmfull.so => ${candidate_prefix}/lib/slurm/libslurmfull.so" \
		"$dependency_log" || return 1
	if grep -Fq 'libmunge.so' "$dependency_log"; then
		return 1
	fi
}

validate_candidate_process()
{
	isolated_pid=$1
	[ -n "$isolated_pid" ] || return 1
	case "$isolated_pid" in *[!0-9]*) return 1 ;; esac
	kill -0 "$isolated_pid" 2>/dev/null || return 1
	[ -r "/proc/${isolated_pid}/cmdline" ] || return 1
	tr '\000' ' ' <"/proc/${isolated_pid}/cmdline" | \
		grep -Fq "$isolated_conf" || return 1
	[ "$(ps -o user= -p "$isolated_pid" | tr -d ' ')" = slurm ] || return 1
	grep -Fq "${candidate_prefix}/lib/slurm/libslurmfull.so" \
		"/proc/${isolated_pid}/maps" || return 1
	grep -Fq "${candidate_prefix}/lib/slurm/auth_slurm.so" \
		"/proc/${isolated_pid}/maps" || return 1
}

wait_ready()
{
	launcher_pid=$1
	ready=0
	i=0
	while [ "$i" -lt 40 ]; do
		i=$((i + 1))
		if [ -s "$pid_file" ] && port_in_use "$isolated_port"; then
			isolated_pid=$(sed -n '1p' "$pid_file")
			if validate_candidate_process "$isolated_pid"; then
				ready=1
				break
			fi
		fi
		kill -0 "$launcher_pid" 2>/dev/null || break
		sleep 1
	done
	[ "$ready" -eq 1 ]
}

wait_helper_runtime()
{
	i=0
	while [ "$i" -lt 15 ]; do
		i=$((i + 1))
		grep -Fq 'disabled OpenSSL atexit cleanup' "$daemon_log" 2>/dev/null && \
			return 0
		sleep 1
	done
	return 1
}

case "$mode" in
preflight)
	[ "$(id -u)" -eq 0 ] || fail 'must run as root'
	[ ! -e "$run_dir" ] || fail 'run directory already exists'
	[ ! -e "$active_marker" ] || fail 'another candidate takeover marker exists'
	[ ! -e "$state" ] || fail 'isolated shared state already exists'
	port_in_use "$isolated_port" && fail 'isolated controller port is in use'
	port_in_use "$isolated_slurmd_port" && fail 'isolated slurmd port is in use'
	[ -x /usr/bin/setsid ] || fail 'setsid is absent'
	[ -x /usr/sbin/runuser ] || fail 'runuser is absent'
	[ -x /usr/bin/timeout ] || fail 'timeout is absent'
	[ -f "$production_conf" ] || fail 'production config is absent'
	[ -f "$production_key" ] || fail 'production auth key is absent'
	[ ! -L "$production_key" ] || fail 'SECURITY: production auth key is a symlink'
	[ -z "$(find "$production_key" -maxdepth 0 -perm /077 -print)" ] || \
		fail 'SECURITY: production auth key has group or other permissions'
	candidate_stage_health || fail 'candidate stage hash or artifact check failed'
	production_health || fail 'production health check failed'
	if [ "$role" = primary ]; then
		[ -x /usr/bin/gdb ] || fail 'gdb is absent'
		production_pid=$(systemctl show -p MainPID --value slurmctld)
	else
		production_pid=$(systemctl show -p MainPID --value slurmctld)
	fi
	printf 'SMD405_OPENSSL_CANDIDATE_TAKEOVER_PREFLIGHT_PASS host=%s role=%s production_pid=%s port=%s runtime_variant=%s runtime_binary=%s\n' \
		"$host" "$role" "$production_pid" "$isolated_port" \
		"$runtime_variant" "$expected_runtime_binary"
	;;
prepare)
	[ "$(id -u)" -eq 0 ] || fail 'must run as root'
	[ ! -e "$run_dir" ] || fail 'run directory already exists'
	[ ! -e "$active_marker" ] || fail 'another candidate takeover marker exists'
	if [ "$role" = primary ]; then
		[ ! -e "$state" ] || fail 'isolated shared state already exists'
	else
		[ -d "$state" ] || fail 'isolated shared state is not visible from backup'
	fi
	candidate_stage_health || fail 'candidate stage hash or artifact check failed'
	production_health || fail 'production health check failed before prepare'
	mkdir -m 0700 -- "$active_marker"
	prepare_complete=0
	prepare_cleanup()
	{
		rc=$?
		trap - EXIT HUP INT TERM
		if [ "$prepare_complete" -ne 1 ]; then
			rm -f -- "$isolated_key" 2>/dev/null || true
			rmdir -- "$active_marker" 2>/dev/null || true
		fi
		exit "$rc"
	}
	trap prepare_cleanup EXIT HUP INT TERM
	install -d -o root -g root -m 0755 "$run_dir"
	install -d -o root -g slurm -m 0750 "${run_dir}/conf"
	install -d -o slurm -g slurm -m 0700 "$local_dir" "$log_dir"
	install -d -o slurm -g slurm -m 0700 "${local_dir}/slurmd-spool"
	if [ "$role" = primary ]; then
		install -d -o slurm -g slurm -m 0700 "$state"
	fi
	cp -a -- "$candidate_stage_prefix" "$candidate_prefix"
	find "$candidate_prefix" -type d -exec chmod 0755 {} +
	validate_runtime_candidate || fail 'runtime candidate validation failed'
	validate_runtime_dependencies || fail 'candidate runtime dependency validation failed'
	write_isolated_config
	grep -Fxq "SlurmctldPort=${isolated_port}" "$isolated_conf" || \
		fail 'isolated port missing from config'
	grep -Fxq "StateSaveLocation=${state}" "$isolated_conf" || \
		fail 'isolated state missing from config'
	grep -Fxq 'AccountingStorageType=accounting_storage/none' "$isolated_conf" || \
		fail 'isolated accounting setting missing'
	grep -Fxq 'CredType=cred/slurm' "$isolated_conf" || \
		fail 'isolated cred/slurm setting missing'
	if grep -Eq 'SlurmctldPort=6817|SlurmdPort=6818|accounting_storage/slurmdbd|enable_configless' \
		"$isolated_conf"; then
		fail 'SECURITY: production endpoint or plugin leaked into isolated config'
	fi
	install -o slurm -g slurm -m 0600 -- "$production_key" "$isolated_key"
	[ "$(sha256sum "$isolated_key" | awk '{print $1}')" = "$expected_key" ] || \
		fail 'isolated auth key copy hash mismatch'
	printf '%s\n' "$(systemctl show -p MainPID --value slurmctld)" \
		>"${run_dir}/production-ctld-pid.before"
	if [ "$role" = primary ]; then
		printf '%s\n' \
			"$(systemctl show -p MainPID --value slurmdbd)" \
			>"${run_dir}/production-slurmdbd-pid.before"
		printf '%s\n' \
			"$(systemctl show -p MainPID --value slurmd)" \
			>"${run_dir}/production-slurmd-pid.before"
		socket_metadata >"${run_dir}/production-sack.before"
		cat >"$gdb_commands" <<'GDB'
set pagination off
set confirm off
set print thread-events off
handle SIGPIPE nostop noprint pass
handle SIGTERM nostop noprint pass
handle SIGUSR1 nostop noprint pass
handle SIGUSR2 nostop noprint pass
handle SIGABRT stop print nopass
run
echo \n=== THREAD_BACKTRACES ===\n
thread apply all bt
echo \n=== REGISTERS ===\n
info registers
echo \n=== SHARED_LIBRARIES ===\n
info sharedlibrary
GDB
		chmod 0644 "$gdb_commands"
		cat >"${local_dir}/launch-gdb.sh" <<EOF
#!/bin/sh
set +e
/usr/bin/env SLURM_CONF='$isolated_conf' LD_LIBRARY_PATH='$candidate_lib_path' \\
	/usr/bin/gdb -q -batch -x '$gdb_commands' --args \\
	'$binary' -D -c -f '$isolated_conf' >'$gdb_log' 2>&1
rc=\$?
printf '%s\\n' "\$rc" >'$gdb_rc_file'
exit 0
EOF
		chown slurm:slurm "${local_dir}/launch-gdb.sh"
		chmod 0750 "${local_dir}/launch-gdb.sh"
	fi
	sha256sum "$isolated_conf" >"${run_dir}/config.sha256"
	{
		printf 'host=%s\nrole=%s\n' "$host" "$role"
		printf 'runtime_variant=%s\n' "$runtime_variant"
		printf 'runtime_binary_sha256=%s\n' "$expected_runtime_binary"
		printf 'candidate_libslurmfull_sha256=%s\n' "$expected_candidate_libslurmfull"
		printf 'candidate_auth_sha256=%s\n' "$expected_candidate_auth"
		printf 'candidate_auth_jwt_sha256=%s\n' "$expected_candidate_auth_jwt"
		printf 'key_sha256=%s\n' "$expected_key"
	} >"${run_dir}/metadata.txt"
	prepare_complete=1
	trap - EXIT HUP INT TERM
	printf 'SMD405_OPENSSL_CANDIDATE_TAKEOVER_PREPARE_PASS host=%s role=%s config_sha256=%s state=%s key=COPIED_PRIVATE\n' \
		"$host" "$role" "$(awk '{print $1}' "${run_dir}/config.sha256")" "$state"
	;;
start)
	[ -d "$active_marker" ] || fail 'active marker is absent'
	[ -f "$isolated_conf" ] || fail 'isolated config is absent'
	[ -f "$isolated_key" ] || fail 'isolated key is absent'
	validate_runtime_candidate || fail 'runtime candidate validation failed'
	/usr/sbin/runuser -u slurm -- /usr/bin/test -w "$log_dir" || \
		fail 'SlurmUser cannot write the candidate log directory'
	/usr/sbin/runuser -u slurm -- /usr/bin/test -w "$local_dir" || \
		fail 'SlurmUser cannot write the candidate local directory'
	port_in_use "$isolated_port" && fail 'isolated controller port is in use before start'
	if [ "$role" = primary ]; then
		/usr/bin/setsid /usr/sbin/runuser -u slurm -- \
			"${local_dir}/launch-gdb.sh" >/dev/null 2>&1 < /dev/null &
		launcher_pid=$!
		printf '%s\n' "$launcher_pid" >"${run_dir}/launcher.pid"
		wait_ready "$launcher_pid" || fail 'candidate primary did not become ready under gdb'
	else
		/usr/bin/setsid /usr/sbin/runuser -u slurm -- \
			/usr/bin/env SLURM_CONF="$isolated_conf" \
			LD_LIBRARY_PATH="$candidate_lib_path" \
			"$binary" -D -c -f "$isolated_conf" \
			>"${run_dir}/stdout.txt" 2>&1 < /dev/null &
		launcher_pid=$!
		printf '%s\n' "$launcher_pid" >"${run_dir}/launcher.pid"
		wait_ready "$launcher_pid" || fail 'candidate backup did not become ready'
	fi
	isolated_pid=$(sed -n '1p' "$pid_file")
	production_pid=$(sed -n '1p' "${run_dir}/production-ctld-pid.before")
	[ "$isolated_pid" != "$production_pid" ] || \
		fail 'SECURITY: candidate PID equals production PID'
	wait_helper_runtime || fail 'OpenSSL helper runtime log was not observed'
	if [ "$role" = primary ]; then
		i=0
		while [ "$i" -lt 20 ] && [ ! -f "${state}/heartbeat" ]; do
			i=$((i + 1))
			sleep 1
		done
		[ -f "${state}/heartbeat" ] || fail 'shared heartbeat was not created'
	else
		background=0
		i=0
		while [ "$i" -lt 30 ]; do
			i=$((i + 1))
			if grep -Fq 'slurmctld running in background mode' "$daemon_log" 2>/dev/null; then
				background=1
				break
			fi
			sleep 1
		done
		[ "$background" -eq 1 ] || fail 'candidate backup background marker is absent'
		if grep -Fq 'Running as primary controller' "$daemon_log"; then
			fail 'candidate backup entered primary role before takeover'
		fi
	fi
	production_health || fail 'production health changed during candidate start'
	printf 'SMD405_OPENSSL_CANDIDATE_TAKEOVER_START_PASS host=%s role=%s pid=%s helper_runtime=YES mode=%s\n' \
		"$host" "$role" "$isolated_pid" \
		"$(if [ "$role" = primary ]; then printf GDB_PRIMARY; else printf BACKGROUND_BACKUP; fi)"
	;;
takeover)
	[ "$role" = primary ] || fail 'takeover mode is primary-only'
	[ -f "$isolated_conf" ] || fail 'isolated config is absent'
	[ -f "$isolated_key" ] || fail 'isolated key is absent'
	isolated_pid=$(sed -n '1p' "$pid_file")
	validate_candidate_process "$isolated_pid" || \
		fail 'candidate primary process validation failed immediately before takeover'
	production_pid=$(sed -n '1p' "${run_dir}/production-ctld-pid.before")
	[ "$isolated_pid" != "$production_pid" ] || \
		fail 'SECURITY: takeover target equals production PID'
	port_in_use "$isolated_port" || fail 'isolated controller port is not listening'
	production_health || fail 'production health failed immediately before takeover'
	[ ! -e "$sack_runtime" ] || fail 'isolated SACK runtime already exists'
	install -d -o slurm -g slurm -m 0755 "$sack_runtime"
	/usr/bin/setsid /usr/sbin/runuser -u slurm -- \
		/usr/bin/env SLURM_CONF="$isolated_conf" \
		RUNTIME_DIRECTORY="$sack_runtime" \
		LD_LIBRARY_PATH="$candidate_lib_path" \
		"$sackd_binary" -D --disable-reconfig --key-file "$isolated_key" \
		-f "$isolated_conf" >"$sack_log" 2>&1 < /dev/null &
	sack_launcher=$!
	printf '%s\n' "$sack_launcher" >"${run_dir}/sackd-launcher.pid"
	i=0
	while [ "$i" -lt 20 ] && [ ! -S "$sack_socket" ]; do
		i=$((i + 1))
		kill -0 "$sack_launcher" 2>/dev/null || fail 'candidate sackd exited'
		sleep 1
	done
	[ -S "$sack_socket" ] || fail 'candidate SACK socket is absent'
	/usr/bin/timeout 20 /usr/bin/env SLURM_CONF="$isolated_conf" \
		SLURM_SACK_SOCKET="$sack_socket" LD_LIBRARY_PATH="$candidate_lib_path" \
		"$scontrol_binary" ping >"${run_dir}/isolated-ping.txt" 2>&1 || \
		fail 'candidate two-controller ping failed'
	grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
		"${run_dir}/isolated-ping.txt" || fail 'candidate primary is not UP'
	grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' \
		"${run_dir}/isolated-ping.txt" || fail 'candidate backup is not UP'
	set +e
	/usr/bin/timeout 30 /usr/bin/env SLURM_CONF="$isolated_conf" \
		SLURM_SACK_SOCKET="$sack_socket" LD_LIBRARY_PATH="$candidate_lib_path" \
		"$scontrol_binary" takeover 1 >"$takeover_log" 2>&1
	takeover_rc=$?
	set -e
	printf '%s\n' "$takeover_rc" >"${run_dir}/takeover.rc"
	stop_exact_processes sackd INT
	rm -f -- "$sack_socket"
	rmdir -- "$sack_runtime" 2>/dev/null || true
	i=0
	while [ "$i" -lt 45 ] && [ ! -f "$gdb_rc_file" ]; do
		i=$((i + 1))
		sleep 1
	done
	[ -f "$gdb_rc_file" ] || fail 'primary gdb did not finish after takeover'
	printf 'SMD405_OPENSSL_CANDIDATE_TAKEOVER_SENT takeover_rc=%s gdb_rc=%s\n' \
		"$takeover_rc" "$(sed -n '1p' "$gdb_rc_file")"
	;;
collect)
	[ -f "$isolated_conf" ] || fail 'isolated config is absent'
	if [ "$role" = primary ]; then
		rpc_observed=NO
		sigabrt=NO
		fasttop=NO
		backtrace=NO
		normal_exit=NO
		grep -Fq 'Performing RPC: REQUEST_SHUTDOWN' "$daemon_log" && rpc_observed=YES
		grep -Eq 'Program received signal SIGABRT|received signal SIGABRT' "$gdb_log" && sigabrt=YES
		grep -Fq 'double free or corruption (fasttop)' "$gdb_log" && fasttop=YES
		grep -Eq '^#0[[:space:]]' "$gdb_log" && backtrace=YES
		grep -Eq 'exited normally|exited with code 0' "$gdb_log" && normal_exit=YES
		takeover_rc=$(sed -n '1p' "${run_dir}/takeover.rc")
		gdb_rc=$(sed -n '1p' "$gdb_rc_file")
		if [ "$rpc_observed" != YES ]; then
			result=INCONCLUSIVE_PRIMARY_RPC_NOT_OBSERVED
		elif [ "$sigabrt" = YES ] && [ "$fasttop" = YES ] && [ "$backtrace" = YES ]; then
			result=REPRODUCED_FASTTOP_WITH_BACKTRACE
		elif [ "$sigabrt" = YES ] && [ "$backtrace" = YES ]; then
			result=REPRODUCED_OTHER_SIGABRT_WITH_BACKTRACE
		elif [ "$sigabrt" = YES ]; then
			result=REPRODUCED_SIGABRT_BACKTRACE_MISSING
		elif [ "$normal_exit" = YES ] && [ "$takeover_rc" -eq 0 ]; then
			result=PRIMARY_CLEAN_AFTER_CANDIDATE_TAKEOVER
		else
			result=INCONCLUSIVE_PRIMARY_EXIT
		fi
		printf 'result=%s\nrpc_observed=%s\ntakeover_rc=%s\nsigabrt=%s\nfasttop=%s\nbacktrace=%s\nnormal_exit=%s\ngdb_rc=%s\nhelper_runtime=YES\n' \
			"$result" "$rpc_observed" "$takeover_rc" "$sigabrt" "$fasttop" \
			"$backtrace" "$normal_exit" "$gdb_rc" | tee "${run_dir}/result.env"
	else
		takeover_observed=NO
		primary_role=NO
		process_alive=NO
		i=0
		while [ "$i" -lt 45 ]; do
			i=$((i + 1))
			grep -Fq 'Performing background RPC: REQUEST_TAKEOVER' "$daemon_log" 2>/dev/null && \
				takeover_observed=YES
			grep -Fq 'Running as primary controller' "$daemon_log" 2>/dev/null && \
				primary_role=YES
			[ -n "$(find_conf_pids slurmctld)" ] && process_alive=YES || process_alive=NO
			[ "$takeover_observed" = YES ] && [ "$primary_role" = YES ] && \
				[ "$process_alive" = YES ] && break
			sleep 1
		done
		printf 'takeover_observed=%s\nprimary_role=%s\nprocess_alive=%s\nhelper_runtime=YES\n' \
			"$takeover_observed" "$primary_role" "$process_alive" | \
			tee "${run_dir}/result.env"
	fi
	;;
cleanup)
	stop_exact_processes sackd INT
	stop_exact_processes slurmctld TERM
	stop_recorded_launcher "${run_dir}/sackd-launcher.pid" || \
		fail 'candidate sackd launcher did not match run directory'
	stop_recorded_launcher "${run_dir}/launcher.pid" || \
		fail 'candidate controller launcher did not match run directory'
	[ -S "$sack_socket" ] && rm -f -- "$sack_socket"
	[ -d "$sack_runtime" ] && rmdir -- "$sack_runtime" 2>/dev/null || true
	[ -f "$isolated_key" ] && rm -f -- "$isolated_key"
	[ -d "$active_marker" ] && rmdir -- "$active_marker"
	chmod -R a+rX "$run_dir" 2>/dev/null || true
	printf 'SMD405_OPENSSL_CANDIDATE_TAKEOVER_CLEANUP_PASS host=%s role=%s key=REMOVED run_dir=%s\n' \
		"$host" "$role" "$run_dir"
	;;
postflight)
	[ ! -f "$isolated_key" ] || fail 'isolated key remains'
	[ ! -e "$active_marker" ] || fail 'active marker remains'
	[ -z "$(find_conf_pids slurmctld)" ] || fail 'candidate slurmctld remains'
	[ -z "$(find_conf_pids sackd)" ] || fail 'candidate sackd remains'
	port_in_use "$isolated_port" && fail 'isolated controller port remains'
	port_in_use "$isolated_slurmd_port" && fail 'isolated slurmd port remains'
	production_health || fail 'production health failed after cleanup'
	production_pid_before=$(sed -n '1p' "${run_dir}/production-ctld-pid.before")
	production_pid_after=$(systemctl show -p MainPID --value slurmctld)
	[ "$production_pid_after" = "$production_pid_before" ] || \
		fail 'production slurmctld PID changed'
	if [ "$role" = primary ]; then
		[ "$(systemctl show -p MainPID --value slurmdbd)" = \
			"$(sed -n '1p' "${run_dir}/production-slurmdbd-pid.before")" ] || \
			fail 'production slurmdbd PID changed'
		[ "$(systemctl show -p MainPID --value slurmd)" = \
			"$(sed -n '1p' "${run_dir}/production-slurmd-pid.before")" ] || \
			fail 'production slurmd PID changed'
		[ "$(socket_metadata)" = \
			"$(sed -n '1p' "${run_dir}/production-sack.before")" ] || \
			fail 'production SACK metadata changed'
	fi
	printf 'SMD405_OPENSSL_CANDIDATE_TAKEOVER_POSTFLIGHT_PASS host=%s role=%s production_pid=%s production=UNCHANGED queue=EMPTY nodes=IDLE jobs=NONE\n' \
		"$host" "$role" "$production_pid_after"
	;;
esac
