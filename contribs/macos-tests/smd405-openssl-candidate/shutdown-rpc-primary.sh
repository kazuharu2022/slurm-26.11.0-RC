#!/bin/sh

# Candidate-only SMD-405 authenticated shutdown RPC regression. This is a new bounded
# harness; retired historical drivers remain disabled.

set -eu

if [ "${SMD405_OPENSSL_CANDIDATE_RPC_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_OPENSSL_CANDIDATE_RPC_CONFIRMED=YES after reviewing the isolated scope' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

production_prefix=/usr/local/slurm/26.11.0
production_binary=${production_prefix}/sbin/slurmctld
production_scontrol=${production_prefix}/bin/scontrol
production_squeue=${production_prefix}/bin/squeue
production_conf=${production_prefix}/etc/slurm.conf
production_key=${production_prefix}/etc/slurm.key
production_lib_path=${production_prefix}/lib/slurm:${production_prefix}/lib

candidate_build_root=${SMD405_CANDIDATE_BUILD_ROOT:-/var/tmp/smd405-openssl-candidate.SEL4sg}
candidate_stage_prefix=${candidate_build_root}/stage${production_prefix}
stage_binary=${candidate_stage_prefix}/sbin/slurmctld
stage_sackd_binary=${candidate_stage_prefix}/sbin/sackd
stage_scontrol_binary=${candidate_stage_prefix}/bin/scontrol
stage_libslurmfull=${candidate_stage_prefix}/lib/slurm/libslurmfull.so
stage_auth_plugin=${candidate_stage_prefix}/lib/slurm/auth_slurm.so
expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_production_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
expected_candidate_binary=8ca849849bbaafd25a85f3d21506f82bb0cd50c0370c631331e2334801668cee
expected_candidate_libslurmfull=791fa00eff4b949cfbb667fc250fc9b40e2e096f7494ad0d763138d62fea9391
expected_candidate_auth=536b07689bedad94cc8e663682b85db0d4e42391a86cc499e4f5895247ff3ee9
expected_key=70a580ae6b21d7ddc32f41e3959b024ea180e70e5a2244fb22774dcb45c55e7b
isolated_port=16937
isolated_slurmd_port=16938
active_marker=/var/tmp/smd405-openssl-candidate-rpc-active
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/var/tmp/smd405-openssl-candidate-rpc-${run_stamp}
candidate_prefix=${run_dir}/candidate
candidate_lib_path=${candidate_prefix}/lib/slurm:${candidate_prefix}/lib
binary=${candidate_prefix}/sbin/slurmctld
sackd_binary=${candidate_prefix}/sbin/sackd
scontrol_binary=${candidate_prefix}/bin/scontrol
isolated_conf=${run_dir}/conf/slurm.conf
client_conf=${run_dir}/conf/client.conf
isolated_key=${run_dir}/conf/slurm.key
isolated_pid_file=${run_dir}/state/slurmctld.pid
gdb_commands=${run_dir}/gdb.commands
gdb_log=${run_dir}/gdb.txt
sackd_runtime=/run/slurm-smd405-candidate-rpc-${run_stamp}
sackd_socket=${sackd_runtime}/sack.socket
sackd_log=${run_dir}/sackd.txt
rpc_log=${run_dir}/shutdown-rpc.txt
gdb_launcher_pid=
isolated_pid=
sackd_launcher_pid=
sackd_pid=
marker_acquired=0
finished=0

fail()
{
	printf 'SMD405_OPENSSL_CANDIDATE_RPC_FAILED error=%s run_dir=%s\n' \
		"$1" "$run_dir" >&2
	exit 1
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

production_health()
{
	label=$1
	out=${run_dir}/${label}-production-health.txt
	{
		date --iso-8601=seconds
		printf 'services=%s\n' \
			"$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)"
		printf 'pids=%s,%s,%s\n' \
			"$(systemctl show -p MainPID --value slurmctld)" \
			"$(systemctl show -p MainPID --value slurmdbd)" \
			"$(systemctl show -p MainPID --value slurmd)"
		printf 'config_sha256=%s\n' "$(sha256sum "$production_conf" | awk '{print $1}')"
		printf 'binary_sha256=%s\n' "$(sha256sum "$production_binary" | awk '{print $1}')"
		printf 'key_sha256=%s\n' "$(sha256sum "$production_key" | awk '{print $1}')"
		printf 'sack=%s\n' "$(socket_metadata)"
		printf '%s\n' 'controller_ping_begin'
		production_command "$production_scontrol" ping
		printf '%s\n' 'controller_ping_end'
		printf 'queue_rows=%s\n' \
			"$(production_command "$production_squeue" -h | wc -l | tr -d ' ')"
		for node in ubuntu PC-210; do
			production_command "$production_scontrol" show node "$node" | \
				awk -v node="$node" '
				/(^|[[:space:]])State=/ || /(^|[[:space:]])CPUAlloc=/ {
					for (i = 1; i <= NF; i++) {
						if ($i ~ /^State=/ || $i ~ /^CPUAlloc=/)
							printf "%s_%s\n", node, $i
					}
				}'
		done
	} >"$out" 2>&1 || return 1

	grep -Fq 'services=active,active,active' "$out" || return 1
	grep -Fq "config_sha256=${expected_config}" "$out" || return 1
	grep -Fq "binary_sha256=${expected_production_binary}" "$out" || return 1
	grep -Fq "key_sha256=${expected_key}" "$out" || return 1
	grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' "$out" || return 1
	grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' "$out" || return 1
	grep -Fq 'queue_rows=0' "$out" || return 1
	for node in ubuntu PC-210; do
		grep -Fq "${node}_State=IDLE" "$out" || return 1
		grep -Fq "${node}_CPUAlloc=0" "$out" || return 1
	done
}

find_isolated_sackd_pids()
{
	for candidate_pid in $(pgrep -x sackd 2>/dev/null || true); do
		[ -r "/proc/${candidate_pid}/cmdline" ] || continue
		if tr '\000' ' ' <"/proc/${candidate_pid}/cmdline" | \
			grep -Fq "$client_conf"; then
			printf '%s\n' "$candidate_pid"
		fi
	done
}

stop_isolated_sackd()
{
	if [ -n "$sackd_pid" ] && kill -0 "$sackd_pid" 2>/dev/null; then
		if [ -r "/proc/${sackd_pid}/cmdline" ] && \
			tr '\000' ' ' <"/proc/${sackd_pid}/cmdline" | grep -Fq "$client_conf"; then
			kill -INT "$sackd_pid" 2>/dev/null || true
			i=0
			while kill -0 "$sackd_pid" 2>/dev/null && [ "$i" -lt 10 ]; do
				i=$((i + 1))
				sleep 1
			done
			if kill -0 "$sackd_pid" 2>/dev/null; then
				kill -KILL "$sackd_pid" 2>/dev/null || true
			fi
		else
			printf '%s\n' \
				'SECURITY_STOP: residual sackd PID did not match isolated client config; it was not signaled' >&2
			return 1
		fi
	fi
	sackd_pid=

	if [ -n "$sackd_launcher_pid" ]; then
		if kill -0 "$sackd_launcher_pid" 2>/dev/null; then
			kill -INT "$sackd_launcher_pid" 2>/dev/null || true
		fi
		wait "$sackd_launcher_pid" 2>/dev/null || true
		sackd_launcher_pid=
	fi

	if [ -S "$sackd_socket" ]; then
		rm -f -- "$sackd_socket" || return 1
	fi
	if [ -d "$sackd_runtime" ]; then
		rmdir -- "$sackd_runtime" 2>/dev/null || return 1
	fi
	return 0
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	set +e

	if [ -n "$isolated_pid" ] && kill -0 "$isolated_pid" 2>/dev/null; then
		if [ -r "/proc/${isolated_pid}/cmdline" ] && \
			tr '\000' ' ' <"/proc/${isolated_pid}/cmdline" | grep -Fq "$isolated_conf"; then
			kill -TERM "$isolated_pid" 2>/dev/null || true
			i=0
			while kill -0 "$isolated_pid" 2>/dev/null && [ "$i" -lt 10 ]; do
				i=$((i + 1))
				sleep 1
			done
			kill -KILL "$isolated_pid" 2>/dev/null || true
		else
			printf '%s\n' \
				'SECURITY_STOP: residual PID did not match the isolated config; it was not signaled' >&2
			rc=1
		fi
	fi

	if [ -n "$gdb_launcher_pid" ] && kill -0 "$gdb_launcher_pid" 2>/dev/null; then
		kill -TERM "$gdb_launcher_pid" 2>/dev/null || true
	fi
	stop_isolated_sackd || rc=1
	if [ -f "$isolated_key" ]; then
		rm -f -- "$isolated_key" || rc=1
	fi
	if [ "$marker_acquired" -eq 1 ]; then
		rmdir -- "$active_marker" 2>/dev/null || rc=1
	fi
	if [ -d "$run_dir" ]; then
		chmod -R a+rX "$run_dir" 2>/dev/null || true
	fi

	if [ "$finished" -ne 1 ] && [ -d "$run_dir" ]; then
		production_health cleanup-after >/dev/null 2>&1 || true
	fi
	exit "$rc"
}

[ "$(id -u)" -eq 0 ] || fail 'must run as root'
[ "$(hostname -s)" = ubuntu2504 ] || fail 'unexpected host'
[ -x "$production_binary" ] || fail 'production slurmctld binary is absent'
[ -x "$production_scontrol" ] || fail 'production scontrol binary is absent'
[ -x "$production_squeue" ] || fail 'production squeue binary is absent'
[ -x "$stage_binary" ] || fail 'staged candidate slurmctld is absent'
[ -x "$stage_sackd_binary" ] || fail 'staged candidate sackd is absent'
[ -x "$stage_scontrol_binary" ] || fail 'staged candidate scontrol is absent'
[ -f "$stage_libslurmfull" ] || fail 'staged candidate libslurmfull is absent'
[ -f "$stage_auth_plugin" ] || fail 'staged candidate auth/slurm plugin is absent'
[ "$(sha256sum "$production_binary" | awk '{print $1}')" = \
	"$expected_production_binary" ] || fail 'production slurmctld hash mismatch'
[ "$(sha256sum "$stage_binary" | awk '{print $1}')" = \
	"$expected_candidate_binary" ] || fail 'candidate slurmctld hash mismatch'
[ "$(sha256sum "$stage_libslurmfull" | awk '{print $1}')" = \
	"$expected_candidate_libslurmfull" ] || fail 'candidate libslurmfull hash mismatch'
[ "$(sha256sum "$stage_auth_plugin" | awk '{print $1}')" = \
	"$expected_candidate_auth" ] || fail 'candidate auth/slurm hash mismatch'
[ -x /usr/bin/gdb ] || fail 'gdb is absent'
[ -x /usr/bin/setsid ] || fail 'setsid is absent'
[ -x /usr/bin/timeout ] || fail 'timeout is absent'
[ -x /usr/bin/test ] || fail 'test command is absent'
[ -x /usr/sbin/runuser ] || fail 'runuser is absent'
[ -f "$production_conf" ] || fail 'production config is absent'
[ -f "$production_key" ] || fail 'production auth key is absent'
[ ! -L "$production_key" ] || fail 'SECURITY: production auth key must not be a symlink'
[ -z "$(find "$production_key" -maxdepth 0 -perm /077 -print)" ] || \
	fail 'SECURITY: production auth key has group or other permissions'
[ ! -e "$active_marker" ] || fail 'another isolated reproduction marker exists'

if ss -H -ltn | awk -v port=":${isolated_port}" '$4 ~ port "$" { found = 1 } END { exit !found }'; then
	fail 'isolated controller port is already listening'
fi
if ss -H -ltn | awk -v port=":${isolated_slurmd_port}" '$4 ~ port "$" { found = 1 } END { exit !found }'; then
	fail 'isolated slurmd port is already listening'
fi

mkdir -m 0700 -- "$active_marker"
marker_acquired=1
trap cleanup EXIT HUP INT TERM
mkdir -m 0755 -- "$run_dir"
mkdir -m 0750 -- "${run_dir}/conf"
mkdir -m 0700 -- "${run_dir}/state" "${run_dir}/spool" "${run_dir}/daemon-log"
chown root:slurm "${run_dir}/conf"
chown slurm:slurm "${run_dir}/state" "${run_dir}/spool" "${run_dir}/daemon-log"

cp -a -- "$candidate_stage_prefix" "$candidate_prefix"
find "$candidate_prefix" -type d -exec chmod 0755 {} +
[ "$(sha256sum "$binary" | awk '{print $1}')" = \
	"$expected_candidate_binary" ] || fail 'runtime candidate slurmctld hash mismatch'
[ "$(sha256sum "${candidate_prefix}/lib/slurm/libslurmfull.so" | awk '{print $1}')" = \
	"$expected_candidate_libslurmfull" ] || fail 'runtime candidate libslurmfull hash mismatch'
[ "$(sha256sum "${candidate_prefix}/lib/slurm/auth_slurm.so" | awk '{print $1}')" = \
	"$expected_candidate_auth" ] || fail 'runtime candidate auth/slurm hash mismatch'
/usr/sbin/runuser -u slurm -- /usr/bin/test -x "$binary" || \
	fail 'SlurmUser cannot execute runtime candidate slurmctld'
/usr/sbin/runuser -u slurm -- /usr/bin/test -x "$sackd_binary" || \
	fail 'SlurmUser cannot execute runtime candidate sackd'
/usr/sbin/runuser -u slurm -- /usr/bin/test -x "$scontrol_binary" || \
	fail 'SlurmUser cannot execute runtime candidate scontrol'
/usr/sbin/runuser -u slurm -- /usr/bin/test -r \
	"${candidate_prefix}/lib/slurm/libslurmfull.so" || \
	fail 'SlurmUser cannot read runtime candidate libslurmfull'
/usr/sbin/runuser -u slurm -- /usr/bin/test -r \
	"${candidate_prefix}/lib/slurm/auth_slurm.so" || \
	fail 'SlurmUser cannot read runtime candidate auth/slurm plugin'

production_health before || fail 'production preflight failed'
production_pids_before=$(awk -F= '$1 == "pids" { print $2; exit }' \
	"${run_dir}/before-production-health.txt")
sack_before=$(awk -F= '$1 == "sack" { print $2; exit }' \
	"${run_dir}/before-production-health.txt")
production_ctld_pid=$(printf '%s\n' "$production_pids_before" | cut -d, -f1)
[ -n "$production_ctld_pid" ] && [ "$production_ctld_pid" -gt 1 ] || \
	fail 'invalid production slurmctld PID'
pgrep -x slurmctld >"${run_dir}/before-slurmctld-pids.txt"
[ "$(wc -l <"${run_dir}/before-slurmctld-pids.txt" | tr -d ' ')" -eq 1 ] || \
	fail 'unexpected extra slurmctld process before isolation'
grep -Fxq "$production_ctld_pid" "${run_dir}/before-slurmctld-pids.txt" || \
	fail 'production slurmctld PID does not match process list'

cat >"$isolated_conf" <<EOF
# SMD-405 OpenSSL candidate isolated authenticated RPC configuration
ClusterName=smd405-openssl-candidate-rpc
SlurmctldHost=ubuntu2504(127.0.0.1)
SlurmctldHost=slurmctld-bak(192.0.2.2)
SlurmUser=slurm
SlurmctldPort=${isolated_port}
SlurmdPort=${isolated_slurmd_port}
SlurmctldPidFile=${run_dir}/state/slurmctld.pid
SlurmdPidFile=${run_dir}/state/slurmd.pid
StateSaveLocation=${run_dir}/state
SlurmdSpoolDir=${run_dir}/spool
SlurmctldLogFile=${run_dir}/daemon-log/slurmctld.log
SlurmdLogFile=${run_dir}/daemon-log/slurmd.log
SlurmctldDebug=debug2
PluginDir=${candidate_prefix}/lib/slurm
SlurmctldTimeout=10
AuthType=auth/slurm
AuthInfo=disable_sack
AccountingStorageType=accounting_storage/none
JobAcctGatherType=jobacct_gather/none
SelectType=select/cons_tres
MailProg=/bin/true
NodeName=validate NodeAddr=127.0.0.1 CPUs=1 RealMemory=1024 State=FUTURE
PartitionName=validate Nodes=validate Default=YES MaxTime=INFINITE State=UP
EOF
chown root:root "$isolated_conf"
chmod 0644 "$isolated_conf"

awk '
	$0 == "SlurmctldHost=slurmctld-bak(192.0.2.2)" { next }
	{ print }
' "$isolated_conf" >"$client_conf"
chown root:slurm "$client_conf"
chmod 0640 "$client_conf"

grep -Ev '^[[:space:]]*(#|$)' "$isolated_conf" >"${run_dir}/isolated-active-config.txt"
if grep -Eq '(/var/spool/slurm/slurmctld|/var/run/slurm/slurmctld\.pid|192\.168\.10\.(118|180)|SlurmctldPort=6817|SlurmdPort=6818|enable_configless|accounting_storage/slurmdbd)' \
	"${run_dir}/isolated-active-config.txt"; then
	fail 'SECURITY: production endpoint or state path leaked into isolated config'
fi
grep -Fxq 'AuthInfo=disable_sack' "${run_dir}/isolated-active-config.txt" || \
	fail 'isolated SACK disable setting is absent'
grep -Fxq "StateSaveLocation=${run_dir}/state" "${run_dir}/isolated-active-config.txt" || \
	fail 'isolated state path is absent'
grep -Fxq "PluginDir=${candidate_prefix}/lib/slurm" \
	"${run_dir}/isolated-active-config.txt" || fail 'candidate PluginDir is absent'
grep -Fxq 'SlurmctldHost=ubuntu2504(127.0.0.1)' "$client_conf" || \
	fail 'isolated client controller address is absent'
[ "$(grep -c '^SlurmctldHost=' "$client_conf")" -eq 1 ] || \
	fail 'isolated client config must contain exactly one controller'
if grep -Eq 'SlurmctldHost=.*(192\.0\.2\.2|192\.168\.10\.(118|180))' \
	"$client_conf"; then
	fail 'SECURITY: isolated client config contains a non-loopback controller'
fi
install -o slurm -g slurm -m 0600 -- "$production_key" "$isolated_key"
[ "$(sha256sum "$isolated_key" | awk '{print $1}')" = "$expected_key" ] || \
	fail 'isolated auth key copy hash mismatch'

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

printf 'isolated_config_sha256=%s\n' "$(sha256sum "$isolated_conf" | awk '{print $1}')" \
	>"${run_dir}/isolated-metadata.txt"
printf 'client_config_sha256=%s\n' "$(sha256sum "$client_conf" | awk '{print $1}')" \
	>>"${run_dir}/isolated-metadata.txt"
printf 'production_binary_sha256=%s\n' "$expected_production_binary" \
	>>"${run_dir}/isolated-metadata.txt"
printf 'candidate_binary_sha256=%s\n' "$expected_candidate_binary" \
	>>"${run_dir}/isolated-metadata.txt"
printf 'candidate_libslurmfull_sha256=%s\n' "$expected_candidate_libslurmfull" \
	>>"${run_dir}/isolated-metadata.txt"
printf 'candidate_auth_slurm_sha256=%s\n' "$expected_candidate_auth" \
	>>"${run_dir}/isolated-metadata.txt"
printf 'candidate_sackd_sha256=%s\n' "$(sha256sum "$sackd_binary" | awk '{print $1}')" \
	>>"${run_dir}/isolated-metadata.txt"
printf 'candidate_scontrol_sha256=%s\n' "$(sha256sum "$scontrol_binary" | awk '{print $1}')" \
	>>"${run_dir}/isolated-metadata.txt"
printf 'key_sha256=%s\n' "$expected_key" >>"${run_dir}/isolated-metadata.txt"
printf 'isolated_ports=%s,%s\n' "$isolated_port" "$isolated_slurmd_port" \
	>>"${run_dir}/isolated-metadata.txt"
printf 'production_pids_before=%s\n' "$production_pids_before" \
	>>"${run_dir}/isolated-metadata.txt"
printf 'sack_before=%s\n' "$sack_before" >>"${run_dir}/isolated-metadata.txt"

/usr/bin/setsid /usr/sbin/runuser -u slurm -- \
	/usr/bin/env "SLURM_CONF=${isolated_conf}" \
	"LD_LIBRARY_PATH=${candidate_lib_path}" \
	/usr/bin/gdb -q -batch -x "$gdb_commands" --args \
	"$binary" -D -c -f "$isolated_conf" >"$gdb_log" 2>&1 &
gdb_launcher_pid=$!
printf '%s\n' "$gdb_launcher_pid" >"${run_dir}/gdb-launcher.pid"

ready=0
i=0
while [ "$i" -lt 30 ]; do
	i=$((i + 1))
	if [ -s "$isolated_pid_file" ]; then
		isolated_pid=$(sed -n '1p' "$isolated_pid_file")
		case "$isolated_pid" in
		''|*[!0-9]*) isolated_pid= ;;
		esac
		if [ -n "$isolated_pid" ] && kill -0 "$isolated_pid" 2>/dev/null && \
			ss -H -ltn | awk -v port=":${isolated_port}" \
			'$4 ~ port "$" { found = 1 } END { exit !found }'; then
			ready=1
			break
		fi
	fi
	if ! kill -0 "$gdb_launcher_pid" 2>/dev/null; then
		break
	fi
	sleep 1
done
[ "$ready" -eq 1 ] || fail 'isolated slurmctld did not become ready under gdb'
[ "$isolated_pid" != "$production_ctld_pid" ] || fail 'SECURITY: isolated PID equals production PID'
tr '\000' ' ' <"/proc/${isolated_pid}/cmdline" >"${run_dir}/isolated-cmdline.txt"
grep -Fq "$isolated_conf" "${run_dir}/isolated-cmdline.txt" || \
	fail 'SECURITY: isolated PID command line does not contain isolated config'
[ "$(ps -o user= -p "$isolated_pid" | tr -d ' ')" = slurm ] || \
	fail 'isolated slurmctld is not running as SlurmUser'

grep -F "$candidate_prefix" "/proc/${isolated_pid}/maps" \
	>"${run_dir}/candidate-runtime-maps.txt"
grep -Fq "${candidate_prefix}/lib/slurm/libslurmfull.so" \
	"${run_dir}/candidate-runtime-maps.txt" || \
	fail 'isolated process did not load candidate libslurmfull'
grep -Fq "${candidate_prefix}/lib/slurm/auth_slurm.so" \
	"${run_dir}/candidate-runtime-maps.txt" || \
	fail 'isolated process did not load candidate auth/slurm plugin'

helper_runtime=NO
i=0
while [ "$i" -lt 10 ]; do
	i=$((i + 1))
	if grep -Fq 'disabled OpenSSL atexit cleanup' \
		"${run_dir}/daemon-log/slurmctld.log"; then
		helper_runtime=YES
		break
	fi
	sleep 1
done
[ "$helper_runtime" = YES ] || fail 'OpenSSL atexit helper runtime log was not observed'

i=0
while [ "$i" -lt 15 ] && [ ! -f "${run_dir}/state/heartbeat" ]; do
	i=$((i + 1))
	sleep 1
done
[ -f "${run_dir}/state/heartbeat" ] || fail 'isolated backup heartbeat file was not created'
stat -c 'heartbeat=%d:%i:%s:%Y' "${run_dir}/state/heartbeat" \
	>"${run_dir}/isolated-heartbeat.txt"

{
	date --iso-8601=seconds
	printf 'production_ctld_pid=%s\n' "$production_ctld_pid"
	printf 'isolated_ctld_pid=%s\n' "$isolated_pid"
	printf 'production_service=%s\n' "$(systemctl is-active slurmctld)"
	printf 'sack_during=%s\n' "$(socket_metadata)"
	production_command "$production_scontrol" ping
	ss -H -ltn | awk '$4 ~ /:(6817|16937)$/ { print }'
} >"${run_dir}/during-isolation.txt" 2>&1
grep -Fq 'production_service=active' "${run_dir}/during-isolation.txt" || \
	fail 'production slurmctld changed state during isolation'
grep -Fq "sack_during=${sack_before}" "${run_dir}/during-isolation.txt" || \
	fail 'SECURITY: production SACK socket metadata changed during isolation'
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' "${run_dir}/during-isolation.txt" || \
	fail 'production primary became unavailable during isolation'
grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' "${run_dir}/during-isolation.txt" || \
	fail 'production backup became unavailable during isolation'

mkdir -m 0755 -- "$sackd_runtime"
chown slurm:slurm "$sackd_runtime"

/usr/bin/setsid /usr/sbin/runuser -u slurm -- \
	/usr/bin/env \
	"SLURM_CONF=${client_conf}" \
	"RUNTIME_DIRECTORY=${sackd_runtime}" \
	"LD_LIBRARY_PATH=${candidate_lib_path}" \
	"$sackd_binary" -D --disable-reconfig \
	--key-file "$isolated_key" \
	-f "$client_conf" >"$sackd_log" 2>&1 &
sackd_launcher_pid=$!

i=0
while [ "$i" -lt 20 ] && [ ! -S "$sackd_socket" ]; do
	i=$((i + 1))
	kill -0 "$sackd_launcher_pid" 2>/dev/null || \
		fail 'isolated candidate sackd exited before socket creation'
	sleep 1
done
[ -S "$sackd_socket" ] || fail 'isolated candidate sackd socket was not created'

sackd_pids=$(find_isolated_sackd_pids)
sackd_count=$(printf '%s\n' "$sackd_pids" | sed '/^$/d' | wc -l | tr -d ' ')
[ "$sackd_count" -eq 1 ] || fail 'isolated candidate sackd PID count is not one'
sackd_pid=$(printf '%s\n' "$sackd_pids" | sed -n '1p')
[ "$(ps -o user= -p "$sackd_pid" | tr -d ' ')" = slurm ] || \
	fail 'isolated candidate sackd is not running as SlurmUser'

[ -r "/proc/${isolated_pid}/cmdline" ] || fail 'isolated PID disappeared before RPC'
tr '\000' ' ' <"/proc/${isolated_pid}/cmdline" | grep -Fq "$isolated_conf" || \
	fail 'SECURITY: RPC target no longer matches isolated config'
[ "$isolated_pid" != "$production_ctld_pid" ] || \
	fail 'SECURITY: RPC target equals production PID'
ss -H -ltn | awk -v port=":${isolated_port}" \
	'$4 ~ port "$" { found = 1 } END { exit !found }' || \
	fail 'isolated port is not listening immediately before RPC'

printf 'rpc_epoch=%s\n' "$(date '+%s')" >>"${run_dir}/isolated-metadata.txt"
set +e
/usr/bin/timeout 20 /usr/bin/env \
	"SLURM_CONF=${client_conf}" \
	"SLURM_SACK_SOCKET=${sackd_socket}" \
	"LD_LIBRARY_PATH=${candidate_lib_path}" \
	"$scontrol_binary" shutdown controller >"$rpc_log" 2>&1
rpc_rc=$?
set -e
printf 'rpc_rc=%s\n' "$rpc_rc" >>"${run_dir}/isolated-metadata.txt"

i=0
while kill -0 "$gdb_launcher_pid" 2>/dev/null && [ "$i" -lt 30 ]; do
	i=$((i + 1))
	sleep 1
done
if kill -0 "$gdb_launcher_pid" 2>/dev/null; then
	fail 'gdb did not finish after isolated shutdown RPC'
fi
set +e
wait "$gdb_launcher_pid"
gdb_rc=$?
set -e
gdb_launcher_pid=
printf 'gdb_rc=%s\n' "$gdb_rc" >>"${run_dir}/isolated-metadata.txt"
stop_isolated_sackd || fail 'isolated candidate sackd cleanup failed'

if kill -0 "$isolated_pid" 2>/dev/null; then
	fail 'isolated slurmctld remained after gdb completion'
fi
isolated_pid=
if ss -H -ltn | awk -v port=":${isolated_port}" '$4 ~ port "$" { found = 1 } END { exit !found }'; then
	fail 'isolated controller port remained open'
fi

abort=NO
fasttop=NO
backtrace=NO
normal_exit=NO
rpc_observed=NO
grep -Eq 'Program received signal SIGABRT|received signal SIGABRT' "$gdb_log" && abort=YES
grep -Fq 'double free or corruption (fasttop)' "$gdb_log" && fasttop=YES
grep -Eq '^#0[[:space:]]' "$gdb_log" && backtrace=YES
grep -Eq 'exited normally|exited with code 0' "$gdb_log" && normal_exit=YES
if grep -Fq 'Performing RPC: REQUEST_SHUTDOWN' \
	"${run_dir}/daemon-log/slurmctld.log"; then
	rpc_observed=YES
fi

if [ "$rpc_observed" != YES ]; then
	result=INCONCLUSIVE_RPC_NOT_OBSERVED
elif [ "$abort" = YES ] && [ "$fasttop" = YES ] && [ "$backtrace" = YES ]; then
	result=REPRODUCED_FASTTOP_WITH_BACKTRACE
elif [ "$abort" = YES ] && [ "$backtrace" = YES ]; then
	result=REPRODUCED_OTHER_SIGABRT_WITH_BACKTRACE
elif [ "$abort" = YES ]; then
	result=REPRODUCED_SIGABRT_BACKTRACE_MISSING
elif [ "$normal_exit" = YES ] && [ "$rpc_rc" -eq 0 ]; then
	result=NOT_REPRODUCED_CLEAN_RPC_SHUTDOWN
elif [ "$normal_exit" = YES ]; then
	result=RPC_OBSERVED_CLEAN_SHUTDOWN_CLIENT_ERROR
else
	result=INCONCLUSIVE_NO_SIGABRT
fi

{
	printf 'result=%s\n' "$result"
	printf 'sigabrt=%s\n' "$abort"
	printf 'fasttop=%s\n' "$fasttop"
	printf 'backtrace=%s\n' "$backtrace"
	printf 'normal_exit=%s\n' "$normal_exit"
	printf 'rpc_observed=%s\n' "$rpc_observed"
	printf 'rpc_rc=%s\n' "$rpc_rc"
	printf 'openssl_helper_runtime=%s\n' "$helper_runtime"
	printf 'gdb_rc=%s\n' "$gdb_rc"
} >"${run_dir}/result.env"

production_health after || fail 'production postflight failed'
production_pids_after=$(awk -F= '$1 == "pids" { print $2; exit }' \
	"${run_dir}/after-production-health.txt")
sack_after=$(awk -F= '$1 == "sack" { print $2; exit }' \
	"${run_dir}/after-production-health.txt")
[ "$production_pids_after" = "$production_pids_before" ] || \
	fail 'production daemon PID changed'
[ "$sack_after" = "$sack_before" ] || \
	fail 'SECURITY: production SACK socket metadata changed'
pgrep -x slurmctld >"${run_dir}/after-slurmctld-pids.txt"
[ "$(wc -l <"${run_dir}/after-slurmctld-pids.txt" | tr -d ' ')" -eq 1 ] || \
	fail 'unexpected extra slurmctld process after isolation'
grep -Fxq "$production_ctld_pid" "${run_dir}/after-slurmctld-pids.txt" || \
	fail 'production slurmctld PID changed in process list'

rm -f -- "$isolated_key"
rmdir -- "$active_marker"
marker_acquired=0
chmod -R a+rX "$run_dir"
finished=1
trap - EXIT HUP INT TERM
printf 'SMD405_OPENSSL_CANDIDATE_RPC_RESULT result=%s helper_runtime=%s rpc_observed=%s rpc_rc=%s production=UNCHANGED sack=UNCHANGED queue=EMPTY nodes=IDLE jobs=NONE run_dir=%s\n' \
	"$result" "$helper_runtime" "$rpc_observed" "$rpc_rc" "$run_dir"
[ "$result" = NOT_REPRODUCED_CLEAN_RPC_SHUTDOWN ] || {
	printf 'SMD405_OPENSSL_CANDIDATE_RPC_FAILED result=%s run_dir=%s\n' \
		"$result" "$run_dir" >&2
	exit 1
}
printf '%s\n' 'SMD405_OPENSSL_CANDIDATE_RPC_COMPLETE'
