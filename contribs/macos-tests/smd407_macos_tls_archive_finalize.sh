#!/bin/sh

set -u

mode=${1:-}
case "$mode" in
preflight|stage|archive) ;;
*) /usr/bin/printf 'usage: %s preflight|stage|archive\n' "$0" >&2; exit 64 ;;
esac
if [ "$mode" = stage ] && [ "${SMD407_TLS_ARCHIVE_STAGE_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD407_TLS_ARCHIVE_STAGE_CONFIRMED=YES after approving non-destructive root-only archival' >&2
	exit 64
fi
if [ "$mode" = archive ] && [ "${SMD407_TLS_ARCHIVE_FINALIZE_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD407_TLS_ARCHIVE_FINALIZE_CONFIRMED=YES after approving recoverable TLS artifact archival' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
gres_conf=${prefix}/etc/gres.conf
slurm_key=${prefix}/etc/slurm.key
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
plugin=${prefix}/lib/slurm/tls_s2n.so
certgen_plugin=${prefix}/lib/slurm/certgen_script.so
s2n_prefix=${prefix}/lib/slurm-s2n-1.7.9
ca=${prefix}/etc/ca_cert.pem
slurmd_cert=${prefix}/etc/slurmd_cert.pem
slurmd_key=${prefix}/etc/slurmd_cert_key.pem
inactive_state=${prefix}/.smd407-mac-tls-inactive.env
retained_runtime_state=${prefix}/.smd407-mac-tls-runtime.env
cwd_failure_state=${prefix}/.smd407-mac-tls-job-runtime.env
srun_failure_state=${prefix}/.smd407-mac-tls-job-runtime-20260923T141041.env
mixed_failure_state=${prefix}/.smd407-mac-tls-job-runtime-20260923T141746.env
mixed_chdir_failure_state=${prefix}/.smd407-mac-tls-job-runtime-20260923T142205.env
success_state=${prefix}/.smd407-mac-tls-job-runtime-20260923T142627.env
service_target=system/org.schedmd.slurmd
pid_file=/var/run/slurmd.pid
test_user=testuser
test_uid=3001
test_gid=3001
plugin_hash=f1b17c47b94c6ea3a86478a4f35493b30dff1f2d0941a45490e63381dd23cfa3
certgen_plugin_hash=aa36683403a51dcf9baba1190e0ee3ed2b8f81c4c4972229ce924e05bae25ce4
libs2n_hash=b0d957ad211cdeaaa996795b04c2dbe3238575b1b37f17719758b75c434c894a
retained_runtime_state_hash=fee2df1c8a9d6baf76eb3d294583b58609106ad885a6e45cb9f8bcf0349d3aa1
cwd_failure_state_hash=33776ac4f884f8f5c98202350114814f0278c73edfb5c02d571aecb13da21b39
srun_failure_state_hash=5b9b4271694261f1aee97f52fec97c2ca41681422a00ced9adf9b6686556b02f
mixed_failure_state_hash=a6a7edbbbd97ab80cae0b5ab98b17332c95aa8da680bff192912d637ea283743
mixed_chdir_failure_state_hash=d1e5a8552a7a29e9aa2c2e9da056ad8b4781c6c9a5964200b957f056e9ff2bb4
success_state_hash=5e142c8c209295a0c0da0c5571d2b8c94e7c8668765da5f2260d518e1b9951e6
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd407-mac-tls-archive-${mode}-${run_stamp}
archive_dir=${prefix}/.smd407-tls-archive-${run_stamp}
archive_artifacts=${archive_dir}/artifacts
archive_certificates=${archive_dir}/certificates
archive_states=${archive_dir}/states
smoke_output=${run_dir}/smoke-output
success=0
archive_copied=0
active_removed=0
active_job=
initial_pid=
final_job=

fail()
{
	/usr/bin/printf 'error: %s\n' "$*" >&2
	exit 1
}

state_value()
{
	key=$1
	file=$2
	/usr/bin/awk -F= -v wanted="$key" \
		'$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "$file"
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

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null | /usr/bin/awk 'NR == 1 { print; exit }'
}

managed_slurmd_pid()
{
	[ -f "$pid_file" ] || return 1
	candidate=$(/bin/cat "$pid_file")
	case "$candidate" in ''|*[!0-9]*) return 1 ;; esac
	/bin/kill -0 "$candidate" >/dev/null 2>&1 || return 1
	/bin/launchctl procinfo "$candidate" 2>/dev/null | \
		/usr/bin/grep -Fq "$service_target = {" || return 1
	/usr/bin/printf '%s\n' "$candidate"
}

wait_node_idle()
{
	label=$1
	node=$2
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$scontrol" show node "$node" >"${run_dir}/${label}-${node}.txt" 2>/dev/null || true
		state=$(node_field State "${run_dir}/${label}-${node}.txt")
		[ "$state" = IDLE ] && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_job_gone()
{
	job=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		[ -z "$(queue_state "$job")" ] && return 0
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_accounting()
{
	job=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		"$sacct" -j "$job" -n -P \
			--format=JobIDRaw,State,ExitCode,NodeList >"$file" 2>/dev/null || true
		if /usr/bin/awk -F '|' -v job="$job" '
		$1 == job && $2 == "COMPLETED" && $3 == "0:0" && $4 == "PC-210" { job_ok = 1 }
		$1 == job ".batch" && $2 == "COMPLETED" && $3 == "0:0" && $4 == "PC-210" { batch_ok = 1 }
		END { exit !(job_ok && batch_ok) }
		' "$file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

restore_from_archive()
{
	[ "$archive_copied" -eq 1 ] || return 0
	[ -e "$plugin" ] || /bin/cp -p "${archive_artifacts}/tls_s2n.so" "$plugin" || return 1
	[ -e "$s2n_prefix" ] || /bin/cp -pR "${archive_artifacts}/slurm-s2n-1.7.9" \
		"${prefix}/lib/" || return 1
	[ -e "$ca" ] || /bin/cp -p "${archive_certificates}/ca_cert.pem" "$ca" || return 1
	[ -e "$slurmd_cert" ] || /bin/cp -p "${archive_certificates}/slurmd_cert.pem" \
		"$slurmd_cert" || return 1
	[ -e "$slurmd_key" ] || /bin/cp -p "${archive_certificates}/slurmd_cert_key.pem" \
		"$slurmd_key" || return 1
	for state_file in "$inactive_state" "$retained_runtime_state" "$cwd_failure_state" \
		"$srun_failure_state" "$mixed_failure_state" "$mixed_chdir_failure_state" \
		"$success_state"; do
		state_name=${state_file##*/}
		[ -e "$state_file" ] || /bin/cp -p "${archive_states}/${state_name}" \
			"$state_file" || return 1
	done
	return 0
}

cleanup_on_exit()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ -n "$active_job" ]; then
		[ -z "$(queue_state "$active_job")" ] || "$scancel" "$active_job" >/dev/null 2>&1 || true
	fi
	if [ "$success" -ne 1 ] && [ "$active_removed" -eq 1 ]; then
		if restore_from_archive; then
			/usr/bin/printf 'recovery: active Mac TLS artifacts restored from archive=%s\n' \
				"$archive_dir" >&2
		else
			/usr/bin/printf 'fatal recovery: inspect archive=%s and run_dir=%s\n' \
				"$archive_dir" "$run_dir" >&2
		fi
	fi
	exit "$rc"
}

trap cleanup_on_exit EXIT HUP INT TERM

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for macOS'
[ "$(/bin/hostname -s)" = PC-210 ] || fail "unexpected host=$(/bin/hostname -s)"
for command_path in /bin/cat /bin/chmod /bin/cp /bin/date /bin/hostname /bin/kill \
	/bin/launchctl /bin/mkdir /bin/rm /bin/sleep /usr/bin/awk /usr/bin/cmp \
	/usr/bin/env /usr/bin/grep /usr/bin/id /usr/bin/shasum /usr/bin/stat \
	/usr/bin/sudo /usr/bin/uname /usr/sbin/chown; do
	[ -x "$command_path" ] || fail "missing command=$command_path"
done
for required in "$slurm_conf" "$gres_conf" "$slurm_key" "$slurmd" "$scontrol" \
	"$squeue" "$sbatch" "$scancel" "$sacct" "$plugin" "$certgen_plugin" \
	"$s2n_prefix/lib/libs2n.dylib" "$ca" "$slurmd_cert" "$slurmd_key" \
	"$inactive_state" "$retained_runtime_state" "$cwd_failure_state" \
	"$srun_failure_state" "$mixed_failure_state" "$mixed_chdir_failure_state" \
	"$success_state" "$pid_file"; do
	[ -e "$required" ] || fail "missing required input=$required"
done
[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'
[ "$(state_value phase "$retained_runtime_state")" = FAILED_LOCAL_TLS_NONE_RESTORED ] || \
	fail 'retained runtime state phase mismatch'
[ "$(state_value phase "$cwd_failure_state")" = FAILED_LOCAL_TLS_NONE_RESTORED ] || \
	fail 'cwd failure state phase mismatch'
[ "$(state_value phase "$srun_failure_state")" = FAILED_LOCAL_TLS_NONE_RESTORED ] || \
	fail 'srun failure state phase mismatch'
[ "$(state_value phase "$mixed_failure_state")" = FAILED_LOCAL_TLS_NONE_RESTORED ] || \
	fail 'mixed failure state phase mismatch'
[ "$(state_value phase "$mixed_chdir_failure_state")" = FAILED_LOCAL_TLS_NONE_RESTORED ] || \
	fail 'mixed chdir failure state phase mismatch'
[ "$(state_value phase "$success_state")" = TEST_COMPLETE_LOCAL_TLS_NONE_RESTORED ] || \
	fail 'successful runtime state phase mismatch'
[ "$(state_value cpu_job "$success_state")" = 634 ] || fail 'successful CPU job mismatch'
[ "$(state_value srun_job "$success_state")" = 635 ] || fail 'successful srun job mismatch'
[ "$(state_value gpu_job "$success_state")" = 636 ] || fail 'successful GPU job mismatch'
[ "$(state_value mixed_job "$success_state")" = 637 ] || fail 'successful mixed job mismatch'
for state_file in "$inactive_state" "$retained_runtime_state" "$cwd_failure_state" \
	"$srun_failure_state" "$mixed_failure_state" "$mixed_chdir_failure_state" \
	"$success_state"; do
	[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$state_file")" = root:wheel:600 ] || \
		fail "state metadata mismatch=$state_file"
done
[ "$(/usr/bin/shasum -a 256 "$plugin" | /usr/bin/awk '{print $1}')" = "$plugin_hash" ] || \
	fail 'TLS plugin hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$certgen_plugin" | /usr/bin/awk '{print $1}')" = \
	"$certgen_plugin_hash" ] || fail 'certgen plugin hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$s2n_prefix/lib/libs2n.dylib" | /usr/bin/awk '{print $1}')" = \
	"$libs2n_hash" ] || fail 'libs2n hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$retained_runtime_state" | /usr/bin/awk '{print $1}')" = \
	"$retained_runtime_state_hash" ] || fail 'retained runtime state hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$cwd_failure_state" | /usr/bin/awk '{print $1}')" = \
	"$cwd_failure_state_hash" ] || fail 'cwd failure state hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$srun_failure_state" | /usr/bin/awk '{print $1}')" = \
	"$srun_failure_state_hash" ] || fail 'srun failure state hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$mixed_failure_state" | /usr/bin/awk '{print $1}')" = \
	"$mixed_failure_state_hash" ] || fail 'mixed failure state hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$mixed_chdir_failure_state" | /usr/bin/awk '{print $1}')" = \
	"$mixed_chdir_failure_state_hash" ] || fail 'mixed chdir failure state hash mismatch'
[ "$(/usr/bin/shasum -a 256 "$success_state" | /usr/bin/awk '{print $1}')" = \
	"$success_state_hash" ] || fail 'successful runtime state hash mismatch'
if /usr/bin/grep -Eq '^[[:space:]]*(TLSType|TLSParameters)=' "$slurm_conf"; then
	fail 'Mac production slurm.conf contains TLS keys'
fi

umask 077
/bin/mkdir "$run_dir" || fail 'cannot create run directory'
/bin/chmod 0755 "$run_dir" || fail 'cannot make run directory traversable'
initial_pid=$(managed_slurmd_pid) || fail 'slurmd launchd identity mismatch'
export SLURM_CONF="$slurm_conf"
"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
for node in ubuntu PC-210; do wait_node_idle before "$node" || fail "node=$node is not IDLE"; done
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-before.txt" || fail 'cannot read queue'
[ ! -s "${run_dir}/queue-before.txt" ] || fail 'queue is not empty'
/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurmd" "$certgen_plugin" \
	>"${run_dir}/protected-before.sha256" || fail 'cannot hash protected production files'
/usr/bin/printf 'SMD407_MAC_TLS_ARCHIVE_PREFLIGHT_COMPLETE tls=tls/none nodes=IDLE queue=EMPTY slurmd_pid=%s mode=%s run_dir=%s\n' \
	"$initial_pid" "$mode" "$run_dir"

if [ "$mode" = preflight ]; then
	success=1
	exit 0
fi

[ ! -e "$archive_dir" ] || fail "archive already exists=$archive_dir"
/bin/mkdir "$archive_dir" "$archive_artifacts" "$archive_certificates" \
	"$archive_states" || fail 'cannot create archive directories'
/bin/chmod 0700 "$archive_dir" "$archive_artifacts" "$archive_certificates" \
	"$archive_states" || fail 'cannot protect archive directories'
/usr/sbin/chown -R root:wheel "$archive_dir" || fail 'cannot set archive ownership'
/bin/cp -p "$plugin" "${archive_artifacts}/tls_s2n.so" || fail 'cannot archive TLS plugin'
/bin/cp -pR "$s2n_prefix" "$archive_artifacts/" || fail 'cannot archive s2n prefix'
/bin/cp -p "$ca" "$slurmd_cert" "$slurmd_key" "$archive_certificates/" || \
	fail 'cannot archive certificates'
/bin/cp -p "$inactive_state" "$retained_runtime_state" "$cwd_failure_state" \
	"$srun_failure_state" "$mixed_failure_state" "$mixed_chdir_failure_state" \
	"$success_state" "$archive_states/" || fail 'cannot archive runtime states'
{
	/usr/bin/printf 'archive_created=%s\n' "$run_stamp"
	/usr/bin/printf 'classification=TLS_RUNTIME_PASS_ACTIVE_ARTIFACTS_RETIRED\n'
	/usr/bin/printf 'source_prefix=%s\n' "$prefix"
	/usr/bin/printf 'successful_jobs=634,635,636,637\n'
} >"${archive_dir}/archive.env" || fail 'cannot write archive marker'
/bin/chmod 0600 "${archive_dir}/archive.env" || fail 'cannot protect archive marker'
/usr/bin/shasum -a 256 "$plugin" "$s2n_prefix/lib/libs2n.dylib" "$ca" \
	"$slurmd_cert" "$slurmd_key" "$inactive_state" "$retained_runtime_state" \
	"$cwd_failure_state" "$srun_failure_state" "$mixed_failure_state" \
	"$mixed_chdir_failure_state" "$success_state" >"${archive_dir}/source.sha256" || \
	fail 'cannot write source hash manifest'
/usr/bin/shasum -a 256 "${archive_artifacts}/tls_s2n.so" \
	"${archive_artifacts}/slurm-s2n-1.7.9/lib/libs2n.dylib" \
	"${archive_certificates}/ca_cert.pem" "${archive_certificates}/slurmd_cert.pem" \
	"${archive_certificates}/slurmd_cert_key.pem" "${archive_states}/${inactive_state##*/}" \
	"${archive_states}/${retained_runtime_state##*/}" \
	"${archive_states}/${cwd_failure_state##*/}" \
	"${archive_states}/${srun_failure_state##*/}" \
	"${archive_states}/${mixed_failure_state##*/}" \
	"${archive_states}/${mixed_chdir_failure_state##*/}" \
	"${archive_states}/${success_state##*/}" >"${archive_dir}/archive.sha256" || \
	fail 'cannot write archive hash manifest'
archive_copied=1
/usr/bin/cmp -s "$plugin" "${archive_artifacts}/tls_s2n.so" || \
	fail 'archived TLS plugin bytes mismatch'
/usr/bin/cmp -s "$s2n_prefix/lib/libs2n.dylib" \
	"${archive_artifacts}/slurm-s2n-1.7.9/lib/libs2n.dylib" || \
	fail 'archived libs2n bytes mismatch'
for source_file in "$ca" "$slurmd_cert" "$slurmd_key"; do
	source_name=${source_file##*/}
	/usr/bin/cmp -s "$source_file" "${archive_certificates}/${source_name}" || \
		fail "archived certificate bytes mismatch=$source_name"
done
for source_file in "$inactive_state" "$retained_runtime_state" "$cwd_failure_state" \
	"$srun_failure_state" "$mixed_failure_state" "$mixed_chdir_failure_state" \
	"$success_state"; do
	source_name=${source_file##*/}
	/usr/bin/cmp -s "$source_file" "${archive_states}/${source_name}" || \
		fail "archived state bytes mismatch=$source_name"
done
[ "$(/usr/bin/shasum -a 256 "${archive_artifacts}/tls_s2n.so" | /usr/bin/awk '{print $1}')" = \
	"$plugin_hash" ] || fail 'archived TLS plugin hash mismatch'
[ "$(/usr/bin/shasum -a 256 "${archive_artifacts}/slurm-s2n-1.7.9/lib/libs2n.dylib" | \
	/usr/bin/awk '{print $1}')" = "$libs2n_hash" ] || fail 'archived libs2n hash mismatch'
[ "$(/usr/bin/shasum -a 256 "${archive_states}/${success_state##*/}" | \
	/usr/bin/awk '{print $1}')" = "$success_state_hash" ] || fail 'archived success state hash mismatch'

if [ "$mode" = stage ]; then
	success=1
	/usr/bin/printf 'SMD407_MAC_TLS_ARCHIVE_STAGED active_artifacts=UNCHANGED certificates=COPIED states=COPIED hashes=PASS archive=%s run_dir=%s\n' \
		"$archive_dir" "$run_dir"
	exit 0
fi

/bin/rm -f "$plugin" "$ca" "$slurmd_cert" "$slurmd_key"
/bin/rm -rf "$s2n_prefix"
/bin/rm -f "$inactive_state" "$retained_runtime_state" "$cwd_failure_state" \
	"$srun_failure_state" "$mixed_failure_state" "$mixed_chdir_failure_state" \
	"$success_state"
active_removed=1
for removed in "$plugin" "$s2n_prefix" "$ca" "$slurmd_cert" "$slurmd_key" \
	"$inactive_state" "$retained_runtime_state" "$cwd_failure_state" \
	"$srun_failure_state" "$mixed_failure_state" "$mixed_chdir_failure_state" \
	"$success_state"; do
	[ ! -e "$removed" ] || fail "active cleanup target remains=$removed"
done

/bin/mkdir "$smoke_output" || fail 'cannot create smoke output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$smoke_output" || fail 'cannot chown smoke output'
/bin/chmod 0700 "$smoke_output" || fail 'cannot protect smoke output'
cd /tmp || fail 'cannot enter /tmp'
active_job=$(/usr/bin/sudo -u "$test_user" -H /usr/bin/env SLURM_CONF="$slurm_conf" \
	"$sbatch" --parsable --partition=debug --nodelist=PC-210 --nodes=1 --ntasks=1 \
	--cpus-per-task=1 --mem=64M --time=00:01:00 --chdir=/tmp \
	--output="${smoke_output}/smoke-%j.out" --error="${smoke_output}/smoke-%j.err" \
	--wrap='/bin/hostname') || fail 'post-archive TLS-none smoke submission failed'
final_job=$active_job
wait_job_gone "$final_job" || fail 'post-archive smoke remained in queue'
wait_accounting "$final_job" "${run_dir}/smoke-accounting.txt" || \
	fail 'post-archive smoke accounting mismatch'
active_job=
/usr/bin/grep -Fqx 'PC-210.local' "${smoke_output}/smoke-${final_job}.out" || \
	fail 'post-archive smoke hostname mismatch'
[ ! -s "${smoke_output}/smoke-${final_job}.err" ] || fail 'post-archive smoke stderr is not empty'
"$scontrol" ping >"${run_dir}/controller-after.txt" 2>&1 || fail 'final controller ping failed'
for node in ubuntu PC-210; do wait_node_idle after "$node" || fail "final node=$node is not IDLE"; done
"$squeue" -h -w ubuntu,PC-210 >"${run_dir}/queue-after.txt" || fail 'cannot read final queue'
[ ! -s "${run_dir}/queue-after.txt" ] || fail 'final queue is not empty'
[ "$(managed_slurmd_pid)" = "$initial_pid" ] || fail 'slurmd PID changed during archive cleanup'
/usr/bin/shasum -a 256 "$slurm_conf" "$gres_conf" "$slurmd" "$certgen_plugin" \
	>"${run_dir}/protected-after.sha256" || fail 'cannot hash final protected production files'
/usr/bin/cmp -s "${run_dir}/protected-before.sha256" "${run_dir}/protected-after.sha256" || \
	fail 'protected production files changed'

success=1
/usr/bin/printf 'SMD407_MAC_TLS_ARCHIVE_COMPLETE tls=tls/none active_artifacts=ABSENT certificates=ARCHIVED_RETIRED states=ARCHIVED final_smoke_job=%s accounting=COMPLETED_0_0 nodes=IDLE queue=EMPTY slurmd_pid=%s archive=%s run_dir=%s\n' \
	"$final_job" "$initial_pid" "$archive_dir" "$run_dir"
