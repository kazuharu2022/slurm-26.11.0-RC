#!/bin/sh

set -u

mode=${1:-}
plugin_source=${2:-}
case "$mode" in
before|after|external|external-nonexec) ;;
*) /usr/bin/printf 'usage: %s before|after|external|external-nonexec /absolute/path/to/certgen_script.so\n' "$0" >&2; exit 64 ;;
esac
case "$plugin_source" in
/*) ;;
*) /usr/bin/printf 'error: plugin path must be absolute\n' >&2; exit 64 ;;
esac

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
production_plugins=${prefix}/lib/slurm
ca=${prefix}/etc/ca_cert.pem
pid_file=/var/run/slurmd.pid
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-certgen-exec-probe-${mode}-${run_stamp}
stage_dir=${run_dir}/plugins
status_file=${run_dir}/scontrol.status

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

cleanup_on_exit()
{
	rc=$?
	trap - EXIT HUP INT TERM
	/usr/bin/find "$run_dir" -type f -exec /bin/chmod a+r {} \; >/dev/null 2>&1 || true
	exit "$rc"
}

run_with_timeout()
{
	(
		SLURM_CONF="${run_dir}/slurm.conf" "$scontrol" -vvvvvv ping \
			>"${run_dir}/scontrol.out" 2>"${run_dir}/scontrol.err"
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

trap cleanup_on_exit EXIT HUP INT TERM

[ "$(/usr/bin/id -u)" -ne 0 ] || fail 'run as a non-root user'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this probe is for macOS'
[ "$(/bin/hostname -s)" = PC-210 ] || fail "unexpected host=$(/bin/hostname -s)"
for required in "$plugin_source" "$slurm_conf" "$scontrol" "$squeue" "$ca" \
	"$pid_file"; do
	[ -f "$required" ] || fail "missing $required"
done
for command_path in /bin/cat /bin/chmod /bin/cp /bin/date /bin/hostname \
	/bin/kill /bin/mkdir /bin/mv /bin/rm /bin/sleep /usr/bin/awk /usr/bin/cmp \
	/usr/bin/file /usr/bin/find /usr/bin/grep /usr/bin/id /usr/bin/shasum \
	/usr/bin/uname; do
	[ -x "$command_path" ] || fail "missing command=$command_path"
done

active_config=$($scontrol show config) || fail 'cannot read active config'
/usr/bin/printf '%s\n' "$active_config" >"${run_dir}.active.tmp"
if ! /usr/bin/printf '%s\n' "$active_config" | \
	/usr/bin/grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$'; then
	/bin/rm -f "${run_dir}.active.tmp"
	fail 'active controller is not tls/none'
fi

umask 077
/bin/mkdir -p "$stage_dir" || fail 'cannot create run directory'
/bin/chmod 0755 "$run_dir" "$stage_dir" || fail 'cannot make run directory traversable'
/bin/mv "${run_dir}.active.tmp" "${run_dir}/active-config.txt" || fail 'cannot preserve active config'
/bin/cp -R "${production_plugins}/." "$stage_dir" || fail 'cannot stage production plugin set'
/bin/cp "$plugin_source" "${stage_dir}/certgen_script.so" || fail 'cannot stage certgen plugin'
/bin/chmod 0755 "${stage_dir}/certgen_script.so" || fail 'cannot set staged plugin mode'
/usr/bin/file "${stage_dir}/certgen_script.so" >"${run_dir}/plugin-file.txt" || \
	fail 'cannot inspect staged plugin'
/usr/bin/grep -Eq 'Mach-O 64-bit bundle arm64' "${run_dir}/plugin-file.txt" || \
	fail 'staged plugin architecture mismatch'
/usr/bin/shasum -a 256 "$plugin_source" "${stage_dir}/certgen_script.so" \
	>"${run_dir}/plugin.sha256" || fail 'cannot hash plugin'
/usr/bin/shasum -a 256 "${production_plugins}/certgen_script.so" "$slurm_conf" \
	>"${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'
/bin/cat "$pid_file" >"${run_dir}/slurmd-pid-before.txt" || fail 'cannot read slurmd PID'

certgen_params=
case "$mode" in
external|external-nonexec)
	script_dir=${run_dir}/external-scripts
	/bin/mkdir "$script_dir" || fail 'cannot create external script directory'
	/usr/bin/printf '%s\n' '#!/bin/sh' \
		'/usr/bin/openssl ecparam -name prime256v1 -genkey' \
		>"${script_dir}/keygen.sh" || fail 'cannot write external keygen script'
	/usr/bin/printf '%s\n' '#!/bin/sh' \
		'printf '\''%s'\'' "$1" | /usr/bin/openssl req -new -x509 -key /dev/stdin -subj "/C=XX/ST=StateName/L=CityName/O=CompanyName/OU=CompanySectionName/CN=my_slurm_ca"' \
		>"${script_dir}/certgen.sh" || fail 'cannot write external certgen script'
	if [ "$mode" = external ]; then
		/bin/chmod 0700 "${script_dir}/keygen.sh" "${script_dir}/certgen.sh" || \
			fail 'cannot make external scripts executable'
	else
		/bin/chmod 0600 "${script_dir}/keygen.sh" "${script_dir}/certgen.sh" || \
			fail 'cannot set non-executable script fixture mode'
	fi
	/usr/bin/shasum -a 256 "${script_dir}/keygen.sh" "${script_dir}/certgen.sh" \
		>"${run_dir}/external-scripts.sha256" || fail 'cannot hash external scripts'
	certgen_params="CertgenParameters=keygen_script=${script_dir}/keygen.sh,certgen_script=${script_dir}/certgen.sh"
	;;
esac

/usr/bin/awk -v stage="$stage_dir" -v ca="$ca" -v certgen_params="$certgen_params" '
/^[[:space:]]*PluginDir=/ { next }
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
	print "PluginDir=" stage
	print "CertgenType=certgen/script"
	if (certgen_params != "") print certgen_params
	print "TLSType=tls/s2n"
	print "TLSParameters=ca_cert_file=" ca
}
' "$slurm_conf" >"${run_dir}/slurm.conf" || fail 'cannot build probe config'
/bin/chmod 0600 "${run_dir}/slurm.conf" || fail 'cannot protect probe config'

probe_rc=0
run_with_timeout || probe_rc=$?
{
	/usr/bin/printf 'mode=%s\n' "$mode"
	/usr/bin/printf 'probe_rc=%s\n' "$probe_rc"
	/usr/bin/printf 'run_dir=%s\n' "$run_dir"
} >"${run_dir}/result.txt"

/usr/bin/shasum -a 256 "${production_plugins}/certgen_script.so" "$slurm_conf" \
	>"${run_dir}/production-after.sha256" || fail 'cannot rehash production inputs'
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed'
/bin/cat "$pid_file" >"${run_dir}/slurmd-pid-after.txt" || fail 'cannot reread slurmd PID'
/usr/bin/cmp -s "${run_dir}/slurmd-pid-before.txt" \
	"${run_dir}/slurmd-pid-after.txt" || fail 'slurmd PID changed'
"$scontrol" show config >"${run_dir}/active-after.txt" || fail 'cannot reread active config'
/usr/bin/grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' \
	"${run_dir}/active-after.txt" || fail 'active TLS changed'
for node in ubuntu PC-210; do
	"$scontrol" show node "$node" >"${run_dir}/${node}.txt" || fail "cannot read node=$node"
	[ "$(node_field State "${run_dir}/${node}.txt")" = IDLE ] || fail "node=$node is not IDLE"
	[ "$(node_field CPUAlloc "${run_dir}/${node}.txt")" = 0 ] || fail "node=$node CPUAlloc is not zero"
	[ "$(node_field AllocMem "${run_dir}/${node}.txt")" = 0 ] || fail "node=$node AllocMem is not zero"
done
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue.txt" || fail 'cannot read queue'
[ ! -s "${run_dir}/queue.txt" ] || fail 'target queue is not empty'

case "$mode" in
before)
	[ "$probe_rc" -ne 0 ] || fail 'before mode unexpectedly returned success'
	if /usr/bin/grep -q ' is UP$' "${run_dir}/scontrol.out"; then
		fail 'before mode unexpectedly reported controller UP'
	fi
	/usr/bin/grep -Fq 'can not be executed (/dev/fd/' "${run_dir}/scontrol.err" || \
		fail 'expected executable-permission failure was not reproduced'
	/usr/bin/grep -Fq 'Permission denied' "${run_dir}/scontrol.err" || \
		fail 'expected EACCES message was not reproduced'
	if /usr/bin/grep -Fq 'Successfully generated private key' "${run_dir}/scontrol.err"; then
		fail 'private key generation unexpectedly succeeded in before mode'
	fi
	/usr/bin/printf 'SMD407_CERTGEN_EXEC_PROBE_BEFORE_REPRODUCED expected_eacces=PASS production_unchanged=PASS run_dir=%s\n' \
		"$run_dir"
	;;
after|external)
	if /usr/bin/grep -Fq 'can not be executed (/dev/fd/' "${run_dir}/scontrol.err"; then
		fail 'executable-permission failure remains after fix'
	fi
	if /usr/bin/grep -Fq 'Unable to generate' "${run_dir}/scontrol.err"; then
		fail 'certificate generation still failed after fix'
	fi
	if /usr/bin/grep -Fq 'failed to initialize tls plugin' "${run_dir}/scontrol.err"; then
		fail 'TLS plugin initialization still failed after fix'
	fi
	/usr/bin/grep -Fq 'connection successfully created' "${run_dir}/scontrol.err" || \
		fail 'TLS client connection success marker missing'
	if [ "$probe_rc" -eq 0 ]; then
		/usr/bin/grep -q ' is UP$' "${run_dir}/scontrol.out" || \
			fail 'successful scontrol did not report controller UP'
		client_route=UP_VIA_LOCAL_SACK
	else
		client_route=TLS_INIT_PASS_RPC_NOT_UP
	fi
	/usr/bin/printf 'SMD407_CERTGEN_EXEC_PROBE_PASS mode=%s certgen_init=PASS tls_client_connection=PASS client_route=%s production_unchanged=PASS run_dir=%s\n' \
		"$mode" "$client_route" "$run_dir"
	;;
external-nonexec)
	[ "$probe_rc" -ne 0 ] || fail 'non-executable external script unexpectedly returned success'
	/usr/bin/grep -Fq 'can not be executed (' "${run_dir}/scontrol.err" || \
		fail 'external executable-permission failure was not detected'
	/usr/bin/grep -Fq 'Permission denied' "${run_dir}/scontrol.err" || \
		fail 'external EACCES message missing'
	if /usr/bin/grep -q ' is UP$' "${run_dir}/scontrol.out"; then
		fail 'non-executable external script unexpectedly reported controller UP'
	fi
	/usr/bin/printf 'SMD407_CERTGEN_EXEC_PROBE_NEGATIVE_PASS mode=external-nonexec expected_eacces=PASS production_unchanged=PASS run_dir=%s\n' \
		"$run_dir"
	;;
esac
