#!/bin/sh

set -eu

candidate=${SMD401_PMIX_CANDIDATE:-}
production_prefix=${SMD401_PRODUCTION_PREFIX:-/opt/slurm/26.11.0}
default_sha256=aebc2697891d643b4484e3953853fc0f392a57791c6b791bcd32c3f458563c57
expected_sha256=${SMD401_PMIX_EXPECTED_SHA256:-$default_sha256}
run_template=/private/tmp/slurm-smd401-pmix-production-install.XXXXXX
run_dir=${SMD401_INSTALL_RUN_DIR:-$(mktemp -d "$run_template")}
plugin_dir=${production_prefix}/lib/slurm
versioned_plugin=${plugin_dir}/mpi_pmix_v6.so
generic_plugin=${plugin_dir}/mpi_pmix.so
staged_plugin=${versioned_plugin}.smd401-new.$$
staged_link=${generic_plugin}.smd401-new.$$
installed=0

fail()
{
	printf 'SMD401_PMIX_PRODUCTION_INSTALL_FAILED error=%s run_dir=%s\n' \
		"$1" "$run_dir" >&2
	exit 1
}

rollback_new_files()
{
	if [ -L "$staged_link" ]; then
		rm -f "$staged_link"
	fi
	if [ -f "$staged_plugin" ]; then
		rm -f "$staged_plugin"
	fi
	if [ "$installed" -eq 1 ]; then
		if [ -L "$generic_plugin" ] &&
		    [ "$(readlink "$generic_plugin")" = './mpi_pmix_v6.so' ]; then
			rm -f "$generic_plugin"
		fi
		if [ -f "$versioned_plugin" ] &&
		    [ "$(shasum -a 256 "$versioned_plugin" | awk '{print $1}')" = \
		    "$expected_sha256" ]; then
			rm -f "$versioned_plugin"
		fi
	fi
}

make_run_dir_readable()
{
	if [ -d "$run_dir" ]; then
		chmod -R a+rX "$run_dir"
	fi
}

trap 'rollback_new_files; make_run_dir_readable' HUP INT TERM EXIT

[ "$(id -u)" -eq 0 ] || fail 'run as root via sudo'
[ -n "$candidate" ] || fail 'SMD401_PMIX_CANDIDATE is required'
[ -f "$candidate" ] || fail "candidate does not exist: $candidate"
[ -d "$plugin_dir" ] || fail "plugin directory does not exist: $plugin_dir"
[ -x "${production_prefix}/bin/srun" ] || fail 'production srun is absent'
[ -r "${production_prefix}/etc/slurm.conf" ] || fail 'production slurm.conf is absent'
[ ! -e "$versioned_plugin" ] && [ ! -L "$versioned_plugin" ] || \
	fail "refusing to replace existing path: $versioned_plugin"
[ ! -e "$generic_plugin" ] && [ ! -L "$generic_plugin" ] || \
	fail "refusing to replace existing path: $generic_plugin"

candidate_sha256=$(shasum -a 256 "$candidate" | awk '{print $1}')
[ "$candidate_sha256" = "$expected_sha256" ] || \
	fail "candidate SHA-256 mismatch: $candidate_sha256"
file "$candidate" | grep -F 'Mach-O 64-bit bundle arm64' >/dev/null || \
	fail 'candidate is not an arm64 Mach-O bundle'
strings "$candidate" | grep -F 'libpmix.2.dylib' >/dev/null || \
	fail 'candidate does not contain the Darwin PMIx library name'
if strings "$candidate" | grep -F 'libpmix.so.2' >/dev/null; then
	fail 'candidate still contains the Linux PMIx library name'
fi

mkdir -p "$run_dir"
{
	date -u '+utc=%Y-%m-%dT%H:%M:%SZ'
	printf 'candidate=%s\n' "$candidate"
	printf 'candidate_sha256=%s\n' "$candidate_sha256"
	printf 'production_prefix=%s\n' "$production_prefix"
	printf 'versioned_plugin_before=ABSENT\n'
	printf 'generic_plugin_before=ABSENT\n'
} >"${run_dir}/before.txt"
pgrep -x slurmd >"${run_dir}/slurmd-pids-before.txt" 2>/dev/null || true
shasum -a 256 "${production_prefix}/bin/srun" \
	"${production_prefix}/etc/slurm.conf" >"${run_dir}/production-hashes-before.txt"

install -o root -g wheel -m 0755 "$candidate" "$staged_plugin"
staged_sha256=$(shasum -a 256 "$staged_plugin" | awk '{print $1}')
[ "$staged_sha256" = "$expected_sha256" ] || \
	fail "staged SHA-256 mismatch: $staged_sha256"
ln -s ./mpi_pmix_v6.so "$staged_link"
mv "$staged_plugin" "$versioned_plugin"
mv "$staged_link" "$generic_plugin"
installed=1

"${production_prefix}/bin/srun" --mpi=list \
	>"${run_dir}/mpi-list.out" 2>"${run_dir}/mpi-list.err" || \
	fail 'production srun --mpi=list failed'
[ ! -s "${run_dir}/mpi-list.err" ] || \
	fail 'production srun --mpi=list emitted stderr'
grep -F 'pmix' "${run_dir}/mpi-list.out" >/dev/null || \
	fail 'generic pmix plugin was not listed'
grep -F 'pmix_v6' "${run_dir}/mpi-list.out" >/dev/null || \
	fail 'pmix_v6 plugin was not listed'

production_sha256=$(shasum -a 256 "$versioned_plugin" | awk '{print $1}')
[ "$production_sha256" = "$expected_sha256" ] || \
	fail "production SHA-256 mismatch: $production_sha256"
[ -L "$generic_plugin" ] || fail 'generic PMIx plugin is not a symlink'
[ "$(readlink "$generic_plugin")" = './mpi_pmix_v6.so' ] || \
	fail 'generic PMIx symlink target is unexpected'

pgrep -x slurmd >"${run_dir}/slurmd-pids-after.txt" 2>/dev/null || true
shasum -a 256 "$versioned_plugin" "${production_prefix}/bin/srun" \
	"${production_prefix}/etc/slurm.conf" >"${run_dir}/production-hashes-after.txt"
ls -ld "$versioned_plugin" "$generic_plugin" >"${run_dir}/installed-paths.txt"

installed=0
make_run_dir_readable
trap - HUP INT TERM EXIT

printf '%s\n' \
	'SMD401_PMIX_PRODUCTION_INSTALL_COMPLETE' \
	"production_plugin_sha256=$production_sha256" \
	'generic_pmix=LISTED' \
	'pmix_v6=LISTED' \
	'daemon_restart=NO' \
	'job_submission=NO' \
	"run_dir=$run_dir"
