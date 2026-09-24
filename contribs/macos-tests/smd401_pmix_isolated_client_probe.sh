#!/bin/sh

set -eu

candidate=${SMD401_PMIX_CANDIDATE:-}
production_prefix=${SMD401_PRODUCTION_PREFIX:-/opt/slurm/26.11.0}
run_dir=${SMD401_PROBE_RUN_DIR:-$(mktemp -d /private/tmp/slurm-smd401-pmix-client.XXXXXX)}
plugin_dir=${run_dir}/plugins
client_conf=${run_dir}/slurm.conf

fail()
{
	printf 'SMD401_PMIX_CLIENT_PROBE_FAILED error=%s run_dir=%s\n' \
		"$1" "$run_dir" >&2
	exit 1
}

[ -n "$candidate" ] || fail 'SMD401_PMIX_CANDIDATE is required'
[ -f "$candidate" ] || fail "candidate does not exist: $candidate"
[ -x "${production_prefix}/bin/srun" ] || fail 'production srun is absent'
[ -r "${production_prefix}/etc/slurm.conf" ] || fail 'production slurm.conf is absent'

mkdir -p "$plugin_dir"
cp "$candidate" "${plugin_dir}/mpi_pmix_v6.so"
ln -s ./mpi_pmix_v6.so "${plugin_dir}/mpi_pmix.so"

awk -v plugin_path="${plugin_dir}:${production_prefix}/lib/slurm" '
	/^[[:space:]]*PluginDir[[:space:]]*=/ { next }
	{ print }
	END { print "PluginDir=" plugin_path }
' "${production_prefix}/etc/slurm.conf" >"$client_conf"

SLURM_CONF="$client_conf" "${production_prefix}/bin/srun" --mpi=list \
	>"${run_dir}/mpi-list.out" 2>"${run_dir}/mpi-list.err" || \
	fail 'srun --mpi=list failed'

[ ! -s "${run_dir}/mpi-list.err" ] || fail 'srun --mpi=list emitted stderr'
grep -F 'pmix' "${run_dir}/mpi-list.out" >/dev/null || \
	fail 'generic pmix plugin was not listed'
grep -F 'pmix_v6' "${run_dir}/mpi-list.out" >/dev/null || \
	fail 'pmix_v6 plugin was not listed'

file "${plugin_dir}/mpi_pmix_v6.so" >"${run_dir}/candidate-file.txt"
otool -l "${plugin_dir}/mpi_pmix_v6.so" \
	>"${run_dir}/candidate-load-commands.txt"
shasum -a 256 "$candidate" "${production_prefix}/bin/srun" \
	"${production_prefix}/etc/slurm.conf" >"${run_dir}/sha256.txt"

printf '%s\n' \
	'SMD401_PMIX_CLIENT_PROBE_COMPLETE' \
	'generic_pmix=LISTED' \
	'pmix_v6=LISTED' \
	'job_submission=NO' \
	'production=UNCHANGED' \
	"run_dir=$run_dir"
