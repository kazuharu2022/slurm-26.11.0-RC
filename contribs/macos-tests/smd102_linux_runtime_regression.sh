#!/bin/sh

set -eu

fail()
{
	printf '%s\n' "SMD102_LINUX_RUNTIME_REGRESSION_FAILED error=$* run_dir=${run_dir:-NOT_CREATED}" >&2
	exit 1
}

require_command()
{
	command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

as_job_user()
{
	runuser -u "$job_user" -- /bin/sh -c '
		work_dir=$1
		shift
		cd "$work_dir"
		exec "$@"
	' sh "$work_dir" "$@"
}

wait_for_accounting_state()
{
	job_id=$1
	expected=$2
	waited=0

	while [ "$waited" -lt 60 ]; do
		state=$($sacct -X -j "$job_id" -n -P -o State 2>/dev/null |
			awk -F'|' 'NF { sub(/[+ ].*$/, "", $1); print $1; exit }')
		[ "$state" = "$expected" ] && return 0
		sleep 1
		waited=$((waited + 1))
	done

	return 1
}

wait_for_job_running()
{
	job_id=$1
	waited=0

	while [ "$waited" -lt 60 ]; do
		state=$($squeue -h -j "$job_id" -o '%T' 2>/dev/null |
			awk 'NF { print; exit }')
		[ "$state" = RUNNING ] && return 0
		case "$state" in
		FAILED|CANCELLED|COMPLETED|TIMEOUT|NODE_FAIL)
			return 1
			;;
		esac
		sleep 1
		waited=$((waited + 1))
	done

	return 1
}

wait_for_job_absent()
{
	job_id=$1
	waited=0

	while [ "$waited" -lt 60 ]; do
		if ! $squeue -h -j "$job_id" 2>/dev/null | grep . >/dev/null; then
			return 0
		fi
		sleep 1
		waited=$((waited + 1))
	done

	return 1
}

production_health()
{
	[ "$(systemctl is-active slurmctld)" = active ] || return 1
	[ "$(systemctl is-active slurmdbd)" = active ] || return 1
	[ "$(systemctl is-active slurmd)" = active ] || return 1
	$scontrol ping 2>/dev/null | grep -F 'Slurmctld(primary)' >/dev/null || return 1
	$scontrol ping 2>/dev/null | grep -F 'Slurmctld(backup)' >/dev/null || return 1
	$scontrol show node "$node" -o 2>/dev/null |
		grep -E 'State=IDLE([^+A-Z]|$)' >/dev/null || return 1
	$scontrol show node "$node" -o 2>/dev/null |
		grep -F 'CPUAlloc=0 ' >/dev/null || return 1
	[ -z "$($squeue -h)" ] || return 1
}

cleanup_active_jobs()
{
	for cleanup_job in ${normal_job_id:-} ${negative_job_id:-} ${cancel_job_id:-}; do
		case "$cleanup_job" in
		''|*[!0-9]*) continue ;;
		esac
		$squeue -h -j "$cleanup_job" 2>/dev/null | grep . >/dev/null || continue
		$scancel "$cleanup_job" >/dev/null 2>&1 || true
	done
}

on_exit()
{
	rc=$?
	if [ "$rc" -ne 0 ]; then
		cleanup_active_jobs
		printf '%s\n' "postfailure_services=$(systemctl is-active slurmctld 2>/dev/null || true),$(systemctl is-active slurmdbd 2>/dev/null || true),$(systemctl is-active slurmd 2>/dev/null || true)" >&2
		printf '%s\n' 'postfailure_queue_begin' >&2
		$squeue -h -o 'job=%i user=%u state=%T nodes=%N' >&2 2>/dev/null || true
		printf '%s\n' 'postfailure_queue_end' >&2
	fi
}

[ "${SMD102_LINUX_RUNTIME_CONFIRMED:-}" = YES ] || {
	printf '%s\n' 'error: set SMD102_LINUX_RUNTIME_CONFIRMED=YES to run the isolated codegen audit and bounded Ubuntu jobs' >&2
	exit 64
}

[ "$(id -u)" -eq 0 ] || fail 'must run as root'
[ "$(hostname -s)" = ubuntu2504 ] || fail 'must run on ubuntu2504'

for command_name in awk cmp cp diff file gcc getent git grep hostname id install ldd mktemp readelf runuser sha256sum sleep stat strings systemctl uname; do
	require_command "$command_name"
done

prefix=/usr/local/slurm/26.11.0
scontrol=$prefix/bin/scontrol
squeue=$prefix/bin/squeue
sacct=$prefix/bin/sacct
sbatch=$prefix/bin/sbatch
srun=$prefix/bin/srun
scancel=$prefix/bin/scancel

for command_path in "$scontrol" "$squeue" "$sacct" "$sbatch" "$srun" "$scancel"; do
	[ -x "$command_path" ] || fail "required Slurm command is missing: $command_path"
done

trap on_exit EXIT HUP INT TERM

tree=/tmp/slurm-smd102-linux-1e20bbab
build=$tree/build
source_dir=$tree/src/slurmd/slurmstepd
fixed_source=$source_dir/slurmstepd.c
base_repo=/root/slurm/slurm
base_source=$base_repo/src/slurmd/slurmstepd/slurmstepd.c
candidate=$build/src/slurmd/slurmstepd/.libs/slurmstepd
candidate_lib=$build/src/api/.libs/libslurmfull.so
production=$prefix/sbin/slurmstepd
production_build=$base_repo/src/slurmd/slurmstepd/.libs/slurmstepd
node=ubuntu
partition=smd402
job_user=testuser

expected_base_head=a44a5b8cd1704890c183b7dc44984ab1c2e7a519
expected_base_source=a46bca086f4d80338c8971318b656cdc84715b7475e3ca424df8755cb4621c69
expected_fixed_source=1f46ef663bd3b462ad50a68771cd5d2f4f909e604ca5ea912efdaea91dca638b
expected_candidate=9cbdec9cc33de2e9d786c17e8b199cde94a7f4d032ec2a7dbcd8912ea306cae3
expected_candidate_lib=d33252c14ce03c7833536b031d97e921a103937eafd6062e933c736636af2483
expected_production=e8b4f4bdf337fb5b6fd67b83c05a84d1672c0a42a7a73282a88ba7a35e57f72e

for required_file in "$fixed_source" "$base_source" "$candidate" "$candidate_lib" "$production" "$production_build" "$build/config.h"; do
	[ -f "$required_file" ] || fail "required file is missing: $required_file"
done

[ "$(git -C "$base_repo" rev-parse HEAD)" = "$expected_base_head" ] ||
	fail 'production source HEAD changed'
[ -z "$(git -C "$base_repo" status --short -- src/slurmd/slurmstepd/slurmstepd.c)" ] ||
	fail 'production source slurmstepd.c is dirty'
[ "$(sha256sum "$base_source" | awk '{print $1}')" = "$expected_base_source" ] ||
	fail 'base source hash changed'
[ "$(sha256sum "$fixed_source" | awk '{print $1}')" = "$expected_fixed_source" ] ||
	fail 'fixed source hash changed'
[ "$(sha256sum "$candidate" | awk '{print $1}')" = "$expected_candidate" ] ||
	fail 'candidate hash changed'
[ "$(sha256sum "$candidate_lib" | awk '{print $1}')" = "$expected_candidate_lib" ] ||
	fail 'candidate libslurmfull hash changed'
[ "$(sha256sum "$production" | awk '{print $1}')" = "$expected_production" ] ||
	fail 'production slurmstepd hash changed'
cmp -s "$production_build" "$production" ||
	fail 'production slurmstepd does not match current build ELF'

grep -F '#ifdef __APPLE__' "$fixed_source" >/dev/null ||
	fail 'macOS guard is absent from fixed source'
grep -F 'does not match local macOS identity' "$fixed_source" >/dev/null ||
	fail 'identity rejection is absent from fixed source'
if strings "$candidate" | grep -F 'does not match local macOS identity' >/dev/null; then
	fail 'macOS-only rejection string is present in Linux candidate'
fi

if LD_LIBRARY_PATH="$build/src/api/.libs" ldd "$candidate" | grep -F 'not found' >/dev/null; then
	fail 'candidate dependency is unresolved under isolated build library path'
fi

production_health || fail 'production health check failed before audit'

service_pids_before=$(printf '%s,%s,%s' \
	"$(systemctl show slurmctld -p MainPID --value)" \
	"$(systemctl show slurmdbd -p MainPID --value)" \
	"$(systemctl show slurmd -p MainPID --value)")

user_entry=$(getent passwd "$job_user") || fail "job user is absent: $job_user"
job_uid=$(printf '%s\n' "$user_entry" | awk -F: '{print $3}')
job_gid=$(printf '%s\n' "$user_entry" | awk -F: '{print $4}')
job_home=$(printf '%s\n' "$user_entry" | awk -F: '{print $6}')
[ "$job_uid:$job_gid" = 3001:3001 ] || fail "unexpected job identity: $job_uid:$job_gid"

run_stamp=${RUN_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
case "$run_stamp" in
	*[!0-9TZ]*|'') fail 'RUN_STAMP contains unsupported characters' ;;
esac

run_dir=/var/tmp/smd102-linux-runtime-regression-$run_stamp
[ ! -e "$run_dir" ] || fail 'run directory already exists'
install -d -o root -g root -m 0700 "$run_dir"

work_dir=$(runuser -u "$job_user" -- mktemp -d "/var/tmp/smd102-linux-runtime-work-$run_stamp.XXXXXX") ||
	fail 'unable to create job-user work directory'

printf '%s\n' "run_dir=$run_dir" "work_dir=$work_dir" >"$run_dir/paths.txt"

compile_common()
{
	output=$1
	input=$2
	mode=$3

	case "$mode" in
	assembly) output_flag=-S ;;
	object) output_flag=-c ;;
	preprocess) output_flag=-E ;;
	*) fail "unknown compile mode: $mode" ;;
	esac

	(
		cd "$source_dir"
		gcc "$output_flag" -P -O2 -fPIC -fno-ident -pthread \
			-I"$build" -I"$build/slurm" -I"$tree" -I"$source_dir" \
			-x c -o "$output" - <"$input"
	)
}

compile_line_normalized()
{
	output=$1
	input=$2
	mode=$3

	case "$mode" in
	assembly) output_flag=-S ;;
	object) output_flag=-c ;;
	*) fail "unknown normalized compile mode: $mode" ;;
	esac

	(
		cd "$source_dir"
		gcc "$output_flag" -P -O2 -fPIC -fno-ident -pthread \
			-Wno-builtin-macro-redefined -D__LINE__=0 \
			-I"$build" -I"$build/slurm" -I"$tree" -I"$source_dir" \
			-x c -o "$output" - <"$input"
	)
}

compile_common "$run_dir/base.i" "$base_source" preprocess
compile_common "$run_dir/fixed.i" "$fixed_source" preprocess
compile_common "$run_dir/base.s" "$base_source" assembly
compile_common "$run_dir/fixed.s" "$fixed_source" assembly
compile_common "$run_dir/base.o" "$base_source" object
compile_common "$run_dir/fixed.o" "$fixed_source" object

diff -u "$base_source" "$fixed_source" >"$run_dir/source.diff" || true
diff -u "$run_dir/base.i" "$run_dir/fixed.i" >"$run_dir/preprocessor.diff" || true
diff -u "$run_dir/base.s" "$run_dir/fixed.s" >"$run_dir/assembly.diff" || true

if cmp -s "$run_dir/base.s" "$run_dir/fixed.s" &&
	cmp -s "$run_dir/base.o" "$run_dir/fixed.o"; then
	raw_codegen_match=YES
	line_normalized_codegen_match=NOT_REQUIRED
else
	raw_codegen_match=NO_SOURCE_LINE_METADATA_SHIFT
	compile_line_normalized "$run_dir/base-line-normalized.s" "$base_source" assembly
	compile_line_normalized "$run_dir/fixed-line-normalized.s" "$fixed_source" assembly
	compile_line_normalized "$run_dir/base-line-normalized.o" "$base_source" object
	compile_line_normalized "$run_dir/fixed-line-normalized.o" "$fixed_source" object
	diff -u "$run_dir/base-line-normalized.s" "$run_dir/fixed-line-normalized.s" \
		>"$run_dir/assembly-line-normalized.diff" || true
	cmp -s "$run_dir/base-line-normalized.s" "$run_dir/fixed-line-normalized.s" ||
		fail 'Linux assembly differs after source line metadata normalization'
	cmp -s "$run_dir/base-line-normalized.o" "$run_dir/fixed-line-normalized.o" ||
		fail 'Linux object differs after source line metadata normalization'
	line_normalized_codegen_match=YES
fi

if cmp -s "$run_dir/base.i" "$run_dir/fixed.i"; then
	preprocessor_match=YES
else
	preprocessor_match=NO_CODEGEN_STILL_IDENTICAL
fi

sha256sum \
	"$base_source" "$fixed_source" \
	"$run_dir/base.i" "$run_dir/fixed.i" \
	"$run_dir/base.s" "$run_dir/fixed.s" \
	"$run_dir/base.o" "$run_dir/fixed.o" \
	"$candidate" "$candidate_lib" "$production" \
	>"$run_dir/hashes.txt"

if [ "$line_normalized_codegen_match" = YES ]; then
	sha256sum \
		"$run_dir/base-line-normalized.s" "$run_dir/fixed-line-normalized.s" \
		"$run_dir/base-line-normalized.o" "$run_dir/fixed-line-normalized.o" \
		>>"$run_dir/hashes.txt"
fi

cat >"$work_dir/normal.sh" <<'EOF'
#!/bin/sh
set -eu
echo "SMD102_LINUX_NORMAL_BEGIN job=$SLURM_JOB_ID"
echo "batch_uid=$(id -u) batch_gid=$(id -g) arch=$(uname -m) host=$(hostname -s)"
/usr/local/slurm/26.11.0/bin/srun -N1 -n2 /bin/sh -c '
	printf "task=%s uid=%s gid=%s arch=%s host=%s\\n" \
		"$SLURM_PROCID" "$(id -u)" "$(id -g)" "$(uname -m)" "$(hostname -s)"
'
echo 'SMD102_LINUX_NORMAL_END'
EOF

cat >"$work_dir/negative.sh" <<'EOF'
#!/bin/sh
echo "SMD102_LINUX_NEGATIVE_EXPECTED job=$SLURM_JOB_ID uid=$(id -u) gid=$(id -g)"
exit 37
EOF

cat >"$work_dir/cancel.sh" <<EOF
#!/bin/sh
set -eu
echo "SMD102_LINUX_CANCEL_STARTED job=\$SLURM_JOB_ID uid=\$(id -u) gid=\$(id -g)"
sleep 120
printf '%s\n' 'UNEXPECTED_CANCEL_PAYLOAD_COMPLETED' >'$work_dir/cancel-completed'
EOF

normal_submit_rc=0
normal_job_id=$(as_job_user "$sbatch" --parsable --wait \
	-p "$partition" -w "$node" -N1 -n2 \
	-o "$work_dir/normal.out" -e "$work_dir/normal.err" \
	"$work_dir/normal.sh") || normal_submit_rc=$?
normal_job_id=$(printf '%s\n' "$normal_job_id" | awk -F';' 'NF { print $1; exit }')
case "$normal_job_id" in
	''|*[!0-9]*) fail 'normal job id is invalid' ;;
esac
[ "$normal_submit_rc" -eq 0 ] || fail "normal job submission/wait failed rc=$normal_submit_rc job=$normal_job_id"
wait_for_accounting_state "$normal_job_id" COMPLETED ||
	fail "normal job did not reach COMPLETED: $normal_job_id"
grep -F 'SMD102_LINUX_NORMAL_BEGIN' "$work_dir/normal.out" >/dev/null ||
	fail 'normal job begin marker is absent'
grep -F 'SMD102_LINUX_NORMAL_END' "$work_dir/normal.out" >/dev/null ||
	fail 'normal job end marker is absent'
[ "$(grep -Ec '^task=[01] uid=3001 gid=3001 arch=x86_64 host=ubuntu2504$' "$work_dir/normal.out")" -eq 2 ] ||
	fail 'normal two-task identity/architecture output mismatch'
[ ! -s "$work_dir/normal.err" ] || fail 'normal job stderr is not empty'

negative_submit_rc=0
negative_job_id=$(as_job_user "$sbatch" --parsable --wait \
	-p "$partition" -w "$node" -N1 -n1 \
	-o "$work_dir/negative.out" -e "$work_dir/negative.err" \
	"$work_dir/negative.sh") || negative_submit_rc=$?
negative_job_id=$(printf '%s\n' "$negative_job_id" | awk -F';' 'NF { print $1; exit }')
case "$negative_job_id" in
	''|*[!0-9]*) fail 'negative job id is invalid' ;;
esac
[ "$negative_submit_rc" -ne 0 ] || fail 'negative job unexpectedly returned zero from sbatch --wait'
wait_for_accounting_state "$negative_job_id" FAILED ||
	fail "negative job did not reach FAILED: $negative_job_id"
grep -F 'SMD102_LINUX_NEGATIVE_EXPECTED' "$work_dir/negative.out" >/dev/null ||
	fail 'negative job marker is absent'

cancel_job_id=$(as_job_user "$sbatch" --parsable \
	-p "$partition" -w "$node" -N1 -n1 \
	-o "$work_dir/cancel.out" -e "$work_dir/cancel.err" \
	"$work_dir/cancel.sh") || fail 'cancel job submission failed'
cancel_job_id=$(printf '%s\n' "$cancel_job_id" | awk -F';' 'NF { print $1; exit }')
case "$cancel_job_id" in
	''|*[!0-9]*) fail 'cancel job id is invalid' ;;
esac
wait_for_job_running "$cancel_job_id" || fail "cancel job did not reach RUNNING: $cancel_job_id"

started_wait=0
while [ "$started_wait" -lt 30 ]; do
	grep -F 'SMD102_LINUX_CANCEL_STARTED' "$work_dir/cancel.out" >/dev/null 2>&1 && break
	sleep 1
	started_wait=$((started_wait + 1))
done
[ "$started_wait" -lt 30 ] || fail 'cancel job start marker was not observed'

as_job_user "$scancel" "$cancel_job_id" || fail "unable to cancel job: $cancel_job_id"
wait_for_job_absent "$cancel_job_id" || fail "cancel job remained in queue: $cancel_job_id"
wait_for_accounting_state "$cancel_job_id" CANCELLED ||
	fail "cancel job did not reach CANCELLED: $cancel_job_id"
[ ! -e "$work_dir/cancel-completed" ] || fail 'cancelled payload reached forbidden completion marker'

sleep 2
production_health || fail 'production health check failed after jobs'
[ "$(sha256sum "$production" | awk '{print $1}')" = "$expected_production" ] ||
	fail 'production slurmstepd changed during regression'
cmp -s "$production_build" "$production" ||
	fail 'production slurmstepd no longer matches current build ELF'
service_pids_after=$(printf '%s,%s,%s' \
	"$(systemctl show slurmctld -p MainPID --value)" \
	"$(systemctl show slurmdbd -p MainPID --value)" \
	"$(systemctl show slurmd -p MainPID --value)")
[ "$service_pids_after" = "$service_pids_before" ] ||
	fail "service PID changed before=$service_pids_before after=$service_pids_after"

{
	echo 'accounting_begin'
	$sacct -j "$normal_job_id,$negative_job_id,$cancel_job_id" -n -P \
		-o JobIDRaw,JobName,User,State,ExitCode,NodeList
	echo 'accounting_end'
	echo 'node_begin'
	$scontrol show node "$node" -o
	echo 'node_end'
	echo 'controllers_begin'
	$scontrol ping
	echo 'controllers_end'
} >"$run_dir/final-state.txt"

cp "$work_dir/normal.out" "$work_dir/normal.err" \
	"$work_dir/negative.out" "$work_dir/negative.err" \
	"$work_dir/cancel.out" "$work_dir/cancel.err" \
	"$run_dir/"

printf '%s\n' \
	'SMD102_LINUX_RUNTIME_REGRESSION_RESULT' \
	"base_head=$expected_base_head" \
	"base_source_sha256=$expected_base_source" \
	"fixed_source_sha256=$expected_fixed_source" \
	"candidate_sha256=$expected_candidate" \
	"production_sha256=$expected_production" \
	"preprocessor_match=$preprocessor_match" \
	"raw_codegen_match=$raw_codegen_match" \
	"line_normalized_codegen_match=$line_normalized_codegen_match" \
	"normal_job=$normal_job_id state=COMPLETED tasks=2 identity=3001:3001 arch=x86_64" \
	"negative_job=$negative_job_id state=FAILED expected_exit=37" \
	"cancel_job=$cancel_job_id state=CANCELLED forbidden_completion=ABSENT" \
	'queue=EMPTY node=IDLE controllers=BOTH_UP slurmdbd=UP' \
	"service_pids=$service_pids_after" \
	'production_artifacts=UNCHANGED services=UNCHANGED' \
	"run_dir=$run_dir" \
	"work_dir=$work_dir"

cat "$run_dir/final-state.txt"
echo 'SMD102_LINUX_RUNTIME_REGRESSION_COMPLETE'

trap - EXIT HUP INT TERM
exit 0
