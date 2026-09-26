#!/bin/sh

set -eu

if [ "${SLURM_MACOS_PORTING_LINUX_CLEAN_CONFIRMED:-}" != YES ]; then
	echo "Set SLURM_MACOS_PORTING_LINUX_CLEAN_CONFIRMED=YES" >&2
	exit 64
fi

if [ "$(uname -s)" != Linux ]; then
	echo "SLURM_MACOS_PORTING_LINUX_CLEAN_FAILED error=Linux host required" >&2
	exit 77
fi

umask 077

source_url=${SLURM_MACOS_PORTING_SOURCE_URL:-https://github.com/kazuharu2022/slurm-26.11.0-RC.git}
base_commit=a44a5b8cd1704890c183b7dc44984ab1c2e7a519
patch_commit_1=7c5a220180968be5d1ba6c046497fd56d717cdbc
patch_commit_2=1e20bbab8b88a20446ea28b5418ed6a9013a15a7
target_commit=ce597ed8fd1005ca0d8d5e322d4000b3a17410cc
run_stamp=${RUN_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
run_root=/var/tmp/slurm-macos-porting-linux-clean-$run_stamp
source_root=$run_root/source
build_root=$run_root/build
stage_root=$run_root/stage
log_root=$run_root/logs
prefix=/usr/local/slurm/26.11.0
production_slurmd=$prefix/sbin/slurmd
production_slurmstepd=$prefix/sbin/slurmstepd

if [ -e "$run_root" ]; then
	echo "SLURM_MACOS_PORTING_LINUX_CLEAN_FAILED error=run directory already exists run_root=$run_root" >&2
	exit 73
fi

for command_name in git gcc g++ make sha256sum file ldd nproc; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		echo "SLURM_MACOS_PORTING_LINUX_CLEAN_FAILED error=missing command command=$command_name" >&2
		exit 69
	fi
done

for production_path in "$production_slurmd" "$production_slurmstepd"; do
	if [ ! -x "$production_path" ]; then
		echo "SLURM_MACOS_PORTING_LINUX_CLEAN_FAILED error=production artifact absent path=$production_path" >&2
		exit 66
	fi
done

mkdir -p "$build_root" "$stage_root" "$log_root"

production_slurmd_before=$(sha256sum "$production_slurmd" | awk '{print $1}')
production_slurmstepd_before=$(sha256sum "$production_slurmstepd" | awk '{print $1}')
service_state_before=$(
	for service_name in slurmctld slurmdbd slurmd; do
		printf '%s:%s:%s\n' \
			"$service_name" \
			"$(systemctl is-active "$service_name" 2>/dev/null || true)" \
			"$(systemctl show -p MainPID --value "$service_name" 2>/dev/null || true)"
	done
)

postflight()
{
	post_rc=$?
	production_slurmd_after=$(sha256sum "$production_slurmd" | awk '{print $1}')
	production_slurmstepd_after=$(sha256sum "$production_slurmstepd" | awk '{print $1}')
	service_state_after=$(
		for service_name in slurmctld slurmdbd slurmd; do
			printf '%s:%s:%s\n' \
				"$service_name" \
				"$(systemctl is-active "$service_name" 2>/dev/null || true)" \
				"$(systemctl show -p MainPID --value "$service_name" 2>/dev/null || true)"
		done
	)

	echo "postflight_production_slurmd_sha256=$production_slurmd_after"
	echo "postflight_production_slurmstepd_sha256=$production_slurmstepd_after"
	if [ "$production_slurmd_before" = "$production_slurmd_after" ] &&
	   [ "$production_slurmstepd_before" = "$production_slurmstepd_after" ]; then
		echo "postflight_production_artifacts_unchanged=YES"
	else
		echo "postflight_production_artifacts_unchanged=NO"
		post_rc=1
	fi

	if [ "$service_state_before" = "$service_state_after" ]; then
		echo "postflight_service_state_unchanged=YES"
	else
		echo "postflight_service_state_unchanged=NO"
		printf 'service_state_before_begin\n%s\nservice_state_before_end\n' "$service_state_before"
		printf 'service_state_after_begin\n%s\nservice_state_after_end\n' "$service_state_after"
		post_rc=1
	fi

	echo "run_root=$run_root"
	trap - EXIT
	exit "$post_rc"
}
trap postflight EXIT

echo "SLURM_MACOS_PORTING_LINUX_CLEAN_BEGIN"
echo "host=$(hostname -s)"
echo "source_url=$source_url"
echo "base_commit=$base_commit"
echo "target_commit=$target_commit"
echo "production_slurmd_sha256=$production_slurmd_before"
echo "production_slurmstepd_sha256=$production_slurmstepd_before"
printf 'service_state_before_begin\n%s\nservice_state_before_end\n' "$service_state_before"

git clone --quiet --no-checkout "$source_url" "$source_root"
git -C "$source_root" checkout --quiet --detach "$target_commit"

actual_target=$(git -C "$source_root" rev-parse HEAD)
actual_parent_1=$(git -C "$source_root" rev-parse HEAD^)
actual_parent_2=$(git -C "$source_root" rev-parse HEAD^^)
actual_parent_3=$(git -C "$source_root" rev-parse HEAD^^^)

[ "$actual_target" = "$target_commit" ]
[ "$actual_parent_1" = "$patch_commit_2" ]
[ "$actual_parent_2" = "$patch_commit_1" ]
[ "$actual_parent_3" = "$base_commit" ]
[ -z "$(git -C "$source_root" status --porcelain)" ]

echo "commit_chain=PASS"
echo "source_tree=$(git -C "$source_root" rev-parse HEAD^{tree})"
echo "gcc=$(gcc --version | sed -n '1p')"
echo "gxx=$(g++ --version | sed -n '1p')"
echo "make=$(make --version | sed -n '1p')"

cd "$build_root"
"$source_root/configure" --prefix="$prefix" \
	>"$log_root/configure.out" 2>"$log_root/configure.err" || {
	configure_rc=$?
	echo "SLURM_MACOS_PORTING_LINUX_CLEAN_FAILED error=configure rc=$configure_rc" >&2
	tail -n 160 "$log_root/configure.out" >&2 || true
	tail -n 160 "$log_root/configure.err" >&2 || true
	exit "$configure_rc"
}
echo "configure=PASS"
echo "configure_args=$($build_root/config.status --config)"

make -j"$(nproc)" >"$log_root/make.out" 2>"$log_root/make.err" || {
	make_rc=$?
	echo "SLURM_MACOS_PORTING_LINUX_CLEAN_FAILED error=full build rc=$make_rc" >&2
	tail -n 200 "$log_root/make.out" >&2 || true
	tail -n 200 "$log_root/make.err" >&2 || true
	exit "$make_rc"
}
echo "full_build=PASS"

make_check_rc=0
make check >"$log_root/make-check.out" 2>"$log_root/make-check.err" || make_check_rc=$?
make_check_pass_count=$(grep -c '^PASS:' "$log_root/make-check.out" || true)
make_check_fail_count=$(grep -c '^FAIL:' "$log_root/make-check.out" || true)
make_check_skip_count=$(grep -c '^SKIP:' "$log_root/make-check.out" || true)
make_check_zero_summaries=$(grep -c '^# TOTAL: 0$' "$log_root/make-check.out" || true)
echo "make_check_rc=$make_check_rc"
echo "make_check_pass_lines=$make_check_pass_count"
echo "make_check_fail_lines=$make_check_fail_count"
echo "make_check_skip_lines=$make_check_skip_count"
echo "make_check_zero_test_summaries=$make_check_zero_summaries"
if [ "$make_check_rc" -ne 0 ]; then
	echo "SLURM_MACOS_PORTING_LINUX_CLEAN_FAILED error=make check rc=$make_check_rc" >&2
	tail -n 200 "$log_root/make-check.out" >&2 || true
	tail -n 200 "$log_root/make-check.err" >&2 || true
	exit "$make_check_rc"
fi

make DESTDIR="$stage_root" install >"$log_root/install.out" 2>"$log_root/install.err" || {
	install_rc=$?
	echo "SLURM_MACOS_PORTING_LINUX_CLEAN_FAILED error=DESTDIR install rc=$install_rc" >&2
	tail -n 200 "$log_root/install.out" >&2 || true
	tail -n 200 "$log_root/install.err" >&2 || true
	exit "$install_rc"
}

stage_prefix=$stage_root$prefix
stage_slurmd=$stage_prefix/sbin/slurmd
stage_slurmstepd=$stage_prefix/sbin/slurmstepd
[ -x "$stage_slurmd" ]
[ -x "$stage_slurmstepd" ]

stage_file_count=$(find "$stage_prefix" -type f | wc -l | tr -d ' ')
echo "destdir_install=PASS"
echo "stage_file_count=$stage_file_count"
file "$stage_slurmd" "$stage_slurmstepd"
sha256sum "$stage_slurmd" "$stage_slurmstepd"
echo "stage_slurmd_dependencies_begin"
ldd "$stage_slurmd"
echo "stage_slurmd_dependencies_end"
echo "stage_slurmstepd_dependencies_begin"
ldd "$stage_slurmstepd"
echo "stage_slurmstepd_dependencies_end"
echo "production_install=NOT_RUN"
echo "jobs_submitted=0"
echo "SLURM_MACOS_PORTING_LINUX_CLEAN_COMPLETE"
