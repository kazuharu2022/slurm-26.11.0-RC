#!/bin/sh

set -u

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
certgen_plugin=${prefix}/lib/slurm/certgen_script.so
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sacct=${prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
service_target=system/org.schedmd.slurmd
stage_archive=${prefix}/.smd407-tls-archive-20260923T150412
final_archive=${prefix}/.smd407-tls-archive-20260923T151440
mac_run=/tmp/slurm-smd407-mac-tls-archive-archive-20260923T151440
plugin_hash=f1b17c47b94c6ea3a86478a4f35493b30dff1f2d0941a45490e63381dd23cfa3
libs2n_hash=b0d957ad211cdeaaa996795b04c2dbe3238575b1b37f17719758b75c434c894a
success_state_hash=5e142c8c209295a0c0da0c5571d2b8c94e7c8668765da5f2260d518e1b9951e6
certgen_hash=aa36683403a51dcf9baba1190e0ee3ed2b8f81c4c4972229ce924e05bae25ce4
slurm_conf_hash=9c7021e4c794fd9ec4e76af0b7cd5c574d1cd058b9ba9c60c849103f0a7577a2
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-mac-tls-archive-readback-${run_stamp}

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

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'expected Darwin'
[ "$(/bin/hostname -s)" = PC-210 ] || fail 'unexpected host'
/bin/mkdir "$run_dir" || fail 'cannot create run directory'

for absent in \
	"${prefix}/lib/slurm/tls_s2n.so" \
	"${prefix}/lib/slurm-s2n-1.7.9" \
	"${prefix}/etc/ca_cert.pem" \
	"${prefix}/etc/slurmd_cert.pem" \
	"${prefix}/etc/slurmd_cert_key.pem" \
	"${prefix}/.smd407-mac-tls-inactive.env" \
	"${prefix}/.smd407-mac-tls-runtime.env" \
	"${prefix}/.smd407-mac-tls-job-runtime.env" \
	"${prefix}/.smd407-mac-tls-job-runtime-20260923T141041.env" \
	"${prefix}/.smd407-mac-tls-job-runtime-20260923T141746.env" \
	"${prefix}/.smd407-mac-tls-job-runtime-20260923T142205.env" \
	"${prefix}/.smd407-mac-tls-job-runtime-20260923T142627.env"; do
	[ ! -e "$absent" ] || fail "active path remains=$absent"
done

for archive in "$stage_archive" "$final_archive"; do
	[ -d "$archive" ] || fail "archive missing=$archive"
	[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$archive")" = root:wheel:700 ] || \
		fail "archive metadata mismatch=$archive"
done
[ "$(/usr/bin/shasum -a 256 "${final_archive}/artifacts/tls_s2n.so" | \
	/usr/bin/awk '{print $1}')" = "$plugin_hash" ] || fail 'archived plugin hash mismatch'
[ "$(/usr/bin/shasum -a 256 \
	"${final_archive}/artifacts/slurm-s2n-1.7.9/lib/libs2n.dylib" | \
	/usr/bin/awk '{print $1}')" = "$libs2n_hash" ] || fail 'archived libs2n hash mismatch'
[ "$(/usr/bin/shasum -a 256 \
	"${final_archive}/states/.smd407-mac-tls-job-runtime-20260923T142627.env" | \
	/usr/bin/awk '{print $1}')" = "$success_state_hash" ] || fail 'archived success state hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$certgen_plugin" | /usr/bin/awk '{print $1}')" = \
	"$certgen_hash" ] || fail 'production certgen hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$slurm_conf" | /usr/bin/awk '{print $1}')" = \
	"$slurm_conf_hash" ] || fail 'production slurm.conf hash mismatch'
if /usr/bin/grep -Eq '^[[:space:]]*(TLSType|TLSParameters)=' "$slurm_conf"; then
	fail 'production slurm.conf contains TLS keys'
fi

pid=$(/bin/cat "$pid_file") || fail 'cannot read slurmd PID'
[ "$pid" = 60321 ] || fail "unexpected slurmd PID=$pid"
/bin/kill -0 "$pid" >/dev/null 2>&1 || fail 'slurmd PID is not running'
/bin/launchctl procinfo "$pid" 2>/dev/null | /usr/bin/grep -Fq "$service_target = {" || \
	fail 'slurmd launchd identity mismatch'
export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller.txt" || fail 'controller is not UP'
for node in ubuntu PC-210; do
	"$scontrol" show node "$node" >"${run_dir}/${node}.txt" || fail "cannot read node=$node"
	[ "$(node_field State "${run_dir}/${node}.txt")" = IDLE ] || fail "node=$node is not IDLE"
	[ "$(node_field CPUAlloc "${run_dir}/${node}.txt")" = 0 ] || fail "node=$node CPUAlloc is not zero"
	[ "$(node_field AllocMem "${run_dir}/${node}.txt")" = 0 ] || fail "node=$node AllocMem is not zero"
done
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue.txt" || fail 'cannot read queue'
[ ! -s "${run_dir}/queue.txt" ] || fail 'queue is not empty'
"$sacct" -j 638,639 -n -P --format=JobIDRaw,State,ExitCode,NodeList \
	>"${run_dir}/accounting.txt" || fail 'cannot read accounting'
/usr/bin/awk -F '|' '
$1 == "638" && $2 == "COMPLETED" && $3 == "0:0" && $4 == "PC-210" { j638 = 1 }
$1 == "638.batch" && $2 == "COMPLETED" && $3 == "0:0" && $4 == "PC-210" { b638 = 1 }
$1 == "639" && $2 == "COMPLETED" && $3 == "0:0" && $4 == "PC-210,ubuntu" { j639 = 1 }
$1 == "639.0" && $2 == "COMPLETED" && $3 == "0:0" && $4 == "PC-210,ubuntu" { s639 = 1 }
END { exit !(j638 && b638 && j639 && s639) }
' "${run_dir}/accounting.txt" || fail 'final accounting mismatch'
/usr/bin/grep -Fqx 'PC-210.local' "${mac_run}/smoke-output/smoke-638.out" || \
	fail 'Job 638 output mismatch'
[ ! -s "${mac_run}/smoke-output/smoke-638.err" ] || fail 'Job 638 stderr is not empty'
/usr/bin/shasum -a 256 "${final_archive}/archive.env" \
	"${final_archive}/source.sha256" "${final_archive}/archive.sha256" \
	>"${run_dir}/archive-manifest-hashes.txt" || fail 'cannot hash archive manifests'
/usr/bin/printf 'SMD407_MAC_TLS_ARCHIVE_READBACK_COMPLETE active_artifacts=ABSENT archives=ROOT_ONLY_HASHED certgen=UNCHANGED slurm_conf=UNCHANGED tls=tls/none slurmd_pid=%s jobs=638,639 accounting=COMPLETED_0_0 nodes=IDLE_NO_ALLOCATION queue=EMPTY run_dir=%s\n' \
	"$pid" "$run_dir"
