#!/bin/sh

set -u

if [ "${SMD104_ENVIRONMENT_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s %s\n' \
		'error: set SMD104_ENVIRONMENT_CONFIRMED=YES after accepting' \
		'one batch and one direct srun environment job' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
slurm_conf=${prefix}/etc/slurm.conf
slurmd=${prefix}/sbin/slurmd
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
sbatch=${prefix}/bin/sbatch
srun=${prefix}/bin/srun
scancel=${prefix}/bin/scancel
sacct=${prefix}/bin/sacct
pid_file=/var/run/slurmd.pid
source_dir=/Users/REDACTED_USER/dev/slurm.26-05/contribs/macos-tests
source_payload=${source_dir}/smd104_environment_payload.sh
node_name=PC-210
partition=debug
test_user=testuser
test_uid=3001
test_gid=3001
run_stamp=$(/bin/date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd104-${run_stamp}
input_dir=${run_dir}/input
output_dir=${run_dir}/output
client_conf=${run_dir}/slurm-client.conf
batch_job=
srun_job=
slurmd_pid=
success=0

expected_path=/opt/slurm/26.11.0/bin:/usr/bin:/bin
expected_lang=ja_JP.UTF-8
expected_short=smd104-short-value
expected_unicode=環境伝播-確認
expected_long_length=8192
long_value=$(/usr/bin/awk -v count="$expected_long_length" \
	'BEGIN { for (i = 0; i < count; i++) printf "L" }')
expected_long_sha=$(/usr/bin/printf '%s' "$long_value" | /usr/bin/shasum -a 256 |
	/usr/bin/awk 'NR == 1 { print $1; exit }')

export SLURM_CONF="$slurm_conf"
export SMD104_PARENT_ONLY=must_not_reach_payload

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
	active_job=$1
	[ -n "$active_job" ] || return 0
	state=$(queue_state "$active_job")
	if [ -n "$state" ]; then
		/usr/bin/printf 'cleanup job_id=%s state=%s\n' "$active_job" "$state" >&2
		"$scancel" "$active_job" >/dev/null 2>&1 || true
	fi
}

make_evidence_readable()
{
	[ -d "$run_dir" ] || return 0
	/bin/chmod 0755 "$run_dir" "$input_dir" "$output_dir" 2>/dev/null || true
	/usr/bin/find "$input_dir" "$output_dir" -type f -exec /bin/chmod 0644 {} \; || return 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	cancel_if_active "$batch_job"
	cancel_if_active "$srun_job"
	make_evidence_readable || rc=1
	if [ "$success" -ne 1 ]; then
		/usr/bin/printf 'recovery: no production configuration was changed; inspect run_dir=%s\n' \
			"$run_dir" >&2
	fi
	exit "$rc"
}

wait_job_gone()
{
	active_job=$1
	attempt=0
	while [ "$attempt" -lt 120 ]; do
		if [ -z "$(queue_state "$active_job")" ]; then
			/usr/bin/printf 'job_gone job_id=%s wait_seconds=%s\n' \
				"$active_job" "$attempt"
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

accounting_complete()
{
	active_job=$1
	step_name=$2
	file=$3
	"$sacct" -j "$active_job" -n -P \
		--format=JobIDRaw,User,State,ExitCode,NodeList \
		>"$file" 2>"${file%.txt}.err" || true
	/usr/bin/awk -F '|' -v job="$active_job" -v step="$step_name" -v user="$test_user" '
	$1 == job && $2 == user && $3 == "COMPLETED" && $4 == "0:0" { root_ok = 1 }
	$1 == job "." step && $3 == "COMPLETED" && $4 == "0:0" { step_ok = 1 }
	END { exit !(root_ok && step_ok) }
	' "$file"
}

wait_accounting()
{
	active_job=$1
	step_name=$2
	file=$3
	attempt=0
	while [ "$attempt" -lt 60 ]; do
		if accounting_complete "$active_job" "$step_name" "$file"; then
			return 0
		fi
		/bin/sleep 1
		attempt=$((attempt + 1))
	done
	return 1
}

validate_output()
{
	mode=$1
	active_job=$2
	expected_step_id=$3
	file=$4
	/usr/bin/grep -Fxq "mode=${mode}" "$file" || return 1
	/usr/bin/grep -Fxq "job_id=${active_job}" "$file" || return 1
	case "$expected_step_id" in
	batch-special)
		# 26.11 setup_env() uses %d for the uint32_t batch sentinel while
		# slurm.conf(5) documents its unsigned decimal representation.
		observed_step_id=$(/usr/bin/awk -F '=' \
			'$1 == "step_id" { print $2; exit }' "$file")
		case "$observed_step_id" in
		-5|4294967291) ;;
		*) return 1 ;;
		esac
		;;
	*)
		/usr/bin/grep -Fxq "step_id=${expected_step_id}" "$file" ||
			return 1
		;;
	esac
	/usr/bin/grep -Fxq 'actual_user=testuser' "$file" || return 1
	/usr/bin/grep -Fxq 'actual_uid=3001' "$file" || return 1
	/usr/bin/grep -Fxq 'actual_gid=3001' "$file" || return 1
	/usr/bin/grep -Fxq "home=${test_home}" "$file" || return 1
	/usr/bin/grep -Fxq "path=${expected_path}" "$file" || return 1
	/usr/bin/grep -Fxq "lang=${expected_lang}" "$file" || return 1
	/usr/bin/grep -Fxq "lc_all=${expected_lang}" "$file" || return 1
	/usr/bin/grep -Fxq "short=${expected_short}" "$file" || return 1
	/usr/bin/grep -Fxq "unicode=${expected_unicode}" "$file" || return 1
	/usr/bin/grep -Fxq 'empty_state=SET_EMPTY' "$file" || return 1
	/usr/bin/grep -Fxq "long_length=${expected_long_length}" "$file" || return 1
	/usr/bin/grep -Fxq "long_sha256=${expected_long_sha}" "$file" || return 1
	/usr/bin/grep -Fxq 'unset_state=ABSENT' "$file" || return 1
	/usr/bin/grep -Fxq 'parent_only_state=ABSENT' "$file" || return 1
	/usr/bin/grep -Fxq 'cwd=/private/tmp' "$file" || return 1
	/usr/bin/grep -Fxq "SMD104_PAYLOAD_PASS mode=${mode}" "$file" || return 1
}

normalize_output()
{
	file=$1
	pattern='^(home|path|lang|lc_all|short|unicode|empty_state|long_length|'
	pattern=${pattern}'long_sha256|unset_state|parent_only_state|cwd)='
	/usr/bin/grep -E "$pattern" "$file"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root with sudo'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this driver is for the macOS worker'

for path in "$slurm_conf" "$slurmd" "$scontrol" "$squeue" "$sbatch" "$srun" \
	"$scancel" "$sacct" "$pid_file" "$source_payload"; do
	[ -e "$path" ] || fail "missing $path"
done
for command in /usr/bin/awk /usr/bin/cmp /usr/bin/diff /usr/bin/env /usr/bin/find \
	/usr/bin/grep /usr/bin/id /usr/bin/locale /usr/bin/pgrep /usr/bin/shasum \
	/usr/bin/stat /usr/bin/sudo /usr/bin/tr /usr/bin/wc /usr/sbin/chown \
	/usr/sbin/ipconfig /bin/cat /bin/chmod /bin/cp /bin/date /bin/kill \
	/bin/mkdir /bin/ps /bin/pwd /bin/sleep; do
	[ -x "$command" ] || fail "required command is not executable: $command"
done

[ "$(/usr/bin/id -u "$test_user")" = "$test_uid" ] || fail 'testuser UID mismatch'
[ "$(/usr/bin/id -g "$test_user")" = "$test_gid" ] || fail 'testuser GID mismatch'
test_record=$(/usr/bin/id -P "$test_user" 2>/dev/null) || fail 'cannot read testuser record'
test_home=$(/usr/bin/printf '%s\n' "$test_record" | /usr/bin/awk -F ':' 'NR == 1 { print $9 }')
test_shell=$(/usr/bin/printf '%s\n' "$test_record" | /usr/bin/awk -F ':' 'NR == 1 { print $10 }')
[ -n "$test_home" ] || fail 'testuser HOME is empty'
[ -n "$test_shell" ] || fail 'testuser shell is empty'
/usr/bin/locale -a | /usr/bin/grep -Fxiq "$expected_lang" ||
	fail "locale unavailable: $expected_lang"
[ "${#long_value}" = "$expected_long_length" ] || fail 'long-value construction failed'

cd /tmp || fail 'cannot change directory to /tmp'
/bin/mkdir -m 0755 "$run_dir" "$input_dir" || fail 'cannot create run/input directory'
/bin/mkdir -m 0700 "$output_dir" || fail 'cannot create output directory'
/usr/sbin/chown "$test_uid:$test_gid" "$output_dir" || fail 'cannot chown output directory'
/bin/cp "$source_payload" "${input_dir}/payload.sh" || fail 'cannot stage payload'
/bin/chmod 0555 "${input_dir}/payload.sh" || fail 'cannot set payload mode'

trap cleanup EXIT HUP INT TERM

"$scontrol" ping >"${run_dir}/controller-before.txt" 2>&1 || fail 'controller ping failed'
/usr/bin/grep -q ' is UP$' "${run_dir}/controller-before.txt" || fail 'controller is not UP'
"$scontrol" show node "$node_name" >"${run_dir}/node-before.txt" || fail 'node readback failed'
[ "$(node_field State "${run_dir}/node-before.txt")" = IDLE ] || fail 'node is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-before.txt")" = 0 ] || fail 'node CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-before.txt")" = 0 ] || fail 'node AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'PC-210 has active jobs'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-before.txt" 2>/dev/null; then
	fail 'slurmstepd exists before test'
fi

slurmd_pid=$(/bin/cat "$pid_file")
case "$slurmd_pid" in
''|*[!0-9]*) fail "invalid slurmd pid=$slurmd_pid" ;;
esac
/bin/kill -0 "$slurmd_pid" >/dev/null 2>&1 || fail 'slurmd is not running'

node_ipv4=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || true)
case "$node_ipv4" in
''|*[!0-9.]*) fail "invalid en0 IPv4 address=$node_ipv4" ;;
esac
/usr/bin/awk -v node="$node_name" -v addr="$node_ipv4" '
$1 == "NodeName=" node {
	found_node = 1
	found_addr = 0
	for (i = 1; i <= NF; i++) {
		if ($i ~ /^NodeAddr=/) {
			$i = "NodeAddr=" addr
			found_addr = 1
		}
	}
	if (!found_addr) $0 = $0 " NodeAddr=" addr
}
{ print }
END { if (!found_node) exit 1 }
' "$slurm_conf" >"$client_conf" || fail 'cannot create numeric NodeAddr client config'
/bin/chmod 0644 "$client_conf" || fail 'cannot set client config mode'
SLURM_SACK_KEY=${prefix}/etc/slurm.key "$slurmd" -C -f "$client_conf" \
	>"${run_dir}/client-parse.txt" 2>"${run_dir}/client-parse.err" ||
	fail 'client configuration did not parse'

/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" >"${run_dir}/inputs-before.sha256"
/usr/bin/printf 'run_dir=%s long_length=%s long_sha256=%s client_node_addr=%s\n' \
	"$run_dir" "$expected_long_length" "$expected_long_sha" "$node_ipv4"

batch_job=$(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" \
		/bin/sh -c 'exec /usr/bin/env -i "$@"' sh \
		"HOME=${test_home}" "USER=${test_user}" "LOGNAME=${test_user}" \
		"SHELL=${test_shell}" "PATH=${expected_path}" "LANG=${expected_lang}" \
		"LC_ALL=${expected_lang}" "SMD104_SHORT=${expected_short}" \
		"SMD104_UNICODE=${expected_unicode}" 'SMD104_EMPTY=' \
		"SMD104_LONG=${long_value}" "SLURM_CONF=${slurm_conf}" \
		"$sbatch" --parsable --export=ALL --partition="$partition" \
		--nodes=1 --ntasks=1 --cpus-per-task=1 --mem=128M --time=00:01:00 \
		--chdir=/tmp --job-name=smd104-batch \
		--output="${output_dir}/batch-%j.out" --error="${output_dir}/batch-%j.err" \
		"${input_dir}/payload.sh" batch "$test_home" "$expected_path" \
		"$expected_lang" "$expected_short" "$expected_unicode" \
		"$expected_long_length" "$expected_long_sha"
) || fail 'batch environment job submission failed'
batch_job=${batch_job%%;*}
case "$batch_job" in
''|*[!0-9]*) fail "invalid batch job id=$batch_job" ;;
esac
/usr/bin/printf 'submitted batch_job=%s\n' "$batch_job"
wait_job_gone "$batch_job" || fail 'batch environment job remained in queue'
wait_accounting "$batch_job" batch "${run_dir}/batch-accounting.txt" ||
	fail 'batch environment accounting mismatch'
batch_out=${output_dir}/batch-${batch_job}.out
batch_err=${output_dir}/batch-${batch_job}.err
[ -f "$batch_out" ] || fail 'batch stdout missing'
[ -f "$batch_err" ] || fail 'batch stderr missing'
[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$batch_out")" = "${test_uid}:${test_gid}:644" ] ||
	fail 'batch stdout owner or mode mismatch'
[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$batch_err")" = "${test_uid}:${test_gid}:644" ] ||
	fail 'batch stderr owner or mode mismatch'
[ ! -s "$batch_err" ] || fail 'batch stderr is not empty'
validate_output batch "$batch_job" batch-special "$batch_out" ||
	fail 'batch environment output mismatch'

(
	cd /tmp || exit 1
	/usr/bin/sudo -n -H -u "$test_user" \
		/bin/sh -c 'exec /usr/bin/env -i "$@"' sh \
		"HOME=${test_home}" "USER=${test_user}" "LOGNAME=${test_user}" \
		"SHELL=${test_shell}" "PATH=${expected_path}" "LANG=${expected_lang}" \
		"LC_ALL=${expected_lang}" "SMD104_SHORT=${expected_short}" \
		"SMD104_UNICODE=${expected_unicode}" 'SMD104_EMPTY=' \
		"SMD104_LONG=${long_value}" "SLURM_CONF=${client_conf}" \
		"$srun" --export=ALL --partition="$partition" --nodes=1 --ntasks=1 \
		--cpus-per-task=1 --mem=128M --time=00:01:00 --chdir=/tmp \
		--job-name=smd104-interactive "${input_dir}/payload.sh" interactive \
		"$test_home" "$expected_path" "$expected_lang" "$expected_short" \
		"$expected_unicode" "$expected_long_length" "$expected_long_sha"
) >"${run_dir}/srun.out" 2>"${run_dir}/srun.err"
srun_rc=$?
[ "$srun_rc" -eq 0 ] || fail "direct srun environment job failed rc=$srun_rc"
[ ! -s "${run_dir}/srun.err" ] || fail 'direct srun stderr is not empty'
srun_job=$(/usr/bin/awk -F '=' '$1 == "job_id" { print $2; exit }' "${run_dir}/srun.out")
case "$srun_job" in
''|*[!0-9]*) fail "invalid srun job id=$srun_job" ;;
esac
/usr/bin/printf 'completed srun_job=%s rc=%s\n' "$srun_job" "$srun_rc"
wait_job_gone "$srun_job" || fail 'direct srun job remained in queue'
wait_accounting "$srun_job" 0 "${run_dir}/srun-accounting.txt" ||
	fail 'direct srun accounting mismatch'
validate_output interactive "$srun_job" 0 "${run_dir}/srun.out" ||
	fail 'direct srun environment output mismatch'

normalize_output "$batch_out" >"${run_dir}/batch-environment.txt" ||
	fail 'cannot normalize batch output'
normalize_output "${run_dir}/srun.out" >"${run_dir}/srun-environment.txt" ||
	fail 'cannot normalize srun output'
/usr/bin/cmp -s "${run_dir}/batch-environment.txt" "${run_dir}/srun-environment.txt" ||
	fail 'batch and direct srun controlled environments differ'

"$scontrol" show node "$node_name" >"${run_dir}/node-final.txt" || fail 'final node readback failed'
[ "$(node_field State "${run_dir}/node-final.txt")" = IDLE ] || fail 'final node state is not IDLE'
[ "$(node_field CPUAlloc "${run_dir}/node-final.txt")" = 0 ] || fail 'final CPUAlloc is not zero'
[ "$(node_field AllocMem "${run_dir}/node-final.txt")" = 0 ] || fail 'final AllocMem is not zero'
[ -z "$("$squeue" -h -w "$node_name")" ] || fail 'final queue is not empty'
[ "$(/bin/cat "$pid_file")" = "$slurmd_pid" ] || fail 'slurmd PID changed during SMD-104'
if /usr/bin/pgrep -x slurmstepd >"${run_dir}/slurmstepd-final.txt" 2>/dev/null; then
	fail 'slurmstepd remains after SMD-104'
fi
/bin/ps -axo pid=,ppid=,pgid=,state=,command= >"${run_dir}/processes-final.txt"
/usr/bin/grep -F "$run_dir" "${run_dir}/processes-final.txt" \
	>"${run_dir}/residual-processes.txt" || true
[ ! -s "${run_dir}/residual-processes.txt" ] || fail 'SMD-104 process remains'
/usr/bin/shasum -a 256 "$slurm_conf" "$source_payload" >"${run_dir}/inputs-after.sha256"
/usr/bin/diff -u "${run_dir}/inputs-before.sha256" "${run_dir}/inputs-after.sha256" \
	>"${run_dir}/inputs.diff" || fail 'production config or payload changed during SMD-104'

make_evidence_readable || fail 'cannot make evidence readable'
/usr/bin/printf '%s\n' '[batch-output]'
/bin/cat "$batch_out"
/usr/bin/printf '%s\n' '[batch-accounting]'
/bin/cat "${run_dir}/batch-accounting.txt"
/usr/bin/printf '%s\n' '[srun-output]'
/bin/cat "${run_dir}/srun.out"
/usr/bin/printf '%s\n' '[srun-accounting]'
/bin/cat "${run_dir}/srun-accounting.txt"

success=1
trap - EXIT HUP INT TERM
/usr/bin/printf '%s%s%s\n' \
	"SMD104_ENVIRONMENT_COMPLETE batch_job=${batch_job} srun_job=${srun_job}" \
	" long_bytes=${expected_long_length} slurmd_pid=${slurmd_pid}" \
	" production_unchanged=PASS run_dir=${run_dir}"
