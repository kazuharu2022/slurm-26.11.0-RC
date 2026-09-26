#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu
umask 077

mode=${MODE:?MODE is required}
run_stamp=${RUN_STAMP:?RUN_STAMP is required}
case "$run_stamp" in
	*[!0-9T]*) printf '%s\n' 'error: invalid RUN_STAMP' >&2; exit 64 ;;
esac

PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib
export PATH LD_LIBRARY_PATH

prefix=/usr/local/slurm/26.11.0
production_conf=${prefix}/etc/slurm.conf
production_key=${prefix}/etc/slurm.key
binary=${prefix}/sbin/slurmctld
sackd_binary=${prefix}/sbin/sackd
scontrol_binary=${prefix}/bin/scontrol
expected_config=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
expected_binary=834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70
expected_key=70a580ae6b21d7ddc32f41e3959b024ea180e70e5a2244fb22774dcb45c55e7b
port=16837
slurmd_port=16838
base=/var/tmp/smd405-isolated-takeover-${run_stamp}
conf_dir=${base}/conf
local_dir=${base}/local
log_dir=${base}/daemon-log
conf=${conf_dir}/slurm.conf
key=${conf_dir}/slurm.key
state=/var/spool/slurm/slurmctld/smd405-isolated-takeover-${run_stamp}
pid_file=${local_dir}/slurmctld.pid
gdb_commands=${conf_dir}/gdb.commands
gdb_log=${log_dir}/gdb.txt
daemon_log=${log_dir}/slurmctld.log
sack_runtime=/run/slurm-smd405-isolated-${run_stamp}
sack_socket=${sack_runtime}/sack.socket

fail()
{
	printf 'SMD405_ISOLATED_PRIMARY_FAILED mode=%s error=%s base=%s\n' \
		"$mode" "$1" "$base" >&2
	exit 1
}

port_in_use()
{
	ss -H -ltn "sport = :${port}" | grep -q .
}

slurmd_port_in_use()
{
	ss -H -ltn "sport = :${slurmd_port}" | grep -q .
}

production_health()
{
	[ "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)" = \
		active,active,active ] || return 1
	[ "$(sha256sum "$production_conf" | awk '{print $1}')" = \
		"$expected_config" ] || return 1
	[ "$(sha256sum "$binary" | awk '{print $1}')" = \
		"$expected_binary" ] || return 1
	[ "$(sha256sum "$production_key" | awk '{print $1}')" = \
		"$expected_key" ] || return 1
	ping_output=$(scontrol ping 2>&1) || return 1
	printf '%s\n' "$ping_output" | \
		grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' || return 1
	printf '%s\n' "$ping_output" | \
		grep -Fq 'Slurmctld(backup) at slurmctld-bak is UP' || return 1
	if [ -d "$base" ]; then
		printf '%s\n' "$ping_output" >"${base}/production-ping-${mode}.txt"
	fi
	[ -z "$(squeue -h)" ] || return 1
	for node in ubuntu PC-210; do
		out=$(scontrol show node "$node") || return 1
		printf '%s\n' "$out" | grep -Eq \
			'(^|[[:space:]])State=IDLE([[:space:]]|$)' || return 1
		printf '%s\n' "$out" | grep -Eq \
			'(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' || return 1
	done
}

find_conf_pids()
{
	process_name=$1
	for candidate in $(pgrep -x "$process_name" 2>/dev/null || true); do
		[ -r "/proc/${candidate}/cmdline" ] || continue
		if tr '\000' ' ' <"/proc/${candidate}/cmdline" | grep -Fq "$conf"; then
			printf '%s\n' "$candidate"
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

write_isolated_config()
{
	awk -v state="$state" -v local_dir="$local_dir" -v log_dir="$log_dir" \
		-v port="$port" -v slurmd_port="$slurmd_port" '
	/^[[:space:]]*(#|$)/ { print; next }
	{
		key = $0
		sub(/=.*/, "", key)
		gsub(/[[:space:]]/, "", key)
		if (key ~ /^(ClusterName|SlurmctldHost|SlurmctldAddr|AuthInfo|AuthAltTypes|AuthAltParameters|SlurmctldPidFile|SlurmctldPort|SlurmdPidFile|SlurmdPort|SlurmdSpoolDir|StateSaveLocation|AccountingStorage.*|JobAcctGather.*|JobComp.*|Metrics.*|SlurmctldLogFile|SlurmdLogFile|SlurmctldParameters|SlurmctldTimeout|SlurmctldDebug|SlurmctldSyslogDebug|SlurmctldPrimaryOnProg|SlurmctldPrimaryOffProg|Prolog.*|Epilog.*|MailProg|ResumeProgram|SuspendProgram|RebootProgram|HealthCheckProgram|NodeName|PartitionName|GresTypes|TLSType)$/)
			next
		print
	}
	END {
		print ""
		print "# SMD-405 two-controller isolated takeover"
		print "ClusterName=smd405-isolated-takeover"
		print "SlurmctldHost=ubuntu2504(192.168.10.180)"
		print "SlurmctldHost=slurmctld-bak(192.168.10.118)"
		print "SlurmctldPort=" port
		print "SlurmdPort=" slurmd_port
		print "SlurmctldPidFile=" local_dir "/slurmctld.pid"
		print "SlurmdPidFile=" local_dir "/slurmd.pid"
		print "StateSaveLocation=" state
		print "SlurmdSpoolDir=" local_dir "/slurmd-spool"
		print "SlurmctldLogFile=" log_dir "/slurmctld.log"
		print "SlurmdLogFile=" log_dir "/slurmd.log"
		print "SlurmctldTimeout=10"
		print "SlurmctldDebug=debug2"
		print "AccountingStorageType=accounting_storage/none"
		print "JobAcctGatherType=jobacct_gather/none"
		print "JobCompType=jobcomp/none"
		print "AuthInfo=disable_sack"
		print "TLSType=tls/none"
		print "MailProg=/bin/true"
		print "NodeName=validate NodeAddr=127.0.0.1 CPUs=1 RealMemory=1024 State=FUTURE"
		print "PartitionName=validate Nodes=validate Default=YES MaxTime=INFINITE State=UP"
	}' "$production_conf" >"${conf}.tmp"
	mv -- "${conf}.tmp" "$conf"
}

case "$mode" in
preflight)
	[ "$(id -u)" -eq 0 ] || fail 'must run as root'
	[ "$(hostname -s)" = ubuntu2504 ] || fail 'unexpected hostname'
	[ ! -e "$base" ] || fail 'isolated base already exists'
	[ ! -e "$state" ] || fail 'isolated shared state already exists'
	port_in_use && fail 'isolated port is in use'
	slurmd_port_in_use && fail 'isolated slurmd port is in use'
	[ -x /usr/bin/gdb ] || fail 'gdb is absent'
	[ -x "$binary" ] || fail 'slurmctld is absent'
	[ -x "$sackd_binary" ] || fail 'sackd is absent'
	[ -x "$scontrol_binary" ] || fail 'scontrol is absent'
	production_health || fail 'production health failed'
	printf 'SMD405_ISOLATED_PRIMARY_PREFLIGHT_PASS production_pid=%s port=%s state_parent=%s\n' \
		"$(systemctl show slurmctld -p MainPID --value)" "$port" \
		"$(stat -c '%U:%G:%a' /var/spool/slurm/slurmctld)"
	;;
prepare)
	[ "$(id -u)" -eq 0 ] || fail 'must run as root'
	[ "$(hostname -s)" = ubuntu2504 ] || fail 'unexpected hostname'
	[ ! -e "$base" ] || fail 'isolated base already exists'
	[ ! -e "$state" ] || fail 'isolated shared state already exists'
	install -d -o root -g root -m 0755 "$base"
	install -d -o root -g slurm -m 0750 "$conf_dir"
	install -d -o slurm -g slurm -m 0700 "$local_dir" "$log_dir" "$state"
	install -d -o slurm -g slurm -m 0700 "${local_dir}/slurmd-spool"
	write_isolated_config
	chown root:slurm "$conf"
	chmod 0640 "$conf"
	install -o slurm -g slurm -m 0600 "$production_key" "$key"
	[ "$(sha256sum "$key" | awk '{print $1}')" = "$expected_key" ] || \
		fail 'isolated key hash mismatch'
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
thread apply all bt full
echo \n=== SHARED_LIBRARIES ===\n
info sharedlibrary
GDB
	chmod 0644 "$gdb_commands"
	cat >"${local_dir}/launch-gdb.sh" <<EOF
#!/bin/sh
set +e
/usr/bin/env SLURM_CONF='$conf' LD_LIBRARY_PATH='$LD_LIBRARY_PATH' \\
	/usr/bin/gdb -q -batch -x '$gdb_commands' --args \\
	'$binary' -D -c -f '$conf' >'$gdb_log' 2>&1
rc=\$?
printf '%s\\n' "\$rc" >'${local_dir}/gdb.rc'
exit 0
EOF
	chown slurm:slurm "${local_dir}/launch-gdb.sh"
	chmod 0750 "${local_dir}/launch-gdb.sh"
	sha256sum "$conf" >"${base}/config.sha256"
	printf 'SMD405_ISOLATED_PRIMARY_PREPARE_PASS base=%s state=%s config_sha256=%s\n' \
		"$base" "$state" "$(awk '{print $1}' "${base}/config.sha256")"
	;;
start)
	[ -f "$conf" ] || fail 'isolated config is absent'
	[ -f "$key" ] || fail 'isolated key is absent'
	port_in_use && fail 'isolated port is in use before start'
	/usr/bin/setsid /usr/sbin/runuser -u slurm -- \
		"${local_dir}/launch-gdb.sh" >/dev/null 2>&1 < /dev/null &
	launcher_pid=$!
	printf '%s\n' "$launcher_pid" >"${base}/gdb-launcher.pid"
	ready=0
	i=0
	while [ "$i" -lt 40 ]; do
		i=$((i + 1))
		if [ -s "$pid_file" ] && port_in_use; then
			isolated_pid=$(sed -n '1p' "$pid_file")
			if kill -0 "$isolated_pid" 2>/dev/null && \
				tr '\000' ' ' <"/proc/${isolated_pid}/cmdline" | grep -Fq "$conf"; then
				ready=1
				break
			fi
		fi
		kill -0 "$launcher_pid" 2>/dev/null || break
		sleep 1
	done
	[ "$ready" -eq 1 ] || fail 'isolated primary did not become ready'
	i=0
	while [ "$i" -lt 20 ] && [ ! -f "${state}/heartbeat" ]; do
		i=$((i + 1))
		sleep 1
	done
	[ -f "${state}/heartbeat" ] || fail 'isolated heartbeat is absent'
	printf 'SMD405_ISOLATED_PRIMARY_START_PASS pid=%s port=%s heartbeat=%s\n' \
		"$isolated_pid" "$port" "$(stat -c '%Y' "${state}/heartbeat")"
	;;
takeover)
	[ -f "$conf" ] || fail 'isolated config is absent'
	[ -f "$key" ] || fail 'isolated key is absent'
	[ -S /run/slurmctld/sack.socket ] || fail 'production SACK socket is absent'
	production_sack=$(stat -c '%d:%i:%f:%u:%g:%s:%Y' /run/slurmctld/sack.socket)
	[ ! -e "$sack_runtime" ] || fail 'isolated sack runtime exists'
	install -d -o slurm -g slurm -m 0755 "$sack_runtime"
	/usr/bin/setsid /usr/sbin/runuser -u slurm -- \
		/usr/bin/env SLURM_CONF="$conf" RUNTIME_DIRECTORY="$sack_runtime" \
		LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
		"$sackd_binary" -D --disable-reconfig --key-file "$key" -f "$conf" \
		>"${base}/sackd.txt" 2>&1 < /dev/null &
	sack_launcher=$!
	printf '%s\n' "$sack_launcher" >"${base}/sackd-launcher.pid"
	i=0
	while [ "$i" -lt 20 ] && [ ! -S "$sack_socket" ]; do
		i=$((i + 1))
		kill -0 "$sack_launcher" 2>/dev/null || fail 'isolated sackd exited'
		sleep 1
	done
	[ -S "$sack_socket" ] || fail 'isolated SACK socket is absent'
	set +e
	/usr/bin/timeout 30 /usr/bin/env SLURM_CONF="$conf" \
		SLURM_SACK_SOCKET="$sack_socket" LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
		"$scontrol_binary" takeover 1 >"${base}/takeover.txt" 2>&1
	takeover_rc=$?
	set -e
	printf '%s\n' "$takeover_rc" >"${base}/takeover.rc"
	stop_exact_processes sackd INT
	[ -S "$sack_socket" ] && rm -f -- "$sack_socket"
	rmdir -- "$sack_runtime" 2>/dev/null || true
	[ "$(stat -c '%d:%i:%f:%u:%g:%s:%Y' /run/slurmctld/sack.socket)" = \
		"$production_sack" ] || fail 'production SACK metadata changed'
	i=0
	while [ "$i" -lt 45 ] && [ ! -f "${local_dir}/gdb.rc" ]; do
		i=$((i + 1))
		sleep 1
	done
	[ -f "${local_dir}/gdb.rc" ] || fail 'gdb did not finish after takeover'
	printf 'SMD405_ISOLATED_PRIMARY_TAKEOVER_SENT takeover_rc=%s gdb_rc=%s\n' \
		"$takeover_rc" "$(sed -n '1p' "${local_dir}/gdb.rc")"
	;;
collect)
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
	takeover_rc=$(sed -n '1p' "${base}/takeover.rc")
	gdb_rc=$(sed -n '1p' "${local_dir}/gdb.rc")
	if [ "$rpc_observed" != YES ]; then
		result=INCONCLUSIVE_PRIMARY_RPC_NOT_OBSERVED
	elif [ "$sigabrt" = YES ] && [ "$fasttop" = YES ] && [ "$backtrace" = YES ]; then
		result=REPRODUCED_FASTTOP_WITH_BACKTRACE
	elif [ "$sigabrt" = YES ] && [ "$backtrace" = YES ]; then
		result=REPRODUCED_OTHER_SIGABRT_WITH_BACKTRACE
	elif [ "$sigabrt" = YES ]; then
		result=REPRODUCED_SIGABRT_BACKTRACE_MISSING
	elif [ "$normal_exit" = YES ] && [ "$takeover_rc" -eq 0 ]; then
		result=PRIMARY_CLEAN_AFTER_ISOLATED_TAKEOVER
	else
		result=INCONCLUSIVE_PRIMARY_EXIT
	fi
	printf 'result=%s\nrpc_observed=%s\ntakeover_rc=%s\nsigabrt=%s\nfasttop=%s\nbacktrace=%s\nnormal_exit=%s\ngdb_rc=%s\n' \
		"$result" "$rpc_observed" "$takeover_rc" "$sigabrt" "$fasttop" \
		"$backtrace" "$normal_exit" "$gdb_rc" | tee "${base}/result.env"
	;;
cleanup)
	stop_exact_processes sackd INT
	stop_exact_processes slurmctld TERM
	if [ -f "${base}/gdb-launcher.pid" ]; then
		launcher_pid=$(sed -n '1p' "${base}/gdb-launcher.pid")
		case "$launcher_pid" in ''|*[!0-9]*) ;; *) kill -TERM "$launcher_pid" 2>/dev/null || true ;; esac
	fi
	[ -S "$sack_socket" ] && rm -f -- "$sack_socket"
	[ -d "$sack_runtime" ] && rmdir -- "$sack_runtime" 2>/dev/null || true
	[ -f "$key" ] && rm -f -- "$key"
	printf 'SMD405_ISOLATED_PRIMARY_CLEANUP_PASS base=%s state_retained=%s key=REMOVED\n' \
		"$base" "$state"
	;;
postflight)
	[ ! -f "$key" ] || fail 'isolated key remains'
	[ -z "$(find_conf_pids slurmctld)" ] || fail 'isolated slurmctld remains'
	[ -z "$(find_conf_pids sackd)" ] || fail 'isolated sackd remains'
	port_in_use && fail 'isolated port remains'
	slurmd_port_in_use && fail 'isolated slurmd port remains'
	production_health || fail 'production health failed after cleanup'
	printf 'SMD405_ISOLATED_PRIMARY_POSTFLIGHT_PASS production_pid=%s port=%s queue=EMPTY nodes=IDLE\n' \
		"$(systemctl show slurmctld -p MainPID --value)" "$port"
	;;
*)
	printf 'error: unsupported MODE=%s\n' "$mode" >&2
	exit 64
	;;
esac
