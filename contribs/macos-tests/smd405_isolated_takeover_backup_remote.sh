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
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib/smd405-runtime/lib:/usr/local/slurm/26.11.0/lib
export PATH LD_LIBRARY_PATH

prefix=/usr/local/slurm/26.11.0
production_conf=${prefix}/etc/slurm.conf
production_key=${prefix}/etc/slurm.key
binary=${prefix}/sbin/slurmctld
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
daemon_log=${log_dir}/slurmctld.log

fail()
{
	printf 'SMD405_ISOLATED_BACKUP_FAILED mode=%s error=%s base=%s\n' \
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

find_conf_pids()
{
	for candidate in $(pgrep -x slurmctld 2>/dev/null || true); do
		[ -r "/proc/${candidate}/cmdline" ] || continue
		if tr '\000' ' ' <"/proc/${candidate}/cmdline" | grep -Fq "$conf"; then
			printf '%s\n' "$candidate"
		fi
	done
}

stop_exact_processes()
{
	pids=$(find_conf_pids)
	[ -n "$pids" ] || return 0
	for isolated_pid in $pids; do
		kill -TERM "$isolated_pid" 2>/dev/null || true
	done
	i=0
	while [ "$i" -lt 15 ]; do
		i=$((i + 1))
		[ -z "$(find_conf_pids)" ] && return 0
		sleep 1
	done
	for isolated_pid in $(find_conf_pids); do
		kill -KILL "$isolated_pid" 2>/dev/null || true
	done
}

production_health()
{
	[ "$(systemctl is-active slurmctld 2>/dev/null || true)" = active ] || return 1
	[ "$(systemctl is-enabled slurmctld 2>/dev/null || true)" = disabled ] || return 1
	[ "$(sha256sum "$production_conf" | awk '{print $1}')" = \
		"$expected_config" ] || return 1
	[ "$(sha256sum "$binary" | awk '{print $1}')" = \
		"$expected_binary" ] || return 1
	[ "$(sha256sum "$production_key" | awk '{print $1}')" = \
		"$expected_key" ] || return 1
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
	[ "$(hostname -s)" = slurmctld-bak ] || fail 'unexpected hostname'
	[ ! -e "$base" ] || fail 'isolated base already exists'
	[ ! -e "$state" ] || fail 'isolated shared state already exists before primary prepare'
	port_in_use && fail 'isolated port is in use'
	slurmd_port_in_use && fail 'isolated slurmd port is in use'
	[ -d /usr/local/slurm/26.11.0/lib/smd405-runtime/lib ] || \
		fail 'private runtime libraries are absent'
	[ "$(findmnt -T /var/spool/slurm/slurmctld -no FSTYPE)" = nfs4 ] || \
		fail 'shared state is not NFSv4'
	findmnt -T /var/spool/slurm/slurmctld -no SOURCE | \
		grep -Fx '192.168.10.180:/var/spool/slurm/slurmctld' >/dev/null || \
		fail 'shared state source mismatch'
	production_health || fail 'production backup health failed'
	printf 'SMD405_ISOLATED_BACKUP_PREFLIGHT_PASS production_pid=%s port=%s mount=NFS4_RW\n' \
		"$(systemctl show slurmctld -p MainPID --value)" "$port"
	;;
prepare)
	[ "$(id -u)" -eq 0 ] || fail 'must run as root'
	[ "$(hostname -s)" = slurmctld-bak ] || fail 'unexpected hostname'
	[ ! -e "$base" ] || fail 'isolated base already exists'
	[ -d "$state" ] || fail 'isolated shared state is not visible'
	install -d -o root -g root -m 0755 "$base"
	install -d -o root -g slurm -m 0750 "$conf_dir"
	install -d -o slurm -g slurm -m 0700 "$local_dir" "$log_dir"
	install -d -o slurm -g slurm -m 0700 "${local_dir}/slurmd-spool"
	write_isolated_config
	chown root:slurm "$conf"
	chmod 0640 "$conf"
	install -o slurm -g slurm -m 0600 "$production_key" "$key"
	[ "$(sha256sum "$key" | awk '{print $1}')" = "$expected_key" ] || \
		fail 'isolated key hash mismatch'
	sha256sum "$conf" >"${base}/config.sha256"
	printf 'SMD405_ISOLATED_BACKUP_PREPARE_PASS base=%s state=%s config_sha256=%s\n' \
		"$base" "$state" "$(awk '{print $1}' "${base}/config.sha256")"
	;;
start)
	[ -f "$conf" ] || fail 'isolated config is absent'
	[ -f "$key" ] || fail 'isolated key is absent'
	port_in_use && fail 'isolated port is in use before start'
	/usr/bin/setsid /usr/sbin/runuser -u slurm -- \
		/usr/bin/env SLURM_CONF="$conf" LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
		"$binary" -D -c -f "$conf" >"${base}/stdout.txt" 2>&1 < /dev/null &
	launcher_pid=$!
	printf '%s\n' "$launcher_pid" >"${base}/launcher.pid"
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
	[ "$ready" -eq 1 ] || fail 'isolated backup did not become ready'
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
	[ "$background" -eq 1 ] || fail 'isolated backup background marker is absent'
	if grep -Fq 'Running as primary controller' "$daemon_log"; then
		fail 'isolated backup entered primary role before takeover'
	fi
	printf 'SMD405_ISOLATED_BACKUP_START_PASS pid=%s port=%s mode=BACKGROUND\n' \
		"$isolated_pid" "$port"
	;;
collect)
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
		[ -n "$(find_conf_pids)" ] && process_alive=YES || process_alive=NO
		[ "$takeover_observed" = YES ] && [ "$primary_role" = YES ] && \
			[ "$process_alive" = YES ] && break
		sleep 1
	done
	printf 'takeover_observed=%s\nprimary_role=%s\nprocess_alive=%s\nproduction_service=%s\nproduction_enabled=%s\n' \
		"$takeover_observed" "$primary_role" "$process_alive" \
		"$(systemctl is-active slurmctld 2>/dev/null || true)" \
		"$(systemctl is-enabled slurmctld 2>/dev/null || true)" | \
		tee "${base}/result.env"
	;;
cleanup)
	stop_exact_processes
	if [ -f "${base}/launcher.pid" ]; then
		launcher_pid=$(sed -n '1p' "${base}/launcher.pid")
		case "$launcher_pid" in ''|*[!0-9]*) ;; *) kill -TERM "$launcher_pid" 2>/dev/null || true ;; esac
	fi
	[ -f "$key" ] && rm -f -- "$key"
	printf 'SMD405_ISOLATED_BACKUP_CLEANUP_PASS base=%s key=REMOVED\n' "$base"
	;;
postflight)
	[ ! -f "$key" ] || fail 'isolated key remains'
	[ -z "$(find_conf_pids)" ] || fail 'isolated backup remains'
	port_in_use && fail 'isolated port remains'
	slurmd_port_in_use && fail 'isolated slurmd port remains'
	production_health || fail 'production backup health failed after cleanup'
	printf 'SMD405_ISOLATED_BACKUP_POSTFLIGHT_PASS production_pid=%s service=active,disabled port=%s\n' \
		"$(systemctl show slurmctld -p MainPID --value)" "$port"
	;;
*)
	printf 'error: unsupported MODE=%s\n' "$mode" >&2
	exit 64
	;;
esac
