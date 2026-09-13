#!/bin/sh

set -u

if [ "${SMD124_SPANK_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf 'error: set SMD124_SPANK_CONFIRMED=YES after confirming PC-210 is idle\n' >&2
	exit 64
fi

source_root=/Users/REDACTED_USER/dev/slurm.26-05
prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
sbatch=${prefix}/bin/sbatch
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
clang=/usr/bin/clang
pid_file=/var/run/slurmd.pid
default_plugstack=${prefix}/etc/plugstack.conf
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
task_count=2
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd124-${run_stamp}
plugin=${run_dir}/smd124_spank_noop.so
plugstack=${run_dir}/plugstack.conf
event_log=${run_dir}/spank-events.log
readable_event_log=${run_dir}/spank-events-evidence.txt
output_dir=${run_dir}/output
backup_conf=${run_dir}/slurm.conf.before
candidate_conf=${run_dir}/slurm.conf.smd124
client_conf=${run_dir}/slurm-client.conf
smoke_script=${run_dir}/smoke.sh
test_job=
smoke_job=
config_modified=0
success=0
old_pid=
before_start=
active_start=
node_ipv4=
event_count_before_smoke=

export SLURM_CONF="$slurm_conf"

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

queue_state()
{
	"$squeue" -h -j "$1" -o '%T' 2>/dev/null |
		/usr/bin/awk 'NR == 1 { print; exit }'
}

cancel_if_active()
{
	job_id=$1
	[ -n "$job_id" ] || return 0
	state=$(queue_state "$job_id")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$job_id" "$state" >&2
		"$scancel" "$job_id" >/dev/null 2>&1 || true
	fi
}

wait_job_gone()
{
	job_id=$1
	attempt=0
	while [ "$attempt" -lt 180 ]; do
		if [ -z "$(queue_state "$job_id")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' "$job_id" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_reconfigure()
{
	previous_start=$1
	output_file=$2
	attempt=0
	stable_count=0
	observed_start=
	while [ "$attempt" -lt 180 ]; do
		if "$scontrol" show node "$node_name" >"$output_file" 2>/dev/null; then
			state=$(node_field State "$output_file")
			candidate_start=$(node_field SlurmdStartTime "$output_file")
			if [ "$state" = IDLE ] && [ -n "$candidate_start" ] && \
				[ "$candidate_start" != None ] && \
				[ "$candidate_start" != "$previous_start" ]; then
				observed_start=$candidate_start
				stable_count=$((stable_count + 1))
			else
				stable_count=0
			fi
		else
			stable_count=0
		fi
		if [ "$stable_count" -ge 3 ]; then
			/usr/bin/printf '%s\n' "$observed_start"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

accounting_complete_srun()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList >"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { job_ok = 1 }
		$1 == job ".0" && $3 == "COMPLETED" && $4 == "0:0" { step_ok = 1 }
		END { exit !(job_ok && step_ok) }
	' "$file"
}

accounting_complete_batch()
{
	job_id=$1
	file=$2
	"$sacct" -j "$job_id" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList >"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$job_id" -v user="$test_user" '
		$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { job_ok = 1 }
		$1 == job ".batch" && $3 == "COMPLETED" && $4 == "0:0" { batch_ok = 1 }
		END { exit !(job_ok && batch_ok) }
	' "$file"
}

wait_batch_accounting()
{
	job_id=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if accounting_complete_batch "$job_id" "$file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

wait_srun_accounting()
{
	job_id=$1
	file=$2
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if accounting_complete_srun "$job_id" "$file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

snapshot_event_log()
{
	[ -f "$event_log" ] || return 0
	/bin/cp "$event_log" "$readable_event_log" || return 1
	/usr/sbin/chown 0:0 "$readable_event_log" || return 1
	/bin/chmod 0444 "$readable_event_log" || return 1
}

callback_count()
{
	callback=$1
	context=$2
	/usr/bin/awk -v cb="callback=${callback}" -v ctx="context=${context}" '
		$1 == cb && $2 == ctx { count++ }
		END { print count + 0 }
	' "$event_log"
}

require_callback_count()
{
	callback=$1
	context=$2
	expected=$3
	actual=$(callback_count "$callback" "$context")
	[ "$actual" = "$expected" ] || \
		fail "callback count mismatch callback=$callback context=$context expected=$expected actual=$actual"
}

require_identity_count()
{
	callback=$1
	context=$2
	euid=$3
	egid=$4
	expected=$5
	actual=$(/usr/bin/awk -v cb="callback=${callback}" -v ctx="context=${context}" \
		-v uid="euid=${euid}" -v gid="egid=${egid}" '
		$1 == cb && $2 == ctx && $5 == uid && $6 == gid { count++ }
		END { print count + 0 }
	' "$event_log")
	[ "$actual" = "$expected" ] || \
		fail "callback identity mismatch callback=$callback context=$context euid=$euid egid=$egid expected=$expected actual=$actual"
}

restore_config()
{
	[ "$config_modified" -eq 1 ] || return 0
	/usr/bin/printf 'restore production_config=%s\n' "$slurm_conf" >&2
	/bin/cp "$backup_conf" "$slurm_conf" || return 1
	"$scontrol" reconfigure >"${run_dir}/reconfigure-restore.out" \
		2>"${run_dir}/reconfigure-restore.err" || return 1
	if ! restored_start=$(wait_reconfigure "$active_start" \
		"${run_dir}/node-restored.txt"); then
		return 1
	fi
	/usr/bin/cmp -s "$backup_conf" "$slurm_conf" || return 1
	config_modified=0
	/usr/bin/printf 'production_restored slurmd_pid=%s start=%s\n' \
		"$old_pid" "$restored_start"
	return 0
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$test_job"
	if [ -n "$test_job" ] && ! wait_job_gone "$test_job"; then
		rc=1
	fi
	if ! snapshot_event_log; then
		/usr/bin/printf 'warning: could not snapshot SPANK event log\n' >&2
		rc=1
	fi
	cancel_if_active "$smoke_job"
	if ! restore_config; then
		/usr/bin/printf 'fatal recovery: verify %s against %s and reconfigure\n' \
			"$slurm_conf" "$backup_conf" >&2
		rc=1
	fi
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: inspect run_dir=%s; production config restore was attempted\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for required_file in "$slurm_conf" "$slurmd" "$scontrol" "$squeue" "$srun" \
	"$sbatch" "$scancel" "$sacct" "$clang" "$pid_file" \
	"${source_root}/contribs/macos-tests/smd124_spank_noop.c"; do
	[ -e "$required_file" ] || fail "missing $required_file"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" || fail 'cannot create run directory'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
: >"$event_log" || fail 'cannot create event log'
/bin/chmod 0600 "$event_log" || fail 'cannot protect event log'
/usr/sbin/chown "$test_uid:$test_gid" "$event_log" || fail 'cannot chown event log'
{
	/usr/bin/printf '#!/bin/sh\n'
	/usr/bin/printf 'exit 0\n'
} >"$smoke_script" || fail 'cannot create smoke script'
/bin/chmod 0555 "$smoke_script" || fail 'cannot set smoke mode'
/usr/sbin/chown 0:0 "$smoke_script" || fail 'cannot set smoke owner'
/usr/bin/printf 'run_dir=%s task_count=%s\n' "$run_dir" "$task_count"

"$clang" -Wall -Wextra -Werror -fPIC -bundle -undefined dynamic_lookup \
	-I"${prefix}/include" -o "$plugin" \
	"${source_root}/contribs/macos-tests/smd124_spank_noop.c" \
	>"${run_dir}/compile.out" 2>"${run_dir}/compile.err" || fail 'SPANK plugin compile failed'
/bin/chmod 0555 "$plugin" || fail 'cannot set plugin mode'
/usr/sbin/chown 0:0 "$plugin" || fail 'cannot set plugin owner'
/usr/bin/file "$plugin" >"${run_dir}/plugin-file.txt"
/usr/bin/grep -Fq 'Mach-O 64-bit bundle arm64' "${run_dir}/plugin-file.txt" || \
	fail 'compiled plugin is not an arm64 Mach-O bundle'
/usr/bin/nm -gU "$plugin" >"${run_dir}/plugin-exports.txt" || fail 'cannot inspect plugin exports'
for symbol in plugin_name plugin_type plugin_version spank_plugin_version \
	slurm_spank_init slurm_spank_job_prolog slurm_spank_init_post_opt slurm_spank_local_user_init \
	slurm_spank_user_init slurm_spank_task_init_privileged slurm_spank_task_init \
	slurm_spank_task_post_fork slurm_spank_task_exit slurm_spank_job_epilog \
	slurm_spank_exit; do
	/usr/bin/grep -Eq "[ _]_${symbol}$| _${symbol}$" "${run_dir}/plugin-exports.txt" || \
		fail "missing plugin export=$symbol"
done
/usr/bin/printf 'required %s %s\n' "$plugin" "$event_log" >"$plugstack" || \
	fail 'cannot create plugstack config'
/bin/chmod 0444 "$plugstack" || fail 'cannot set plugstack mode'
/usr/sbin/chown 0:0 "$plugstack" || fail 'cannot set plugstack owner'

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
before_state=$(node_field State "${run_dir}/node-before.txt")
[ "$before_state" = IDLE ] || fail "node state is $before_state, expected IDLE"
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'

old_pid=$(/bin/cat "$pid_file")
case "$old_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$old_pid" ;;
esac
/bin/kill -0 "$old_pid" >/dev/null 2>&1 || fail "slurmd pid=$old_pid is not running"
before_start=$(node_field SlurmdStartTime "${run_dir}/node-before.txt")
node_ipv4=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || true)
case "$node_ipv4" in
''|*[!0-9.]*) fail "invalid en0 IPv4 address=$node_ipv4" ;;
esac
/usr/bin/dscacheutil -q host -a name "${node_name}.local" \
	>"${run_dir}/node-address-readback.txt" 2>"${run_dir}/node-address-readback.err" || \
	fail "cannot resolve ${node_name}.local"
/usr/bin/grep -Fqx "ip_address: ${node_ipv4}" "${run_dir}/node-address-readback.txt" || \
	fail "${node_name}.local does not resolve to en0 address $node_ipv4"

if /usr/bin/grep -Eq '^[[:space:]]*PlugStackConfig[[:space:]]*=' "$slurm_conf"; then
	fail 'production config already has PlugStackConfig; refusing to replace it'
fi
if [ -s "$default_plugstack" ]; then
	fail "default plugstack is non-empty: $default_plugstack"
fi

/bin/cp -p "$slurm_conf" "$backup_conf" || fail 'cannot back up slurm.conf'
/bin/cp "$backup_conf" "$candidate_conf" || fail 'cannot create candidate config'
{
	/usr/bin/printf '\n# SMD-124 temporary SPANK test\n'
	/usr/bin/printf 'PlugStackConfig=%s\n' "$plugstack"
} >>"$candidate_conf" || fail 'cannot append PlugStackConfig'
"$slurmd" -C -f "$candidate_conf" >"${run_dir}/candidate-parse.txt" \
	2>"${run_dir}/candidate-parse.err" || fail 'candidate configuration did not parse'

/usr/bin/awk -v node="$node_name" -v addr="$node_ipv4" '
	$1 == "NodeName=" node {
		for (i = 1; i <= NF; i++) if ($i ~ /^NodeAddr=/) found_addr = 1
		if (!found_addr) $0 = $0 " NodeAddr=" addr
		found_node = 1
	}
	{ print }
	END { if (!found_node) exit 1 }
' "$candidate_conf" >"$client_conf" || fail 'cannot create numeric NodeAddr client config'
/bin/chmod 0644 "$client_conf" || fail 'cannot set client config mode'
"$slurmd" -C -f "$client_conf" >"${run_dir}/client-parse.txt" \
	2>"${run_dir}/client-parse.err" || fail 'client configuration did not parse'
/usr/bin/shasum -a 256 "$backup_conf" >"${run_dir}/config-before.sha256"
/usr/bin/shasum -a 256 "$candidate_conf" >"${run_dir}/config-candidate.sha256"
/usr/bin/shasum -a 256 "$client_conf" >"${run_dir}/config-client.sha256"
/usr/bin/shasum -a 256 "$plugin" >"${run_dir}/plugin.sha256"

/bin/cp "$candidate_conf" "$slurm_conf" || fail 'cannot apply candidate config'
config_modified=1
"$scontrol" reconfigure >"${run_dir}/reconfigure-apply.out" \
	2>"${run_dir}/reconfigure-apply.err" || fail 'candidate reconfigure failed'
active_start=$(wait_reconfigure "$before_start" "${run_dir}/node-active.txt") || \
	fail 'worker did not become stably IDLE with SPANK config'
[ "$(/bin/cat "$pid_file")" = "$old_pid" ] || fail 'slurmd PID changed during reconfigure'
/usr/bin/printf 'spank_config_active slurmd_pid=%s old_start=%s new_start=%s client_node_addr=%s\n' \
	"$old_pid" "$before_start" "$active_start" "$node_ipv4"

set +e
/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$client_conf" \
	"$srun" --partition="$partition" --nodes=1 --ntasks="$task_count" \
	--cpus-per-task=1 --mem=256M --time=00:01:00 --chdir=/tmp \
	--job-name=smd124-spank --kill-on-bad-exit=1 /bin/sleep 1 \
	>"${run_dir}/srun.out" 2>"${run_dir}/srun.err"
srun_rc=$?
set -e
/usr/bin/printf 'srun_rc=%s\n' "$srun_rc"
test_job=$(/usr/bin/awk '$2 == "context=remote" {
	for (i = 1; i <= NF; i++) if ($i ~ /^job_id=[1-9][0-9]*$/) {
		sub(/^job_id=/, "", $i); print $i
	}
}' "$event_log" | /usr/bin/sort -u)
if [ -z "$test_job" ]; then
	test_job=$(/usr/bin/sed -nE \
		's/.*StepId=([1-9][0-9]*)\.[0-9]+.*/\1/p' "${run_dir}/srun.err" | \
		/usr/bin/sort -u)
fi
case "$test_job" in
*[!0-9]*|*' '*) test_job= ;;
esac
[ "$srun_rc" -eq 0 ] || fail "SPANK srun failed rc=$srun_rc job_id=${test_job:-unknown}"
[ -n "$test_job" ] || fail 'could not determine SPANK job id'
wait_job_gone "$test_job" || fail 'SPANK job remained in queue'

require_callback_count slurm_spank_init slurmd 1
require_callback_count slurm_spank_init local 1
require_callback_count slurm_spank_init_post_opt local 1
require_callback_count slurm_spank_local_user_init local 1
require_callback_count slurm_spank_exit local 1
require_callback_count slurm_spank_job_prolog job_script 1
require_callback_count slurm_spank_job_epilog job_script 1
require_callback_count slurm_spank_init remote 1
require_callback_count slurm_spank_init_post_opt remote 1
require_callback_count slurm_spank_user_init remote 1
require_callback_count slurm_spank_task_init_privileged remote "$task_count"
require_callback_count slurm_spank_task_init remote "$task_count"
require_callback_count slurm_spank_task_post_fork remote "$task_count"
require_callback_count slurm_spank_task_exit remote "$task_count"
require_callback_count slurm_spank_exit remote 1

require_identity_count slurm_spank_init slurmd 0 0 1
require_identity_count slurm_spank_init local "$test_uid" "$test_gid" 1
require_identity_count slurm_spank_init_post_opt local "$test_uid" "$test_gid" 1
require_identity_count slurm_spank_local_user_init local "$test_uid" "$test_gid" 1
require_identity_count slurm_spank_exit local "$test_uid" "$test_gid" 1
require_identity_count slurm_spank_job_prolog job_script 0 0 1
require_identity_count slurm_spank_job_epilog job_script 0 0 1
require_identity_count slurm_spank_init remote 0 0 1
require_identity_count slurm_spank_init_post_opt remote 0 0 1
require_identity_count slurm_spank_user_init remote "$test_uid" "$test_gid" 1
require_identity_count slurm_spank_task_init_privileged remote 0 "$test_gid" "$task_count"
require_identity_count slurm_spank_task_post_fork remote 0 "$test_gid" "$task_count"
require_identity_count slurm_spank_task_init remote "$test_uid" "$test_gid" "$task_count"
require_identity_count slurm_spank_task_exit remote 0 "$test_gid" "$task_count"
require_identity_count slurm_spank_exit remote 0 "$test_gid" 1

for callback in slurm_spank_task_init_privileged slurm_spank_task_init \
	slurm_spank_task_post_fork slurm_spank_task_exit; do
	for task_id in 0 1; do
		matches=$(/usr/bin/awk -v cb="callback=${callback}" -v task="task_id=${task_id}" \
			'$1 == cb && $2 == "context=remote" && $4 == task { count++ } END { print count + 0 }' \
			"$event_log")
		[ "$matches" = 1 ] || fail "task callback mismatch callback=$callback task_id=$task_id count=$matches"
	done
done

/usr/bin/awk -v job="job_id=${test_job}" '
	($2 == "context=remote" || $2 == "context=job_script") && $3 != job { bad = 1 }
	END { exit bad }
' "$event_log" || fail 'remote/job_script callback job ID mismatch'
wait_srun_accounting "$test_job" "${run_dir}/test-sacct.txt" || \
	fail 'SPANK job/step accounting did not reach COMPLETED 0:0'
event_count_before_smoke=$(/usr/bin/wc -l <"$event_log" | /usr/bin/tr -d ' ')
[ "$event_count_before_smoke" = 19 ] || \
	fail "unexpected total callback count=$event_count_before_smoke expected=19"
snapshot_event_log || fail 'could not snapshot successful SPANK event log'
/usr/bin/printf 'spank_lifecycle=PASS job_id=%s tasks=%s callbacks=%s slurmd_context=PASS local_context=PASS remote_context=PASS job_script_context=PASS identity=PASS task_ids=0,1\n' \
	"$test_job" "$task_count" "$event_count_before_smoke"

restore_config || fail 'production configuration restore failed'

smoke_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" /usr/bin/env SLURM_CONF="$slurm_conf" \
		"$sbatch" --parsable --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=128M --time=00:01:00 --chdir=/tmp \
		--job-name=smd124-smoke --output="${output_dir}/smoke-%j.out" \
		--error="${output_dir}/smoke-%j.err" "$smoke_script"
) || fail 'post-restore smoke submission failed'
smoke_job=${smoke_job%%;*}
/usr/bin/printf 'submitted smoke_job=%s\n' "$smoke_job"
wait_job_gone "$smoke_job" || fail 'post-restore smoke did not leave queue'
wait_batch_accounting "$smoke_job" "${run_dir}/smoke-sacct.txt" || \
	fail 'post-restore smoke accounting did not reach COMPLETED 0:0'
[ "$event_count_before_smoke" = "$(/usr/bin/wc -l <"$event_log" | /usr/bin/tr -d ' ')" ] || \
	fail 'SPANK plugin ran after production config restore'

"$scontrol" show node "$node_name" >"${run_dir}/node-after.txt" || fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-after.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-after.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-after.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final node queue is not empty'
/usr/bin/cmp -s "$backup_conf" "$slurm_conf" || fail 'final config is not byte-for-byte restored'
/usr/bin/shasum -a 256 "$slurm_conf" >"${run_dir}/config-restored.sha256"

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf 'SMD124_PHASE_A_COMPLETE test_job=%s smoke_job=%s tasks=%s callbacks=%s slurmd_pid=%s run_dir=%s\n' \
	"$test_job" "$smoke_job" "$task_count" "$event_count_before_smoke" "$old_pid" "$run_dir"
