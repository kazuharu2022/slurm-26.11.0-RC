#!/bin/sh

set -eu

if [ "${SMD401_PMIX6_INSTALL_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD401_PMIX6_INSTALL_CONFIRMED=YES after approval' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
candidate=/tmp/smd401-pmix6-production-match-attempt4/artifacts/mpi_pmix_v6.so
pmix_prefix=/tmp/smd401-pmix6/pmix
pmix_library=${pmix_prefix}/lib/libpmix.so.2
target=${prefix}/lib/slurm/mpi_pmix_v6.so
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
expected_candidate=1c4b8d44eaf8279d24611c52c70e858410e449385a7627bc97b8be6a552668bb
expected_pmix=46c72eeda9dbc8798fb3308435bc8a511fb0d89a2715c29df5ebb20a0445cc12
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd401-pmix6-install-${run_stamp}
installed=0
success=0

fail()
{
	printf 'SMD401_PMIX6_UBUNTU_INSTALL_FAILED error=%s run_dir=%s\n' \
		"$1" "$run_dir" >&2
	exit 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$installed" -eq 1 ] && \
		[ -f "$target" ] && \
		[ "$(sha256sum "$target" | awk '{print $1}')" = \
		"$expected_candidate" ]; then
		cp -p "$target" "${run_dir}/failed-install-plugin-copy" \
			2>/dev/null || true
		rm -f -- "$target"
		systemctl restart slurmd >"${run_dir}/recovery-restart.out" \
			2>"${run_dir}/recovery-restart.err" || true
		printf '%s\n' 'recovery=temporary_plugin_removed_and_slurmd_restarted' \
			>"${run_dir}/recovery.txt"
	fi
	chmod -R a+rX "$run_dir" >/dev/null 2>&1 || true
	exit "$rc"
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

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(uname -s)" = Linux ] || fail 'run on Ubuntu Linux'
for path in "$candidate" "$pmix_library" "$scontrol" "$squeue" "$srun"; do
	[ -e "$path" ] || fail "missing prerequisite: $path"
done
[ ! -e "$target" ] || fail 'production PMIx v6 plugin already exists'
[ "$(sha256sum "$candidate" | awk '{print $1}')" = \
	"$expected_candidate" ] || fail 'candidate hash mismatch'
[ "$(sha256sum "$pmix_library" | awk '{print $1}')" = \
	"$expected_pmix" ] || fail 'PMIx runtime hash mismatch'
ldd "$candidate" | tee /tmp/smd401-pmix6-candidate-ldd.txt | \
	grep -q 'not found' && fail 'candidate dependency missing'

mkdir -m 0755 "$run_dir"
trap cleanup EXIT HUP INT TERM
chmod -R a+rX /tmp/smd401-pmix6
systemctl is-active slurmctld slurmdbd slurmd \
	>"${run_dir}/services-before.txt" || fail 'Slurm service is not active'
[ "$(grep -c '^active$' "${run_dir}/services-before.txt")" -eq 3 ] || \
	fail 'Slurm service state mismatch'
systemctl show -p MainPID,ActiveState,SubState slurmctld slurmdbd slurmd \
	>"${run_dir}/service-state-before.txt"
ctld_pid_before=$(systemctl show slurmctld -p MainPID --value)
dbd_pid_before=$(systemctl show slurmdbd -p MainPID --value)
slurmd_pid_before=$(systemctl show slurmd -p MainPID --value)
for node in ubuntu PC-210; do
	"$scontrol" show node "$node" >"${run_dir}/node-${node}-before.txt" || \
		fail "cannot read node=$node"
	[ "$(node_field State "${run_dir}/node-${node}-before.txt")" = IDLE ] || \
		fail "node=$node is not IDLE"
	[ "$(node_field CPUAlloc "${run_dir}/node-${node}-before.txt")" = 0 ] || \
		fail "node=$node is allocated"
done
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'target queue is not empty'
"$srun" --mpi=list >"${run_dir}/mpi-list-before.txt" \
	2>"${run_dir}/mpi-list-before.err"
if grep -q 'pmix_v6' "${run_dir}/mpi-list-before.txt"; then
	fail 'production client already lists pmix_v6'
fi
sha256sum "${prefix}/etc/slurm.conf" "${prefix}/sbin/slurmd" \
	"${prefix}/sbin/slurmctld" "$candidate" "$pmix_library" \
	>"${run_dir}/inputs-before.sha256"

install -o root -g root -m 0755 "$candidate" "$target" || \
	fail 'cannot install PMIx v6 plugin'
installed=1
[ "$(sha256sum "$target" | awk '{print $1}')" = \
	"$expected_candidate" ] || fail 'installed plugin hash mismatch'
install_epoch=$(date '+%s')
printf '%s\n' "$install_epoch" >"${run_dir}/install-epoch.txt"
systemctl restart slurmd || fail 'Ubuntu slurmd restart failed'

attempt=0
while [ "$attempt" -lt 60 ]; do
	if systemctl is-active --quiet slurmd; then
		"$scontrol" show node ubuntu >"${run_dir}/node-ubuntu-after.txt" \
			2>"${run_dir}/node-ubuntu-after.err" || true
		if [ -s "${run_dir}/node-ubuntu-after.txt" ] && \
			[ "$(node_field State "${run_dir}/node-ubuntu-after.txt")" = IDLE ]; then
			break
		fi
	fi
	sleep 1
	attempt=$((attempt + 1))
done
[ "$attempt" -lt 60 ] || fail 'Ubuntu slurmd did not return IDLE'
slurmd_pid_after=$(systemctl show slurmd -p MainPID --value)
[ "$slurmd_pid_after" -gt 1 ] || fail 'invalid Ubuntu slurmd PID after restart'
[ "$slurmd_pid_after" != "$slurmd_pid_before" ] || \
	fail 'Ubuntu slurmd PID did not change'
[ "$(systemctl show slurmctld -p MainPID --value)" = "$ctld_pid_before" ] || \
	fail 'slurmctld PID changed'
[ "$(systemctl show slurmdbd -p MainPID --value)" = "$dbd_pid_before" ] || \
	fail 'slurmdbd PID changed'

"$srun" --mpi=list >"${run_dir}/mpi-list-after.txt" \
	2>"${run_dir}/mpi-list-after.err"
grep -F 'specific pmix plugin versions available: pmix_v6' \
	"${run_dir}/mpi-list-after.txt" >/dev/null || \
	fail 'production client does not list pmix_v6'
[ ! -s "${run_dir}/mpi-list-after.err" ] || fail 'mpi list emitted stderr'
"$scontrol" show node PC-210 >"${run_dir}/node-PC-210-after.txt" || \
	fail 'cannot read final Mac node'
[ "$(node_field State "${run_dir}/node-PC-210-after.txt")" = IDLE ] || \
	fail 'Mac node is not IDLE'
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'final target queue is not empty'
journalctl -u slurmd --since "@${install_epoch}" --no-pager \
	>"${run_dir}/slurmd-journal.txt" 2>"${run_dir}/slurmd-journal.err" || true
if grep -Ei 'unable to resolve MPI plugin|mpi/pmix.*(error|failed)' \
	"${run_dir}/slurmd-journal.txt" >"${run_dir}/unexpected-pmix-errors.txt"; then
	fail 'PMIx-specific restart error detected'
fi
sha256sum "${prefix}/etc/slurm.conf" "${prefix}/sbin/slurmd" \
	"${prefix}/sbin/slurmctld" "$candidate" "$pmix_library" \
	>"${run_dir}/inputs-after.sha256"
cmp -s "${run_dir}/inputs-before.sha256" \
	"${run_dir}/inputs-after.sha256" || fail 'non-plugin input changed'
chmod -R a+rX "$run_dir"

success=1
trap - EXIT HUP INT TERM
printf '%s%s%s%s\n' \
	'SMD401_PMIX6_UBUNTU_INSTALL_COMPLETE' \
	" target=$target sha256=$expected_candidate" \
	" slurmd_pid=${slurmd_pid_before}->${slurmd_pid_after}" \
	" production_config_unchanged=PASS run_dir=$run_dir"
