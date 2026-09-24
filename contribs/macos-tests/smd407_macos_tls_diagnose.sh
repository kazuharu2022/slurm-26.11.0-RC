#!/bin/sh

set -u

mode=${1:-}
case "$mode" in
client|daemon) ;;
*) /usr/bin/printf 'usage: %s client|daemon\n' "$0" >&2; exit 64 ;;
esac

if [ "${SMD407_TLS_DIAG_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD407_TLS_DIAG_CONFIRMED=YES after approving the no-job TLS diagnosis' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
slurm_key=${prefix}/etc/slurm.key
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
plugin=${prefix}/lib/slurm/tls_s2n.so
certgen_plugin=${prefix}/lib/slurm/certgen_script.so
s2n_prefix=${prefix}/lib/slurm-s2n-1.7.9
ca=${prefix}/etc/ca_cert.pem
slurmd_cert=${prefix}/etc/slurmd_cert.pem
slurmd_key=${prefix}/etc/slurmd_cert_key.pem
inactive_state=${prefix}/.smd407-mac-tls-inactive.env
runtime_state=${prefix}/.smd407-mac-tls-runtime.env
plugin_hash=f1b17c47b94c6ea3a86478a4f35493b30dff1f2d0941a45490e63381dd23cfa3
certgen_plugin_hash=aa36683403a51dcf9baba1190e0ee3ed2b8f81c4c4972229ce924e05bae25ce4
libs2n_hash=b0d957ad211cdeaaa996795b04c2dbe3238575b1b37f17719758b75c434c894a
runtime_state_hash=fee2df1c8a9d6baf76eb3d294583b58609106ad885a6e45cb9f8bcf0349d3aa1
service_target=system/org.schedmd.slurmd
pid_file=/var/run/slurmd.pid
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-mac-tls-diagnose-${mode}-${run_stamp}
success=0
config_installed=0
original_config_hash=

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
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
	old_pid=$(managed_slurmd_pid 2>/dev/null || true)
	/bin/launchctl kickstart -k "$service_target" \
		>"${run_dir}/${label}-kickstart.out" 2>"${run_dir}/${label}-kickstart.err" || return 1
	attempt=0
	while [ "$attempt" -lt 90 ]; do
		new_pid=$(managed_slurmd_pid 2>/dev/null || true)
		if [ -n "$new_pid" ] && { [ -z "$old_pid" ] || [ "$new_pid" != "$old_pid" ]; }; then
			/usr/bin/printf 'slurmd_restarted phase=%s old_pid=%s new_pid=%s wait_seconds=%s\n' \
				"$label" "${old_pid:-ABSENT}" "$new_pid" "$attempt"
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
	tmp_file=${target_file}.smd407-diagnose.$$
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
	/^[[:space:]]*DebugFlags=/ {
		if (tolower($0) !~ /(^|,)tls(,|$)/) $0 = $0 ",TLS"
		seen_debug = 1
		print
		next
	}
	{ print }
	END {
		if (!seen_communication) print "CommunicationParameters=disable_http"
		if (!seen_debug) print "DebugFlags=TLS"
		print "CertgenType=certgen/script"
		print "TLSType=tls/s2n"
		print "TLSParameters=ca_cert_file=" prefix "/etc/ca_cert.pem,slurmd_cert_file=" prefix "/etc/slurmd_cert.pem,slurmd_cert_key_file=" prefix "/etc/slurmd_cert_key.pem"
	}
	' "$source_file" >"$target_file"
}

run_ping_with_timeout()
{
	config=$1
	label=$2
	status_file=${run_dir}/${label}.status
	(
		SLURM_CONF="$config" "$scontrol" -vvvvvv ping \
			>"${run_dir}/${label}.out" 2>"${run_dir}/${label}.err"
		/usr/bin/printf '%s\n' "$?" >"$status_file"
	) &
	command_pid=$!
	attempt=0
	while [ "$attempt" -lt 30 ]; do
		if ! /bin/kill -0 "$command_pid" >/dev/null 2>&1; then
			wait "$command_pid" >/dev/null 2>&1 || true
			[ -f "$status_file" ] || return 125
			return "$(/bin/cat "$status_file")"
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	/bin/kill -TERM "$command_pid" >/dev/null 2>&1 || true
	/bin/sleep 1
	/bin/kill -KILL "$command_pid" >/dev/null 2>&1 || true
	wait "$command_pid" >/dev/null 2>&1 || true
	/usr/bin/printf '%s\n' 124 >"$status_file"
	return 124
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

wait_mac_idle()
{
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		SLURM_CONF="${run_dir}/slurm.conf.tls" "$scontrol" show node PC-210 \
			>"${run_dir}/daemon-PC-210.txt" 2>"${run_dir}/daemon-PC-210.err" || true
		state=$(node_field State "${run_dir}/daemon-PC-210.txt")
		if [ "$state" = IDLE ]; then
			/usr/bin/printf 'node_idle node=PC-210 wait_seconds=%s\n' "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

restore_local_config()
{
	[ "$config_installed" -eq 1 ] || return 0
	atomic_install "${run_dir}/slurm.conf.before" "$slurm_conf" \
		"${run_dir}/slurm.conf.before" || return 1
	restart_launchd local-restore || return 1
	config_installed=0
	restored_hash=$(/usr/bin/shasum -a 256 "$slurm_conf" | /usr/bin/awk '{print $1}')
	[ "$restored_hash" = "$original_config_hash" ] || return 1
}

cleanup_on_exit()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$config_installed" -eq 1 ]; then
		if restore_local_config; then
			/usr/bin/printf 'recovery: Mac tls/none config restored; Ubuntu TLS still requires restore; run_dir=%s\n' \
				"$run_dir" >&2
		else
			/usr/bin/printf 'fatal recovery: Mac config or launchd restore failed; backup=%s\n' \
				"${run_dir}/slurm.conf.before" >&2
		fi
	fi
	/usr/bin/find "$run_dir" -type f -exec /bin/chmod a+r {} \; >/dev/null 2>&1 || true
	exit "$rc"
}

trap cleanup_on_exit EXIT HUP INT TERM

[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this diagnostic is for macOS'
[ "$(/bin/hostname -s)" = PC-210 ] || fail "unexpected host=$(/bin/hostname -s)"
for required in "$slurm_conf" "$gres_conf" "$slurm_key" "$slurmd" "$scontrol" \
	"$squeue" "$plugin" "$certgen_plugin" "$s2n_prefix/lib/libs2n.dylib" \
	"$ca" "$slurmd_cert" "$slurmd_key" "$inactive_state" "$pid_file"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_path in /bin/cat /bin/chmod /bin/cp /bin/date \
	/bin/hostname /bin/kill /bin/launchctl /bin/mkdir /bin/mv /bin/rm \
	/bin/sleep /usr/bin/awk /usr/bin/env /usr/bin/grep /usr/bin/id \
	/usr/bin/cmp /usr/bin/find /usr/bin/install /usr/bin/nc /usr/bin/openssl /usr/bin/shasum \
	/usr/bin/stat /usr/bin/uname; do
	[ -x "$command_path" ] || fail "missing command=$command_path"
done
[ "$mode" != daemon ] || [ "$(/usr/bin/id -u)" -eq 0 ] || fail 'daemon mode must run as root'
[ "$mode" != client ] || [ "$(/usr/bin/id -u)" -ne 0 ] || fail 'client mode must run as a non-root user'
[ "$(/usr/bin/shasum -a 256 "$plugin" | /usr/bin/awk '{print $1}')" = \
	"$plugin_hash" ] || fail 'installed plugin hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$certgen_plugin" | /usr/bin/awk '{print $1}')" = \
	"$certgen_plugin_hash" ] || fail 'installed certgen plugin hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$s2n_prefix/lib/libs2n.dylib" | /usr/bin/awk '{print $1}')" = \
	"$libs2n_hash" ] || fail 'installed libs2n hash mismatch'
if /usr/bin/grep -Eq '^[[:space:]]*(TLSType|TLSParameters|CertgenType|CertgenParameters)=' \
	"$slurm_conf"; then
	fail 'Mac production slurm.conf already has TLS or certgen keys'
fi
if [ "$mode" = daemon ]; then
	[ -f "$runtime_state" ] || fail 'retained runtime state is missing'
	[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$inactive_state")" = root:wheel:600 ] || \
		fail 'inactive state metadata mismatch'
	/usr/bin/grep -Fqx 'phase=MAC_INACTIVE_INSTALLED' "$inactive_state" || \
		fail 'unexpected inactive state phase'
	[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$runtime_state")" = root:wheel:600 ] || \
		fail 'retained runtime state metadata mismatch'
	/usr/bin/grep -Fqx 'phase=FAILED_LOCAL_TLS_NONE_RESTORED' "$runtime_state" || \
		fail 'unexpected retained runtime phase'
	[ "$(/usr/bin/shasum -a 256 "$runtime_state" | /usr/bin/awk '{print $1}')" = \
		"$runtime_state_hash" ] || fail 'retained runtime state hash mismatch'
fi

umask 077
/bin/mkdir "$run_dir" || fail 'cannot create run directory'
/bin/chmod 0755 "$run_dir" || fail 'cannot make run directory traversable'
/usr/bin/printf 'mode=%s run_dir=%s\n' "$mode" "$run_dir"
/usr/bin/openssl version -a >"${run_dir}/openssl-version.txt" 2>&1 || fail 'openssl version failed'
/usr/bin/shasum -a 256 /usr/bin/openssl "$plugin" "$certgen_plugin" \
	"$s2n_prefix/lib/libs2n.dylib" "$ca" "$slurm_conf" \
	>"${run_dir}/client-inputs-before.sha256" || \
	fail 'cannot hash client inputs'
if [ "$mode" = daemon ]; then
	/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurm_key" \
		"$plugin" "$certgen_plugin" "$s2n_prefix/lib/libs2n.dylib" \
		"$ca" "$slurmd_cert" "$slurmd_key" "$inactive_state" "$runtime_state" \
		>"${run_dir}/protected-inputs-before.sha256" || fail 'cannot hash protected inputs'
fi
build_candidate "$slurm_conf" "${run_dir}/slurm.conf.tls" || fail 'cannot build TLS client config'
/bin/chmod 0600 "${run_dir}/slurm.conf.tls" || fail 'cannot protect TLS client config'
/usr/bin/nc -vz -w 3 192.168.10.180 6817 \
	>"${run_dir}/controller-port.out" 2>"${run_dir}/controller-port.err" || \
	fail 'controller port 6817 is unreachable'

cleartext_rc=0
run_ping_with_timeout "$slurm_conf" client-cleartext-negative || cleartext_rc=$?
/usr/bin/printf 'client_cleartext_ping_rc=%s\n' "$cleartext_rc" >"${run_dir}/negative-result.txt"
if [ "$cleartext_rc" -eq 0 ] || \
	/usr/bin/grep -q ' is UP$' "${run_dir}/client-cleartext-negative.out"; then
	fail 'TLS-none client unexpectedly reached the TLS controller'
fi

client_rc=0
run_ping_with_timeout "${run_dir}/slurm.conf.tls" client-ping || client_rc=$?
/usr/bin/printf 'client_ping_rc=%s\n' "$client_rc" >"${run_dir}/result.txt"
if [ "$client_rc" -ne 0 ]; then
	fail "TLS client ping failed rc=$client_rc run_dir=$run_dir"
fi
/usr/bin/grep -q ' is UP$' "${run_dir}/client-ping.out" || \
	fail "TLS client did not report controller UP run_dir=$run_dir"
/usr/bin/grep -Fq 'connection successfully created' "${run_dir}/client-ping.err" || \
	fail 'TLS client connection success marker missing'
/usr/bin/shasum -a 256 /usr/bin/openssl "$plugin" "$certgen_plugin" \
	"$s2n_prefix/lib/libs2n.dylib" "$ca" "$slurm_conf" \
	>"${run_dir}/client-inputs-after.sha256" || fail 'cannot rehash client inputs'
/usr/bin/cmp -s "${run_dir}/client-inputs-before.sha256" \
	"${run_dir}/client-inputs-after.sha256" || fail 'Mac client inputs changed'

if [ "$mode" = client ]; then
	success=1
	/usr/bin/printf 'SMD407_MAC_TLS_CLIENT_DIAG_PASS controller=UP certgen=PASS tls_connection=PASS tls_none_rejected=PASS no_job=PASS production_unchanged=PASS run_dir=%s\n' \
		"$run_dir"
	exit 0
fi

initial_pid=$(managed_slurmd_pid) || fail 'slurmd launchd identity mismatch'
for node in ubuntu PC-210; do
	SLURM_CONF="${run_dir}/slurm.conf.tls" "$scontrol" show node "$node" \
		>"${run_dir}/before-${node}.txt" 2>"${run_dir}/before-${node}.err" || \
		fail "cannot read node=$node over TLS"
	[ "$(node_field CPUAlloc "${run_dir}/before-${node}.txt")" = 0 ] || \
		fail "node=$node CPUAlloc is not zero"
	[ "$(node_field AllocMem "${run_dir}/before-${node}.txt")" = 0 ] || \
		fail "node=$node AllocMem is not zero"
done
SLURM_CONF="${run_dir}/slurm.conf.tls" "$squeue" -h -w ubuntu,PC-210 \
	>"${run_dir}/queue-before.txt" 2>"${run_dir}/queue-before.err" || fail 'cannot read queue over TLS'
[ ! -s "${run_dir}/queue-before.txt" ] || fail 'target queue is not empty'

/bin/cp -p "$slurm_conf" "${run_dir}/slurm.conf.before" || fail 'cannot back up slurm.conf'
original_config_hash=$(/usr/bin/shasum -a 256 "$slurm_conf" | /usr/bin/awk '{print $1}')
/bin/cp "$gres_conf" "${run_dir}/gres.conf" || fail 'cannot stage candidate gres.conf'
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
wait_mac_idle || fail 'PC-210 did not become IDLE with TLS'
daemon_tls_pid=$(managed_slurmd_pid) || fail 'TLS slurmd launchd identity mismatch'
restore_local_config || fail 'cannot restore Mac tls/none config and daemon'
restored_pid=$(managed_slurmd_pid) || fail 'restored slurmd launchd identity mismatch'
/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurm_key" \
	"$plugin" "$certgen_plugin" "$s2n_prefix/lib/libs2n.dylib" \
	"$ca" "$slurmd_cert" "$slurmd_key" "$inactive_state" "$runtime_state" \
	>"${run_dir}/protected-inputs-after.sha256" || fail 'cannot rehash protected inputs'
/usr/bin/cmp -s "${run_dir}/protected-inputs-before.sha256" \
	"${run_dir}/protected-inputs-after.sha256" || fail 'protected Mac inputs changed'
success=1
/usr/bin/printf 'SMD407_MAC_TLS_DAEMON_DIAG_PASS client=PASS registration=IDLE no_job=PASS local_tls_none_restored=PASS protected_inputs_unchanged=PASS retained_runtime_state=UNCHANGED initial_pid=%s tls_pid=%s restored_pid=%s run_dir=%s\n' \
	"$initial_pid" "$daemon_tls_pid" "$restored_pid" "$run_dir"
