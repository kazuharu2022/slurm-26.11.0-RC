#!/bin/sh

set -u

if [ "${SMD126_PLUGIN_AUDIT_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD126_PLUGIN_AUDIT_CONFIRMED=YES to run the read-only plugin audit' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
plugin_dir=${prefix}/lib/slurm
slurm_conf=${prefix}/etc/slurm.conf
node_name=PC-210
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd126-inventory-${run_stamp}
plugin_list=${run_dir}/plugins.txt
inventory=${run_dir}/plugin-inventory.txt
dependency_report=${run_dir}/plugin-dependencies.txt
undefined_report=${run_dir}/plugin-undefined-summary.txt
known_weak_report=${run_dir}/known-weak-symbols.txt
probe_dir=${run_dir}/probes
failure_count=0

export SLURM_CONF="$slurm_conf"

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
}

run_probe()
{
	name=$1
	shift
	"$@" >"${probe_dir}/${name}.out" 2>"${probe_dir}/${name}.err"
	rc=$?
	/usr/bin/printf 'probe=%s rc=%s stdout_bytes=%s stderr_bytes=%s\n' \
		"$name" "$rc" \
		"$(/usr/bin/wc -c <"${probe_dir}/${name}.out" | /usr/bin/tr -d ' ')" \
		"$(/usr/bin/wc -c <"${probe_dir}/${name}.err" | /usr/bin/tr -d ' ')"
	[ "$rc" -eq 0 ] || failure_count=$((failure_count + 1))
}

require_probe_text()
{
	name=$1
	pattern=$2
	if ! /usr/bin/grep -Eq "$pattern" \
		"${probe_dir}/${name}.out" "${probe_dir}/${name}.err"; then
		/usr/bin/printf 'probe_assertion_failure=%s pattern=%s\n' \
			"$name" "$pattern" >&2
		failure_count=$((failure_count + 1))
	fi
}

require_weak_dynamic_symbol()
{
	plugin=$1
	symbol=$2
	base=$(/usr/bin/basename "$plugin")
	undefined=${run_dir}/undefined-${base}.txt
	if /usr/bin/grep -Fq \
		"(undefined) weak external _${symbol} (dynamically looked up)" \
		"$undefined"; then
		/usr/bin/printf 'plugin=%s symbol=%s binding=weak_dynamic_lookup\n' \
			"$base" "$symbol" >>"$known_weak_report"
	else
		/usr/bin/printf 'known_weak_failure plugin=%s symbol=%s\n' \
			"$base" "$symbol" >>"$known_weak_report"
		failure_count=$((failure_count + 1))
	fi
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this audit is for the macOS worker'
[ -d "$plugin_dir" ] || fail "missing plugin directory=$plugin_dir"
[ -f "$slurm_conf" ] || fail "missing slurm.conf=$slurm_conf"

for command in /usr/bin/awk /usr/bin/basename /usr/bin/file /usr/bin/find \
	/usr/bin/grep /usr/bin/id /usr/bin/nm /usr/bin/otool /usr/bin/sort \
	/usr/bin/tr /usr/bin/wc /bin/date /bin/mkdir; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done
for binary in "${prefix}/bin/sinfo" "${prefix}/bin/squeue" \
	"${prefix}/bin/scontrol" "${prefix}/bin/sacct" \
	"${prefix}/bin/sacctmgr" "${prefix}/bin/srun" \
	"${prefix}/sbin/slurmd"; do
	[ -x "$binary" ] || fail "missing executable=$binary"
done

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$probe_dir" || fail 'cannot create run directory'
/usr/bin/find "$plugin_dir" -maxdepth 1 -type f -name '*.so' -print |
	/usr/bin/sort >"$plugin_list" || fail 'cannot enumerate plugins'
plugin_count=$(/usr/bin/wc -l <"$plugin_list" | /usr/bin/tr -d ' ')
case "$plugin_count" in
''|*[!0-9]*) fail "invalid plugin count=$plugin_count" ;;
esac
[ "$plugin_count" -gt 0 ] || fail 'no installed plugins found'

: >"$inventory"
: >"$dependency_report"
: >"$undefined_report"
: >"$known_weak_report"
architecture_failures=0
metadata_failures=0
dependency_failures=0
undefined_scan_failures=0

while IFS= read -r plugin; do
	base=$(/usr/bin/basename "$plugin")
	file_output=$(/usr/bin/file "$plugin")
	/usr/bin/printf 'plugin=%s file=%s\n' "$base" "$file_output" >>"$inventory"
	case "$file_output" in
	*'Mach-O 64-bit bundle arm64'*) ;;
	*)
		architecture_failures=$((architecture_failures + 1))
		/usr/bin/printf 'architecture_failure=%s\n' "$base" >>"$inventory"
	;;
	esac

	exports=${run_dir}/exports-${base}.txt
	/usr/bin/nm -gU "$plugin" >"$exports" 2>"${exports}.err" || {
		metadata_failures=$((metadata_failures + 1))
		continue
	}
	for symbol in plugin_name plugin_type plugin_version; do
		if ! /usr/bin/grep -Eq " _${symbol}$" "$exports"; then
			metadata_failures=$((metadata_failures + 1))
			/usr/bin/printf 'metadata_failure=%s symbol=%s\n' \
				"$base" "$symbol" >>"$inventory"
		fi
	done

	deps=${run_dir}/deps-${base}.txt
	/usr/bin/otool -L "$plugin" >"$deps" 2>"${deps}.err" || {
		dependency_failures=$((dependency_failures + 1))
		continue
	}
	/usr/bin/awk 'NR > 1 { print $1 }' "$deps" | while IFS= read -r dependency; do
		/usr/bin/printf 'plugin=%s dependency=%s\n' "$base" "$dependency"
	done >>"$dependency_report"
	while IFS= read -r dependency; do
		case "$dependency" in
		/opt/*)
			if [ ! -e "$dependency" ]; then
				dependency_failures=$((dependency_failures + 1))
				/usr/bin/printf 'missing plugin=%s dependency=%s\n' \
					"$base" "$dependency" >>"$dependency_report"
			fi
		;;
		esac
	done <<EOF
$(/usr/bin/awk 'NR > 1 { print $1 }' "$deps")
EOF

	undefined=${run_dir}/undefined-${base}.txt
	if ! /usr/bin/nm -m -u "$plugin" >"$undefined" 2>"${undefined}.err"; then
		undefined_scan_failures=$((undefined_scan_failures + 1))
		/usr/bin/printf 'undefined_scan_failure=%s\n' "$base" \
			>>"$undefined_report"
		continue
	fi
	undefined_total=$(/usr/bin/wc -l <"$undefined" | /usr/bin/tr -d ' ')
	dynamic_total=$(/usr/bin/grep -c 'dynamically looked up' "$undefined" || true)
	weak_dynamic=$(/usr/bin/grep 'dynamically looked up' "$undefined" |
		/usr/bin/grep -c 'weak external' || true)
	/usr/bin/printf 'plugin=%s undefined=%s dynamic_lookup=%s weak_dynamic=%s\n' \
		"$base" "$undefined_total" "$dynamic_total" "$weak_dynamic" >>"$undefined_report"
done <"$plugin_list"

# These symbols previously caused fatal flat-namespace loader failures on macOS.
# They remain parent-provided, but must be weak dynamic lookups so a client that
# does not export the controller-side state can still load the plugin.
for symbol in assoc_cache_cond assoc_cache_mutex running_cache; do
	require_weak_dynamic_symbol \
		"${plugin_dir}/accounting_storage_slurmdbd.so" "$symbol"
done
require_weak_dynamic_symbol "${plugin_dir}/topology_flat.so" idle_node_bitmap

/usr/bin/printf 'run_dir=%s\n' "$run_dir"
/usr/bin/printf 'plugins=%s architecture_failures=%s metadata_failures=%s dependency_failures=%s undefined_scan_failures=%s\n' \
	"$plugin_count" "$architecture_failures" "$metadata_failures" \
	"$dependency_failures" "$undefined_scan_failures"

run_probe sinfo "${prefix}/bin/sinfo"
run_probe squeue "${prefix}/bin/squeue"
run_probe scontrol-config "${prefix}/bin/scontrol" show config
run_probe scontrol-node "${prefix}/bin/scontrol" show node "$node_name"
run_probe sacct-job379 "${prefix}/bin/sacct" -j 379
run_probe sacctmgr-ping "${prefix}/bin/sacctmgr" ping
run_probe srun-mpi-list "${prefix}/bin/srun" --mpi=list
run_probe slurmd-config "${prefix}/sbin/slurmd" -C -f "$slurm_conf"
run_probe slurmd-gres "${prefix}/sbin/slurmd" -G -f "$slurm_conf"

require_probe_text sinfo 'PC-210'
require_probe_text scontrol-config 'AccountingStorageType[[:space:]]*=[[:space:]]*accounting_storage/slurmdbd'
require_probe_text scontrol-node 'NodeName=PC-210'
require_probe_text scontrol-node 'State=IDLE'
require_probe_text sacct-job379 '379'
require_probe_text sacct-job379 'COMPLETED'
require_probe_text sacctmgr-ping 'is UP'
require_probe_text srun-mpi-list 'MPI plugin types are'
require_probe_text slurmd-config 'NodeName=PC-210'
require_probe_text slurmd-gres 'Gres Name=gpu Type=apple Count=1'

loader_pattern='symbol not found|Couldn.t load specified plugin|Dlopen of plugin file failed|cannot create .* context|failed to initialize .* plugin'
loader_errors=${run_dir}/loader-errors.txt
: >"$loader_errors"
for output in "${probe_dir}"/*.out "${probe_dir}"/*.err; do
	/usr/bin/grep -Ein "$loader_pattern" "$output" |
		/usr/bin/awk -v file="$output" '{ print file ":" $0 }' >>"$loader_errors" || true
done
loader_error_count=$(/usr/bin/wc -l <"$loader_errors" | /usr/bin/tr -d ' ')

[ "$architecture_failures" -eq 0 ] || failure_count=$((failure_count + 1))
[ "$metadata_failures" -eq 0 ] || failure_count=$((failure_count + 1))
[ "$dependency_failures" -eq 0 ] || failure_count=$((failure_count + 1))
[ "$undefined_scan_failures" -eq 0 ] || failure_count=$((failure_count + 1))
[ "$loader_error_count" -eq 0 ] || failure_count=$((failure_count + 1))

if [ "$failure_count" -ne 0 ]; then
	/usr/bin/printf 'SMD126_PHASE_A_FAILED failures=%s loader_errors=%s run_dir=%s\n' \
		"$failure_count" "$loader_error_count" "$run_dir" >&2
	exit 1
fi

/usr/bin/printf 'SMD126_PHASE_A_COMPLETE plugins=%s probes=9 loader_errors=0 run_dir=%s\n' \
	"$plugin_count" "$run_dir"
