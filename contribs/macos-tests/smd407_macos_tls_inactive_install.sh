#!/bin/sh

set -u

if [ "${SMD407_MAC_TLS_INACTIVE_INSTALL_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD407_MAC_TLS_INACTIVE_INSTALL_CONFIRMED=YES after approving inactive Mac TLS artifact installation' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
artifact_root=/tmp/slurm-smd407-mac-isolated-build-20260912T220604/artifacts
plugin_source=${artifact_root}/tls_s2n.so
s2n_source=${artifact_root}/s2n-prefix
archive=${SMD407_MAC_CERT_ARCHIVE:-/tmp/smd407-mac-bundle.tar}
archive_hash=b67b1b2f9f513c81e10e04322c83c11e6cc3df49d4ffae10fb18c2c76e31f5dc
plugin_hash=f1b17c47b94c6ea3a86478a4f35493b30dff1f2d0941a45490e63381dd23cfa3
libs2n_hash=b0d957ad211cdeaaa996795b04c2dbe3238575b1b37f17719758b75c434c894a
plugin_target=${prefix}/lib/slurm/tls_s2n.so
s2n_target=${prefix}/lib/slurm-s2n-1.7.9
state_file=${prefix}/.smd407-mac-tls-inactive.env
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
slurm_key=${prefix}/etc/slurm.key
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
pid_file=/var/run/slurmd.pid
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-mac-inactive-install-${run_stamp}
extract_dir=${run_dir}/extract
bundle=${extract_dir}/mac-bundle
tmp_s2n=${prefix}/lib/.slurm-s2n-1.7.9.smd407-${run_stamp}
tmp_plugin=${prefix}/lib/slurm/.tls_s2n.so.smd407-${run_stamp}
installed_s2n=0
installed_plugin=0
installed_certs=
state_installed=0
success=0

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

hash_active_inputs()
{
	output=$1
	: >"$output" || return 1
	for active_path in \
		"$slurm_conf" \
		"$gres_conf" \
		"$slurmd" \
		"${prefix}/lib/slurm/libslurmfull.dylib" \
		"${prefix}/lib/slurm/tls_none.so" \
		/Library/LaunchDaemons/org.schedmd.slurm.slurmd.plist; do
		[ -f "$active_path" ] || continue
		/usr/bin/shasum -a 256 "$active_path" >>"$output" || return 1
	done
}

rollback()
{
	[ "$state_installed" -eq 0 ] || /bin/rm -f "$state_file"
	/bin/rm -f "${state_file}.tmp"
	for name in $installed_certs; do
		/bin/rm -f "${prefix}/etc/${name}"
	done
	[ "$installed_plugin" -eq 0 ] || /bin/rm -f "$plugin_target"
	if [ "$installed_s2n" -eq 1 ] && [ -d "$s2n_target" ]; then
		/bin/rm -rf "$s2n_target"
	fi
	/bin/rm -rf "$tmp_s2n"
	/bin/rm -f "$tmp_plugin"
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ]; then
		rollback
		/usr/bin/printf \
			'recovery: inactive files introduced by this attempt were removed; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this installer is for macOS'
[ "$(/bin/hostname -s)" = PC-210 ] || fail "unexpected host=$(/bin/hostname -s)"
for required in "$plugin_source" "$s2n_source/lib/libs2n.dylib" "$archive" \
	"$slurm_conf" "$gres_conf" "$slurm_key" "$slurmd" "$scontrol" \
	"$squeue" "$pid_file"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_path in /bin/cat /bin/chmod /bin/cp /bin/date /bin/hostname \
	/bin/launchctl /bin/mkdir /bin/mv /bin/ps /bin/rm /usr/bin/awk \
	/usr/bin/cmp /usr/bin/file /usr/bin/find /usr/bin/grep /usr/bin/id \
	/usr/bin/install /usr/bin/nm /usr/bin/otool /usr/bin/shasum \
	/usr/bin/stat /usr/bin/tar /usr/bin/uname /usr/bin/wc /usr/sbin/chown; do
	[ -x "$command_path" ] || fail "missing command=$command_path"
done
[ ! -e "$state_file" ] || fail "inactive install state already exists=$state_file"
for target in "$plugin_target" "$s2n_target" \
	"${prefix}/etc/ca_cert.pem" "${prefix}/etc/slurmd_cert.pem" \
	"${prefix}/etc/slurmd_cert_key.pem"; do
	[ ! -e "$target" ] || fail "refusing to overwrite existing target=$target"
done

umask 077
/bin/mkdir "$run_dir" "$extract_dir" || fail 'cannot create run directory'
/usr/bin/printf 'mode=MAC_TLS_INACTIVE_INSTALL run_dir=%s\n' "$run_dir"

hash_active_inputs "${run_dir}/active-inputs-before.sha256" || \
	fail 'cannot hash active production inputs'
initial_slurmd_pid=$(/bin/cat "$pid_file")
case "$initial_slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$initial_slurmd_pid" ;;
esac
/bin/ps -p "$initial_slurmd_pid" -o pid=,ppid=,state=,command= \
	>"${run_dir}/slurmd-process-before.txt" || fail 'slurmd process is not alive'
/usr/bin/grep -q '/opt/slurm/26.11.0/sbin/slurmd' \
	"${run_dir}/slurmd-process-before.txt" || fail 'unexpected slurmd process'
/bin/launchctl procinfo "$initial_slurmd_pid" \
	>"${run_dir}/slurmd-procinfo-before.txt" 2>&1 || \
	fail 'cannot read slurmd launchd identity'
/usr/bin/grep -Fq 'system/org.schedmd.slurmd = {' \
	"${run_dir}/slurmd-procinfo-before.txt" || \
	fail 'slurmd is not associated with launchd service'

export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller.txt" || fail 'controller is not UP'
"$scontrol" show config >"${run_dir}/active-config-before.txt" || \
	fail 'cannot read active config'
/usr/bin/grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' \
	"${run_dir}/active-config-before.txt" || fail 'active TLS is not tls/none'
"$scontrol" show node ubuntu >"${run_dir}/ubuntu-before.txt" || \
	fail 'cannot read Ubuntu node'
"$scontrol" show node PC-210 >"${run_dir}/mac-before.txt" || \
	fail 'cannot read Mac node'
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-before.txt" || \
	fail 'cannot read target queue'
for node_file in "${run_dir}/ubuntu-before.txt" "${run_dir}/mac-before.txt"; do
	[ "$(node_field State "$node_file")" = IDLE ] || fail "node is not IDLE=$node_file"
	[ "$(node_field CPUAlloc "$node_file")" = 0 ] || fail "CPU allocation exists=$node_file"
	[ "$(node_field AllocMem "$node_file")" = 0 ] || fail "memory allocation exists=$node_file"
done
[ ! -s "${run_dir}/queue-before.txt" ] || fail 'target queue is not empty'
/usr/bin/grep -Fq 'Gres=gpu:apple:1' "${run_dir}/mac-before.txt" || \
	fail 'controller node record lacks gpu:apple:1'

[ "$(/usr/bin/shasum -a 256 "$plugin_source" | /usr/bin/awk '{print $1}')" = \
	"$plugin_hash" ] || fail 'Mac plugin artifact hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$s2n_source/lib/libs2n.dylib" | /usr/bin/awk '{print $1}')" = \
	"$libs2n_hash" ] || fail 'Mac libs2n artifact hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')" = \
	"$archive_hash" ] || fail 'Mac certificate archive hash mismatch'
/usr/bin/file "$plugin_source" >"${run_dir}/plugin-source-file.txt" || \
	fail 'cannot inspect plugin source'
/usr/bin/grep -Eq 'Mach-O 64-bit bundle arm64' \
	"${run_dir}/plugin-source-file.txt" || fail 'Mac plugin architecture mismatch'
/usr/bin/otool -L "$plugin_source" >"${run_dir}/plugin-source-links.txt" || \
	fail 'cannot inspect plugin dependencies'
/usr/bin/otool -l "$plugin_source" >"${run_dir}/plugin-source-load-commands.txt" || \
	fail 'cannot inspect plugin load commands'
/usr/bin/nm -g "$plugin_source" >"${run_dir}/plugin-source-symbols.txt" 2>&1 || \
	fail 'cannot inspect plugin symbols'
/usr/bin/grep -Fq '@rpath/libs2n.1.dylib' \
	"${run_dir}/plugin-source-links.txt" || fail 'plugin does not link libs2n'
/usr/bin/grep -Fq "${s2n_target}/lib" \
	"${run_dir}/plugin-source-load-commands.txt" || fail 'plugin lacks final s2n LC_RPATH'
/usr/bin/grep -Fq '_plugin_type' "${run_dir}/plugin-source-symbols.txt" || \
	fail 'plugin metadata symbol missing'

/usr/bin/tar -tf "$archive" >"${run_dir}/archive-members.txt" || \
	fail 'cannot list certificate archive'
[ "$(/usr/bin/grep -Ec '.' "${run_dir}/archive-members.txt")" -eq 5 ] || \
	fail 'unexpected certificate archive member count'
while IFS= read -r member; do
	case "$member" in
	mac-bundle/|mac-bundle/ca_cert.pem|mac-bundle/slurmd_cert.pem|mac-bundle/slurmd_cert_key.pem|mac-bundle/manifest.sha256)
		;;
	*'/../'*|'../'*|/*)
		fail "unsafe archive member=$member"
		;;
	*)
		fail "unexpected archive member=$member"
		;;
	esac
done <"${run_dir}/archive-members.txt"
/usr/bin/tar -xf "$archive" -C "$extract_dir" || \
	fail 'cannot extract certificate archive'
for required in ca_cert.pem slurmd_cert.pem slurmd_cert_key.pem manifest.sha256; do
	[ -f "${bundle}/${required}" ] || fail "missing bundle member=$required"
done
(
	cd "$bundle" || exit 1
	/usr/bin/shasum -a 256 -c manifest.sha256
) >"${run_dir}/certificate-manifest.out" \
	2>"${run_dir}/certificate-manifest.err" || fail 'Mac certificate manifest mismatch'

trap cleanup EXIT HUP INT TERM
/bin/cp -R "$s2n_source" "$tmp_s2n" || fail 'cannot stage libs2n tree'
/usr/sbin/chown -R root:wheel "$tmp_s2n" || fail 'cannot set libs2n ownership'
/usr/bin/find "$tmp_s2n" -type d -exec /bin/chmod 0755 {} \; || \
	fail 'cannot set libs2n directory modes'
/usr/bin/find "$tmp_s2n" -type f -exec /bin/chmod 0644 {} \; || \
	fail 'cannot set libs2n file modes'
/usr/bin/find "$tmp_s2n/lib" -type f -name 'libs2n*.dylib' \
	-exec /bin/chmod 0755 {} \; || fail 'cannot set libs2n library mode'
/bin/mv "$tmp_s2n" "$s2n_target" || fail 'cannot activate inactive libs2n tree'
installed_s2n=1

/usr/bin/install -o root -g wheel -m 0755 "$plugin_source" "$tmp_plugin" || \
	fail 'cannot stage tls_s2n plugin'
/bin/mv "$tmp_plugin" "$plugin_target" || fail 'cannot install tls_s2n plugin'
installed_plugin=1

for name in ca_cert.pem slurmd_cert.pem slurmd_cert_key.pem; do
	mode=0600
	[ "$name" != ca_cert.pem ] || mode=0644
	/usr/bin/install -o root -g wheel -m "$mode" \
		"${bundle}/${name}" "${prefix}/etc/${name}" || \
		fail "cannot install inactive certificate=$name"
	installed_certs="$installed_certs $name"
done

[ "$(/usr/bin/shasum -a 256 "$plugin_target" | /usr/bin/awk '{print $1}')" = \
	"$plugin_hash" ] || fail 'installed plugin hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$s2n_target/lib/libs2n.dylib" | /usr/bin/awk '{print $1}')" = \
	"$libs2n_hash" ] || fail 'installed libs2n hash mismatch'
/usr/bin/otool -L "$plugin_target" >"${run_dir}/plugin-installed-links.txt" || \
	fail 'cannot inspect installed plugin dependencies'
/usr/bin/otool -l "$plugin_target" >"${run_dir}/plugin-installed-load-commands.txt" || \
	fail 'cannot inspect installed plugin load commands'
/usr/bin/grep -Fq '@rpath/libs2n.1.dylib' \
	"${run_dir}/plugin-installed-links.txt" || fail 'installed plugin lacks libs2n dependency'
/usr/bin/grep -Fq "${s2n_target}/lib" \
	"${run_dir}/plugin-installed-load-commands.txt" || fail 'installed plugin lacks final LC_RPATH'
/usr/bin/otool -L "${s2n_target}/lib/libs2n.dylib" \
	>"${run_dir}/libs2n-installed-links.txt" || fail 'cannot inspect installed libs2n'
/usr/bin/grep -Fq '/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib' \
	"${run_dir}/libs2n-installed-links.txt" || fail 'installed libs2n crypto dependency mismatch'

for file in ca_cert.pem slurmd_cert.pem slurmd_cert_key.pem; do
	[ "$(/usr/bin/shasum -a 256 "${prefix}/etc/${file}" | /usr/bin/awk '{print $1}')" = \
		"$(/usr/bin/shasum -a 256 "${bundle}/${file}" | /usr/bin/awk '{print $1}')" ] || \
		fail "installed certificate hash mismatch=$file"
done
[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "${prefix}/etc/ca_cert.pem")" = root:wheel:644 ] || \
	fail 'installed CA metadata mismatch'
for file in slurmd_cert.pem slurmd_cert_key.pem; do
	[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "${prefix}/etc/${file}")" = root:wheel:600 ] || \
		fail "installed protected certificate metadata mismatch=$file"
done

if /usr/bin/grep -Eq '^[[:space:]]*(TLSType|TLSParameters)=' "$slurm_conf"; then
	fail 'production slurm.conf already has TLS keys'
fi
/bin/cp "$gres_conf" "${run_dir}/gres.conf" || fail 'cannot stage candidate gres.conf'
/usr/bin/awk -v prefix="$prefix" '
{ print }
END {
	print "TLSType=tls/s2n"
	print "TLSParameters=ca_cert_file=" prefix "/etc/ca_cert.pem,slurmd_cert_file=" prefix "/etc/slurmd_cert.pem,slurmd_cert_key_file=" prefix "/etc/slurmd_cert_key.pem"
}
' "$slurm_conf" >"${run_dir}/slurm.conf" || fail 'cannot build candidate slurm.conf'
/bin/chmod 0600 "${run_dir}/slurm.conf" || fail 'cannot protect candidate config'
SLURM_SACK_KEY="$slurm_key" "$slurmd" -G -f "${run_dir}/slurm.conf" \
	>"${run_dir}/candidate-G.out" 2>"${run_dir}/candidate-G.err" || \
	fail 'installed TLS candidate slurmd -G failed'
/usr/bin/grep -Eq 'Gres Name=gpu Type=apple Count=1 .*File=/dev/null' \
	"${run_dir}/candidate-G.out" "${run_dir}/candidate-G.err" || \
	fail 'candidate Apple GPU GRES validation missing'

/usr/bin/printf '%s\n' \
	"run_dir=$run_dir" \
	'phase=MAC_INACTIVE_INSTALLED' \
	"plugin_hash=$plugin_hash" \
	"libs2n_hash=$libs2n_hash" \
	"archive_hash=$archive_hash" >"${state_file}.tmp" || fail 'cannot create state file'
/bin/chmod 0600 "${state_file}.tmp" || fail 'cannot protect state file'
/usr/sbin/chown root:wheel "${state_file}.tmp" || fail 'cannot set state ownership'
/bin/mv "${state_file}.tmp" "$state_file" || fail 'cannot install state file'
state_installed=1

"$scontrol" show config >"${run_dir}/active-config-after.txt" || \
	fail 'cannot reread active config'
/usr/bin/grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' \
	"${run_dir}/active-config-after.txt" || fail 'active TLS changed unexpectedly'
[ "$(/bin/cat "$pid_file")" = "$initial_slurmd_pid" ] || fail 'slurmd PID changed'
/bin/ps -p "$initial_slurmd_pid" -o pid=,ppid=,state=,command= \
	>"${run_dir}/slurmd-process-after.txt" || fail 'slurmd process stopped'
/bin/launchctl procinfo "$initial_slurmd_pid" \
	>"${run_dir}/slurmd-procinfo-after.txt" 2>&1 || \
	fail 'cannot reread slurmd launchd identity'
/usr/bin/grep -Fq 'system/org.schedmd.slurmd = {' \
	"${run_dir}/slurmd-procinfo-after.txt" || fail 'launchd identity changed'
hash_active_inputs "${run_dir}/active-inputs-after.sha256" || \
	fail 'cannot rehash active production inputs'
/usr/bin/cmp -s "${run_dir}/active-inputs-before.sha256" \
	"${run_dir}/active-inputs-after.sha256" || fail 'active production input changed'
"$scontrol" show node ubuntu >"${run_dir}/ubuntu-after.txt" || \
	fail 'cannot reread Ubuntu node'
"$scontrol" show node PC-210 >"${run_dir}/mac-after.txt" || \
	fail 'cannot reread Mac node'
for node_file in "${run_dir}/ubuntu-after.txt" "${run_dir}/mac-after.txt"; do
	[ "$(node_field State "$node_file")" = IDLE ] || fail "final node is not IDLE=$node_file"
	[ "$(node_field CPUAlloc "$node_file")" = 0 ] || fail "final CPU allocation exists=$node_file"
	[ "$(node_field AllocMem "$node_file")" = 0 ] || fail "final memory allocation exists=$node_file"
done
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-after.txt" || \
	fail 'cannot reread target queue'
[ ! -s "${run_dir}/queue-after.txt" ] || fail 'target queue changed during inactive install'

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s\n' \
	"SMD407_MAC_TLS_INACTIVE_INSTALL_COMPLETE plugin_hash=${plugin_hash} libs2n_hash=${libs2n_hash} certificates=3 candidate_G=PASS apple_gres=PASS active_tls=tls/none slurmd_pid_unchanged=${initial_slurmd_pid} active_inputs_unchanged=PASS nodes=IDLE queue=EMPTY state=${state_file} run_dir=${run_dir}"
