#!/bin/sh

set -u

if [ "${SMD407_TLS_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD407_TLS_PREFLIGHT_CONFIRMED=YES after confirming a read-only TLS preflight' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
source_root=/Users/REDACTED_USER/dev/slurm.26-05
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
plugin_dir=${prefix}/lib/slurm
pid_file=/var/run/slurmd.pid
service_target=system/org.schedmd.slurmd
node_name=PC-210
peer_node=ubuntu
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-mac-preflight-${run_stamp}

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

hash_inputs()
{
	output=$1
	: >"$output" || return 1
	for path in \
		"$slurm_conf" \
		"$gres_conf" \
		"$slurmd" \
		"${prefix}/lib/slurm/libslurmfull.dylib" \
		"${plugin_dir}/tls_none.so" \
		"${plugin_dir}/tls_s2n.so" \
		"${plugin_dir}/certgen_script.so" \
		"${plugin_dir}/certmgr_script.so"; do
		[ -f "$path" ] || continue
		/usr/bin/shasum -a 256 "$path" >>"$output" || return 1
	done
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this preflight is for the macOS worker'
for required in "$slurm_conf" "$gres_conf" "$slurmd" "$scontrol" "$squeue" \
	"$plugin_dir" "$pid_file"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_path in /usr/bin/awk /usr/bin/cmp /usr/bin/file /usr/bin/find \
	/usr/bin/grep /usr/bin/otool /usr/bin/openssl /usr/bin/shasum \
	/usr/bin/stat /bin/launchctl /bin/mkdir; do
	[ -x "$command_path" ] || fail "required command is not executable: $command_path"
done

umask 077
/bin/mkdir "$run_dir" || fail 'cannot create run directory'
/usr/bin/printf 'mode=READ_ONLY_PRODUCTION run_dir=%s\n' "$run_dir"
hash_inputs "${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller.txt" || fail 'controller is not UP'
"$scontrol" show config >"${run_dir}/controller-config.txt" || \
	fail 'controller config readback failed'
"$scontrol" show node "$node_name" >"${run_dir}/mac-node.txt" || \
	fail 'Mac node readback failed'
"$scontrol" show node "$peer_node" >"${run_dir}/ubuntu-node.txt" || \
	fail 'Ubuntu node readback failed'
"$squeue" -h -w "$node_name,$peer_node" >"${run_dir}/queue.txt" || \
	fail 'queue readback failed'

pid=$(/bin/cat "$pid_file")
case "$pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$pid" ;;
esac
/bin/kill -0 "$pid" >/dev/null 2>&1 || fail "slurmd pid=$pid is not running"
launchd_method=direct
if /bin/launchctl print "$service_target" \
	>"${run_dir}/launchd-direct.txt" 2>&1; then
	launchd_pid=$(/usr/bin/awk '/pid =/ { print $3; exit }' \
		"${run_dir}/launchd-direct.txt")
	[ "$launchd_pid" = "$pid" ] || \
		fail "launchd and pidfile mismatch launchd=$launchd_pid pidfile=$pid"
else
	launchd_method=procinfo
	/bin/launchctl procinfo "$pid" >"${run_dir}/launchd-procinfo.txt" 2>&1 || \
		fail "launchctl direct lookup and procinfo both failed for pid=$pid"
	/usr/bin/grep -Fq "${service_target} = {" \
		"${run_dir}/launchd-procinfo.txt" || \
		fail "slurmd pid=$pid is not associated with $service_target"
	/usr/bin/grep -Fq 'state = running' "${run_dir}/launchd-procinfo.txt" || \
		fail "launchd service is not running for pid=$pid"
	/usr/bin/grep -Fq "pid = $pid" "${run_dir}/launchd-procinfo.txt" || \
		fail "launchd procinfo does not contain pid=$pid"
fi

/usr/bin/grep -E \
	'^[[:space:]]*(AuthAltTypes|AuthType|CertgenParameters|CertgenType|CertmgrParameters|CertmgrType|CommunicationParameters|TLSParameters|TLSType)=' \
	"$slurm_conf" >"${run_dir}/local-tls-config.txt" || true
/usr/bin/grep -E \
	'^(AuthAltTypes|AuthType|CertgenParameters|CertgenType|CertmgrParameters|CertmgrType|CommunicationParameters|TLSParameters|TLSType)' \
	"${run_dir}/controller-config.txt" >"${run_dir}/controller-tls-config.txt" || true

: >"${run_dir}/installed-plugins.txt"
: >"${run_dir}/installed-plugin-file.txt"
: >"${run_dir}/installed-plugin-links.txt"
installed_s2n=NO
for plugin in "$plugin_dir"/tls_*.so "$plugin_dir"/certgen_*.so \
	"$plugin_dir"/certmgr_*.so; do
	[ -f "$plugin" ] || continue
	/usr/bin/printf '%s\n' "$plugin" >>"${run_dir}/installed-plugins.txt"
	/usr/bin/file "$plugin" >>"${run_dir}/installed-plugin-file.txt" 2>&1 || true
	/usr/bin/printf '%s\n' "[$plugin]" >>"${run_dir}/installed-plugin-links.txt"
	/usr/bin/otool -L "$plugin" >>"${run_dir}/installed-plugin-links.txt" 2>&1 || true
	case "$plugin" in
	*/tls_s2n.so) installed_s2n=YES ;;
	esac
done

: >"${run_dir}/build-plugins.txt"
build_s2n=NO
for plugin in "$source_root"/src/plugins/tls/*/.libs/tls_*.so \
	"$source_root"/src/plugins/certgen/*/.libs/certgen_*.so \
	"$source_root"/src/plugins/certmgr/*/.libs/certmgr_*.so; do
	[ -f "$plugin" ] || continue
	/usr/bin/printf '%s\n' "$plugin" >>"${run_dir}/build-plugins.txt"
	case "$plugin" in
	*/tls_s2n.so) build_s2n=YES ;;
	esac
done

if [ -f "${source_root}/config.log" ]; then
	/usr/bin/grep -nE 'unable to locate .*s2n|checking for s2n installation' \
		"${source_root}/config.log" >"${run_dir}/build-s2n-config-log.txt" || true
fi
if [ -f "${source_root}/config.status" ]; then
	/usr/bin/grep -nE 'S2N_|WITH_S2N_' "${source_root}/config.status" \
		>"${run_dir}/build-s2n-config-status.txt" || true
fi
if [ -f "${source_root}/config.h" ]; then
	/usr/bin/grep -n 'HAVE_S2N' "${source_root}/config.h" \
		>"${run_dir}/build-s2n-config-h.txt" || true
fi

/usr/bin/openssl version -a >"${run_dir}/openssl.txt" 2>&1 || true
: >"${run_dir}/s2n-prefixes.txt"
for candidate in /opt/homebrew/opt/s2n /opt/homebrew/opt/s2n-tls \
	/usr/local/opt/s2n /usr/local/opt/s2n-tls; do
	[ -e "$candidate" ] || continue
	/usr/bin/stat -f '%Su:%Sg:%Lp %N' "$candidate" >>"${run_dir}/s2n-prefixes.txt" 2>&1 || true
done
if [ -x /opt/homebrew/bin/pkg-config ]; then
	/opt/homebrew/bin/pkg-config --modversion s2n \
		>"${run_dir}/s2n-pkg-config.out" 2>"${run_dir}/s2n-pkg-config.err" || true
else
	/usr/bin/printf '%s\n' 'pkg-config=ABSENT' >"${run_dir}/s2n-pkg-config.err"
fi
if [ -x /opt/homebrew/bin/brew ]; then
	/opt/homebrew/bin/brew list --versions s2n s2n-tls openssl@3 \
		>"${run_dir}/brew-dependencies.out" 2>"${run_dir}/brew-dependencies.err" || true
else
	/usr/bin/printf '%s\n' 'homebrew=ABSENT' >"${run_dir}/brew-dependencies.err"
fi

: >"${run_dir}/certificate-metadata.txt"
for path in \
	"${prefix}/etc/ca_cert.pem" \
	"${prefix}/etc/ctld_cert.pem" \
	"${prefix}/etc/ctld_cert_key.pem" \
	"${prefix}/etc/dbd_cert.pem" \
	"${prefix}/etc/dbd_cert_key.pem" \
	"${prefix}/etc/slurmd_cert.pem" \
	"${prefix}/etc/slurmd_cert_key.pem"; do
	if [ -e "$path" ]; then
		/usr/bin/stat -f '%Su:%Sg:%Lp %z %N' "$path" \
			>>"${run_dir}/certificate-metadata.txt" 2>&1 || true
	else
		/usr/bin/printf 'ABSENT %s\n' "$path" >>"${run_dir}/certificate-metadata.txt"
	fi
done

hash_inputs "${run_dir}/production-after.sha256" || fail 'cannot hash final production inputs'
/usr/bin/cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed during preflight'
[ "$(/bin/cat "$pid_file")" = "$pid" ] || fail 'slurmd PID changed during preflight'

node_state=$(node_field State "${run_dir}/mac-node.txt")
if [ "$installed_s2n" = YES ]; then
	classification=MAC_TLS_S2N_INSTALLED
else
	classification=MISSING_MAC_TLS_S2N_PLUGIN
fi

/usr/bin/printf '%s\n' \
	"mac_tls_s2n_installed=$installed_s2n build_tree_tls_s2n=$build_s2n" \
	"runtime_state=$node_state slurmd_pid=$pid launchd_identity=$launchd_method queue_bytes=$(/usr/bin/wc -c <"${run_dir}/queue.txt" | /usr/bin/tr -d ' ')" \
	"SMD407_MAC_TLS_PREFLIGHT_COMPLETE classification=$classification production_unchanged=PASS run_dir=$run_dir"
