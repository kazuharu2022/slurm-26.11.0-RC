#!/bin/sh

set -u

mode=${1:-}
case "$mode" in
apply|verify|restore|cleanup) ;;
*) printf 'usage: %s apply|verify|restore|cleanup\n' "$0" >&2; exit 64 ;;
esac
if [ "${SMD407_TLS_RUNTIME_CHANGE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD407_TLS_RUNTIME_CHANGE_CONFIRMED=YES after approving the coordinated TLS runtime change' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmdbd_conf=${prefix}/etc/slurmdbd.conf
gres_conf=${prefix}/etc/gres.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sacctmgr=${prefix}/bin/sacctmgr
plugin=${prefix}/lib/slurm/tls_s2n.so
certgen_plugin=${prefix}/lib/slurm/certgen_script.so
s2n_prefix=${prefix}/lib/slurm-s2n-1.7.9
ca=${prefix}/etc/ca_cert.pem
ctld_cert=${prefix}/etc/ctld_cert.pem
ctld_key=${prefix}/etc/ctld_cert_key.pem
dbd_cert=${prefix}/etc/dbd_cert.pem
dbd_key=${prefix}/etc/dbd_cert_key.pem
slurmd_cert=${prefix}/etc/slurmd_cert.pem
slurmd_key=${prefix}/etc/slurmd_cert_key.pem
rogue_ca=/tmp/slurm-smd407-certificate-stage-20260912T221817/ca-private/rogue_ca_cert.pem
inactive_state=${prefix}/.smd407-ubuntu-tls-inactive.env
runtime_state=${prefix}/.smd407-ubuntu-tls-runtime.env
plugin_hash=fac2507c6c5070c47c78959a005b2e861632c9ff837601353a178570d72808a1
certgen_plugin_hash=3539895a90a3bff3770ab2b301460a6e3d140dd9e1fb4209b28783529347ff14
libs2n_hash=7ca8f397d81e31b2dfe47229e72200115b24716b63f46a354c13b9e2a1ccfd70
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-ubuntu-tls-runtime-${mode}-${run_stamp}
success=0
slurm_conf_installed=0
slurmdbd_conf_installed=0

fail()
{
	printf 'error: %s\n' "$*" >&2
	exit 1
}

node_field()
{
	field=$1
	file=$2
	awk -v key="${field}=" '
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
	awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

atomic_install()
{
	source_file=$1
	target_file=$2
	reference_file=$3
	tmp_file=${target_file}.smd407.$$
	uid=$(stat -c '%u' "$reference_file") || return 1
	gid=$(stat -c '%g' "$reference_file") || return 1
	file_mode=$(stat -c '%a' "$reference_file") || return 1
	if ! install -o "$uid" -g "$gid" -m "$file_mode" "$source_file" "$tmp_file"; then
		rm -f "$tmp_file"
		return 1
	fi
	if ! mv -f "$tmp_file" "$target_file"; then
		rm -f "$tmp_file"
		return 1
	fi
}

build_slurm_candidate()
{
	source_file=$1
	target_file=$2
	awk -v prefix="$prefix" '
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
		print "TLSParameters=ca_cert_file=" prefix "/etc/ca_cert.pem,ctld_cert_file=" prefix "/etc/ctld_cert.pem,ctld_cert_key_file=" prefix "/etc/ctld_cert_key.pem,slurmd_cert_file=" prefix "/etc/slurmd_cert.pem,slurmd_cert_key_file=" prefix "/etc/slurmd_cert_key.pem"
	}
	' "$source_file" >"$target_file"
}

build_dbd_candidate()
{
	source_file=$1
	target_file=$2
	awk -v prefix="$prefix" '
	{ print }
	END {
		print "TLSType=tls/s2n"
		print "TLSParameters=ca_cert_file=" prefix "/etc/ca_cert.pem,dbd_cert_file=" prefix "/etc/dbd_cert.pem,dbd_cert_key_file=" prefix "/etc/dbd_cert_key.pem"
	}
	' "$source_file" >"$target_file"
}

restart_stack()
{
	label=$1
	systemctl restart slurmdbd >"${run_dir}/${label}-slurmdbd.out" \
		2>"${run_dir}/${label}-slurmdbd.err" || return 1
	systemctl restart slurmctld >"${run_dir}/${label}-slurmctld.out" \
		2>"${run_dir}/${label}-slurmctld.err" || return 1
	systemctl restart slurmd >"${run_dir}/${label}-slurmd.out" \
		2>"${run_dir}/${label}-slurmd.err" || return 1
	for service in slurmdbd slurmctld slurmd; do
		[ "$(systemctl is-active "$service")" = active ] || return 1
	done
}

wait_control_plane()
{
	label=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$scontrol" ping >"${run_dir}/${label}-controller.txt" 2>&1 &&
		"$sacctmgr" ping >"${run_dir}/${label}-database.txt" 2>&1 && return 0
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_node_idle()
{
	label=$1
	node=$2
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$scontrol" show node "$node" >"${run_dir}/${label}-${node}.txt" 2>/dev/null || true
		state=$(node_field State "${run_dir}/${label}-${node}.txt")
		if [ "$state" = IDLE ]; then
			printf 'node_idle phase=%s node=%s wait_seconds=%s\n' "$label" "$node" "$attempt"
			return 0
		fi
		sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

rollback_apply()
{
	printf 'rollback_begin run_dir=%s\n' "$run_dir" >&2
	if [ "$slurmdbd_conf_installed" -eq 1 ] && [ -f "${run_dir}/slurmdbd.conf.before" ]; then
		atomic_install "${run_dir}/slurmdbd.conf.before" "$slurmdbd_conf" \
			"${run_dir}/slurmdbd.conf.before" || true
	fi
	if [ "$slurm_conf_installed" -eq 1 ] && [ -f "${run_dir}/slurm.conf.before" ]; then
		atomic_install "${run_dir}/slurm.conf.before" "$slurm_conf" \
			"${run_dir}/slurm.conf.before" || true
	fi
	if [ "$slurm_conf_installed" -eq 1 ] || [ "$slurmdbd_conf_installed" -eq 1 ]; then
		restart_stack rollback >/dev/null 2>&1 || true
	fi
	rm -f "$runtime_state"
	printf 'rollback_end\n' >&2
}

cleanup_on_exit()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$mode" = apply ]; then
		rollback_apply
		printf 'recovery: original Ubuntu TLS-none config restore attempted; inactive artifacts retained; inspect run_dir=%s\n' \
			"$run_dir" >&2
	elif [ "$success" -ne 1 ]; then
		printf 'recovery: %s did not complete; state and backups were retained; inspect run_dir=%s\n' \
			"$mode" "$run_dir" >&2
	fi
	exit "$rc"
}

trap cleanup_on_exit EXIT HUP INT TERM

[ "$(id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(uname -s)" = Linux ] || fail 'this control script is for Ubuntu'
[ "$(hostname -s)" = ubuntu2504 ] || fail "unexpected host=$(hostname -s)"
for required in "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
	"$scontrol" "$squeue" "$sacctmgr"; do
	[ -e "$required" ] || fail "missing $required"
done
for command_name in awk chmod cmp cp env grep install ldd mkdir mv readelf rm \
	sha256sum sleep ss stat systemctl timeout; do
	command -v "$command_name" >/dev/null 2>&1 || fail "missing command=$command_name"
done
umask 077
mkdir "$run_dir" || fail 'cannot create run directory'
printf 'mode=%s run_dir=%s\n' "$mode" "$run_dir"
export SLURM_CONF="$slurm_conf"

case "$mode" in
apply)
	[ -f "$inactive_state" ] || fail "missing inactive state=$inactive_state"
	[ "$(stat -c '%U:%G:%a' "$inactive_state")" = root:root:600 ] || \
		fail 'inactive state owner/mode mismatch'
	[ "$(state_value phase "$inactive_state")" = UBUNTU_INACTIVE_INSTALLED ] || \
		fail 'unexpected inactive state phase'
	[ ! -e "$runtime_state" ] || fail "runtime state already exists=$runtime_state"
	for required in "$plugin" "$certgen_plugin" "$s2n_prefix/lib/libs2n.so" "$ca" "$ctld_cert" \
		"$ctld_key" "$dbd_cert" "$dbd_key" "$slurmd_cert" "$slurmd_key"; do
		[ -e "$required" ] || fail "missing inactive TLS input=$required"
	done
	[ "$(sha256sum "$plugin" | awk '{print $1}')" = "$plugin_hash" ] || \
		fail 'installed plugin hash mismatch'
	[ "$(sha256sum "$certgen_plugin" | awk '{print $1}')" = "$certgen_plugin_hash" ] || \
		fail 'installed certgen plugin hash mismatch'
	[ "$(sha256sum "$s2n_prefix/lib/libs2n.so" | awk '{print $1}')" = "$libs2n_hash" ] || \
		fail 'installed libs2n hash mismatch'
	for service in slurmdbd slurmctld slurmd; do
		[ "$(systemctl is-active "$service")" = active ] || fail "$service is not active"
	done
	"$scontrol" show config >"${run_dir}/active-config-before.txt" || fail 'cannot read active config'
	grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' \
		"${run_dir}/active-config-before.txt" || fail 'active TLS is not tls/none'
	for node in ubuntu PC-210; do
		"$scontrol" show node "$node" >"${run_dir}/before-${node}.txt" || \
			fail "cannot read node=$node"
		[ "$(node_field State "${run_dir}/before-${node}.txt")" = IDLE ] || \
			fail "node=$node is not IDLE"
		[ "$(node_field CPUAlloc "${run_dir}/before-${node}.txt")" = 0 ] || \
			fail "node=$node CPUAlloc is not zero"
		[ "$(node_field AllocMem "${run_dir}/before-${node}.txt")" = 0 ] || \
			fail "node=$node AllocMem is not zero"
	done
	"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-before.txt" || fail 'cannot read queue'
	[ ! -s "${run_dir}/queue-before.txt" ] || fail 'target queue is not empty'
	if grep -Eq '^[[:space:]]*(TLSType|TLSParameters)=' "$slurm_conf"; then
		fail 'production slurm.conf already has TLS keys'
	fi
	if grep -Eq '^[[:space:]]*(TLSType|TLSParameters)=' "$slurmdbd_conf"; then
		fail 'production slurmdbd.conf already has TLS keys'
	fi
	cp -p "$slurm_conf" "${run_dir}/slurm.conf.before" || fail 'cannot back up slurm.conf'
	cp -p "$slurmdbd_conf" "${run_dir}/slurmdbd.conf.before" || fail 'cannot back up slurmdbd.conf'
	sha256sum "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
		>"${run_dir}/production-before.sha256" || fail 'cannot hash production inputs'
	build_slurm_candidate "$slurm_conf" "${run_dir}/slurm.conf.tls" || \
		fail 'cannot build TLS slurm.conf'
	build_dbd_candidate "$slurmdbd_conf" "${run_dir}/slurmdbd.conf.tls" || \
		fail 'cannot build TLS slurmdbd.conf'
	cp -p "$gres_conf" "${run_dir}/gres.conf" || fail 'cannot stage gres.conf'
	chmod 0600 "${run_dir}/slurm.conf.tls" "${run_dir}/slurmdbd.conf.tls" || \
		fail 'cannot protect TLS candidate configs'
	grep -Fqx 'TLSType=tls/s2n' "${run_dir}/slurm.conf.tls" || fail 'candidate slurm TLS type missing'
	grep -Fqx 'TLSType=tls/s2n' "${run_dir}/slurmdbd.conf.tls" || fail 'candidate dbd TLS type missing'
	grep -Eq '^CommunicationParameters=.*disable_http' "${run_dir}/slurm.conf.tls" || \
		fail 'candidate disable_http missing'
	SLURM_SACK_KEY="$prefix/etc/slurm.key" "$slurmd" -G -f "${run_dir}/slurm.conf.tls" \
		>"${run_dir}/candidate-G.out" 2>"${run_dir}/candidate-G.err" || \
		fail 'TLS candidate slurmd -G failed'
	atomic_install "${run_dir}/slurmdbd.conf.tls" "$slurmdbd_conf" "$slurmdbd_conf" || \
		fail 'cannot install TLS slurmdbd.conf'
	slurmdbd_conf_installed=1
	atomic_install "${run_dir}/slurm.conf.tls" "$slurm_conf" "$slurm_conf" || \
		fail 'cannot install TLS slurm.conf'
	slurm_conf_installed=1
	restart_stack tls || fail 'cannot restart Ubuntu Slurm stack with TLS config'
	wait_control_plane tls || fail 'TLS control plane did not become ready'
	wait_node_idle tls ubuntu || fail 'Ubuntu worker did not become IDLE with TLS'
	"$scontrol" show config >"${run_dir}/active-config-tls.txt" || fail 'cannot read TLS config'
	grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/s2n$' \
		"${run_dir}/active-config-tls.txt" || fail 'effective TLS type mismatch'
	grep -Eq '^CommunicationParameters[[:space:]]*=.*disable_http' \
		"${run_dir}/active-config-tls.txt" || fail 'effective disable_http missing'
	ss -ltnp >"${run_dir}/listeners.txt" || fail 'cannot capture listeners'
	for port in 6817 6818 6819; do
		grep -Eq ":${port}([[:space:]]|$)" "${run_dir}/listeners.txt" || \
			fail "missing listener port=$port"
	done
	"$scontrol" show node PC-210 >"${run_dir}/mac-transition-state.txt" 2>&1 || true
	{
		printf 'apply_run_dir=%s\n' "$run_dir"
		printf 'phase=UBUNTU_TLS_ACTIVE_AWAITING_MAC\n'
		printf 'plugin_hash=%s\n' "$plugin_hash"
		printf 'libs2n_hash=%s\n' "$libs2n_hash"
	} >"${runtime_state}.tmp" || fail 'cannot create runtime state'
	chmod 0600 "${runtime_state}.tmp" || fail 'cannot protect runtime state'
	mv -f "${runtime_state}.tmp" "$runtime_state" || fail 'cannot install runtime state'
	slurm_conf_installed=0
	slurmdbd_conf_installed=0
	success=1
	printf 'SMD407_UBUNTU_TLS_APPLY_COMPLETE tls=tls/s2n disable_http=PASS services=ACTIVE ubuntu=IDLE mac_transition=EXPECTED state=%s run_dir=%s\n' \
		"$runtime_state" "$run_dir"
	printf '%s\n' 'NEXT_ON_MAC: run smd407_macos_tls_runtime_driver.sh run; do not restore Ubuntu first'
	;;
verify)
	[ "${SMD407_MAC_TLS_RUNTIME_COMPLETE:-}" = YES ] || \
		fail 'set SMD407_MAC_TLS_RUNTIME_COMPLETE=YES only after the Mac runtime completion marker'
	[ -f "$runtime_state" ] || fail "missing runtime state=$runtime_state"
	[ "$(stat -c '%U:%G:%a' "$runtime_state")" = root:root:600 ] || \
		fail 'runtime state metadata mismatch'
	[ -f "$rogue_ca" ] || fail "missing staged rogue CA=$rogue_ca"
	apply_run_dir=$(state_value apply_run_dir "$runtime_state")
	case "$apply_run_dir" in /tmp/slurm-smd407-ubuntu-tls-runtime-apply-*) ;; *) fail 'invalid apply run directory' ;; esac
	[ -f "${apply_run_dir}/slurm.conf.before" ] || fail 'missing original slurm.conf backup'
	wait_control_plane verify || fail 'TLS control plane is not ready'
	"$scontrol" show config >"${run_dir}/active-config.txt" || fail 'cannot read active TLS config'
	grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/s2n$' \
		"${run_dir}/active-config.txt" || fail 'active TLS is not tls/s2n'
	grep -Eq '^CommunicationParameters[[:space:]]*=.*disable_http' \
		"${run_dir}/active-config.txt" || fail 'effective disable_http missing'
	"$scontrol" show node ubuntu >"${run_dir}/ubuntu.txt" || fail 'cannot read node=ubuntu'
	[ "$(node_field State "${run_dir}/ubuntu.txt")" = IDLE ] || fail 'node=ubuntu is not IDLE'
	[ "$(node_field CPUAlloc "${run_dir}/ubuntu.txt")" = 0 ] || fail 'node=ubuntu CPUAlloc is not zero'
	[ "$(node_field AllocMem "${run_dir}/ubuntu.txt")" = 0 ] || fail 'node=ubuntu AllocMem is not zero'
	# The Mac runtime driver deliberately restores its local tls/none config before
	# this verification. Capture that transitional state, but do not require it to
	# remain IDLE while the controller is still using TLS.
	"$scontrol" show node PC-210 >"${run_dir}/PC-210-transition.txt" 2>&1 || true
	mac_transition_state=$(node_field State "${run_dir}/PC-210-transition.txt")
	[ -n "$mac_transition_state" ] || mac_transition_state=UNKNOWN
	"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue.txt" || fail 'cannot read target queue'
	[ ! -s "${run_dir}/queue.txt" ] || fail 'target queue is not empty'
	tls_none_rc=0
	timeout 10 env SLURM_CONF="${apply_run_dir}/slurm.conf.before" \
		"$scontrol" ping >"${run_dir}/tls-none-client.out" \
		2>"${run_dir}/tls-none-client.err" || tls_none_rc=$?
	[ "$tls_none_rc" -ne 0 ] || fail 'tls/none client unexpectedly reached TLS controller'
	if grep -q ' is UP$' "${run_dir}/tls-none-client.out"; then
		fail 'tls/none client reported controller UP'
	fi
	awk -v rogue="$rogue_ca" '
	/^[[:space:]]*TLSParameters=/ {
		gsub(/ca_cert_file=[^,[:space:]]+/, "ca_cert_file=" rogue)
	}
	{ print }
	' "$slurm_conf" >"${run_dir}/rogue-client.conf" || fail 'cannot build rogue-CA client config'
	chmod 0600 "${run_dir}/rogue-client.conf" || fail 'cannot protect rogue-CA client config'
	rogue_rc=0
	timeout 10 env SLURM_CONF="${run_dir}/rogue-client.conf" \
		"$scontrol" ping >"${run_dir}/rogue-client.out" \
		2>"${run_dir}/rogue-client.err" || rogue_rc=$?
	[ "$rogue_rc" -ne 0 ] || fail 'rogue-CA client unexpectedly reached TLS controller'
	if grep -q ' is UP$' "${run_dir}/rogue-client.out"; then
		fail 'rogue-CA client reported controller UP'
	fi
	{
		printf 'tls_none_client_rc=%s\n' "$tls_none_rc"
		printf 'rogue_ca_client_rc=%s\n' "$rogue_rc"
	} >"${run_dir}/negative-results.txt" || fail 'cannot record negative results'
	success=1
	printf 'SMD407_UBUNTU_TLS_VERIFY_COMPLETE control_plane=PASS ubuntu=IDLE mac_transition=%s queue=EMPTY tls_none_rejected=PASS rogue_ca_rejected=PASS disable_http=PASS run_dir=%s apply_run_dir=%s\n' \
		"$mac_transition_state" "$run_dir" "$apply_run_dir"
	printf '%s\n' 'NEXT_ON_UBUNTU: after Mac local TLS-none restore, run restore with SMD407_MAC_TLS_LOCAL_RESTORED=YES'
	;;
restore)
	[ "${SMD407_MAC_TLS_LOCAL_RESTORED:-}" = YES ] || \
		fail 'set SMD407_MAC_TLS_LOCAL_RESTORED=YES only after the Mac runtime or recovery marker'
	[ -f "$runtime_state" ] || fail "missing runtime state=$runtime_state"
	[ "$(stat -c '%U:%G:%a' "$runtime_state")" = root:root:600 ] || fail 'runtime state metadata mismatch'
	apply_run_dir=$(state_value apply_run_dir "$runtime_state")
	case "$apply_run_dir" in /tmp/slurm-smd407-ubuntu-tls-runtime-apply-*) ;; *) fail 'invalid apply run directory' ;; esac
	for backup in slurm.conf.before slurmdbd.conf.before production-before.sha256; do
		[ -f "${apply_run_dir}/${backup}" ] || fail "missing backup=$backup"
	done
	cp "$runtime_state" "${run_dir}/runtime-state-before.txt" || fail 'cannot preserve runtime state'
	atomic_install "${apply_run_dir}/slurmdbd.conf.before" "$slurmdbd_conf" \
		"${apply_run_dir}/slurmdbd.conf.before" || fail 'cannot restore slurmdbd.conf'
	atomic_install "${apply_run_dir}/slurm.conf.before" "$slurm_conf" \
		"${apply_run_dir}/slurm.conf.before" || fail 'cannot restore slurm.conf'
	restart_stack restore || fail 'cannot restart Ubuntu stack with original config'
	wait_control_plane restored || fail 'restored control plane did not become ready'
	wait_node_idle restored ubuntu || fail 'Ubuntu did not become IDLE after restore'
	wait_node_idle restored PC-210 || fail 'Mac did not become IDLE after restore'
	sha256sum "$slurm_conf" "$slurmdbd_conf" "$gres_conf" "$slurmd" \
		>"${run_dir}/production-restored.sha256" || fail 'cannot hash restored production'
	cmp -s "${apply_run_dir}/production-before.sha256" \
		"${run_dir}/production-restored.sha256" || fail 'production config hashes were not restored'
	"$scontrol" show config >"${run_dir}/active-config-restored.txt" || fail 'cannot read restored config'
	grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' \
		"${run_dir}/active-config-restored.txt" || fail 'TLS-none was not restored'
	"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-restored.txt" || fail 'cannot read restored queue'
	[ ! -s "${run_dir}/queue-restored.txt" ] || fail 'queue is not empty after restore'
	rm -f "$runtime_state"
	success=1
	printf 'SMD407_UBUNTU_TLS_RESTORE_COMPLETE tls=tls/none services=ACTIVE nodes=IDLE queue=EMPTY production_restored=PASS inactive_artifacts=RETAINED run_dir=%s apply_run_dir=%s\n' \
		"$run_dir" "$apply_run_dir"
	printf '%s\n' 'NEXT_ON_MAC: run smd407_macos_tls_runtime_driver.sh finalize before Ubuntu cleanup'
	;;
cleanup)
	[ "${SMD407_MAC_TLS_FINALIZED:-}" = YES ] || \
		fail 'set SMD407_MAC_TLS_FINALIZED=YES only after the Mac finalize marker'
	[ ! -e "$runtime_state" ] || fail 'runtime state still exists; restore first'
	[ -f "$inactive_state" ] || fail "missing inactive state=$inactive_state"
	"$scontrol" show config >"${run_dir}/active-config.txt" || fail 'cannot read active config'
	grep -Eq '^TLSType[[:space:]]*=[[:space:]]*tls/none$' \
		"${run_dir}/active-config.txt" || fail 'active TLS is not tls/none'
	for node in ubuntu PC-210; do
		"$scontrol" show node "$node" >"${run_dir}/${node}.txt" || fail "cannot read node=$node"
		[ "$(node_field State "${run_dir}/${node}.txt")" = IDLE ] || fail "node=$node is not IDLE"
	done
	"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue.txt" || fail 'cannot read queue'
	[ ! -s "${run_dir}/queue.txt" ] || fail 'target queue is not empty'
	sha256sum "$plugin" "$s2n_prefix/lib/libs2n.so" "$ca" "$ctld_cert" \
		"$ctld_key" "$dbd_cert" "$dbd_key" "$slurmd_cert" "$slurmd_key" \
		>"${run_dir}/removed-inputs.sha256" || fail 'cannot preserve cleanup hashes'
	rm -f "$plugin" "$ca" "$ctld_cert" "$ctld_key" "$dbd_cert" "$dbd_key" \
		"$slurmd_cert" "$slurmd_key"
	rm -rf "$s2n_prefix"
	rm -f "$inactive_state"
	for removed in "$plugin" "$s2n_prefix" "$ca" "$ctld_cert" "$ctld_key" \
		"$dbd_cert" "$dbd_key" "$slurmd_cert" "$slurmd_key" "$inactive_state"; do
		[ ! -e "$removed" ] || fail "cleanup target remains=$removed"
	done
	success=1
	printf 'SMD407_UBUNTU_TLS_CLEANUP_COMPLETE tls=tls/none artifacts=REMOVED certificates=REMOVED state=ABSENT services=UNCHANGED nodes=IDLE queue=EMPTY run_dir=%s\n' "$run_dir"
	;;
esac
