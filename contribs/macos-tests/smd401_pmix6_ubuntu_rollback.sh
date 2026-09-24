#!/bin/sh

set -eu

if [ "${SMD401_PMIX6_ROLLBACK_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD401_PMIX6_ROLLBACK_CONFIRMED=YES after approval' >&2
	exit 64
fi

prefix=/usr/local/slurm/26.11.0
target=${prefix}/lib/slurm/mpi_pmix_v6.so
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
srun=${prefix}/bin/srun
expected_target=1c4b8d44eaf8279d24611c52c70e858410e449385a7627bc97b8be6a552668bb
run_stamp=$(date '+%Y%m%dT%H%M%S')
run_dir=/tmp/slurm-smd401-pmix6-rollback-${run_stamp}

fail()
{
	printf 'SMD401_PMIX6_UBUNTU_ROLLBACK_FAILED error=%s run_dir=%s\n' \
		"$1" "$run_dir" >&2
	exit 1
}

node_state()
{
	"$scontrol" show node "$1" -o | awk '
	{
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^State=/) { sub(/^State=/, "", $i); print $i; exit }
		}
	}'
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ -f "$target" ] || fail 'temporary PMIx v6 plugin is absent'
[ "$(sha256sum "$target" | awk '{print $1}')" = "$expected_target" ] || \
	fail 'refusing to remove unexpected target content'
mkdir -m 0755 "$run_dir"
[ "$(node_state ubuntu)" = IDLE ] || fail 'Ubuntu node is not IDLE'
[ "$(node_state PC-210)" = IDLE ] || fail 'Mac node is not IDLE'
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'target queue is not empty'
ctld_pid_before=$(systemctl show slurmctld -p MainPID --value)
dbd_pid_before=$(systemctl show slurmdbd -p MainPID --value)
slurmd_pid_before=$(systemctl show slurmd -p MainPID --value)
sha256sum "${prefix}/etc/slurm.conf" "${prefix}/sbin/slurmd" \
	"${prefix}/sbin/slurmctld" >"${run_dir}/production-before.sha256"
cp -p "$target" "${run_dir}/mpi_pmix_v6.so.removed-copy"
rm -f -- "$target"
[ ! -e "$target" ] || fail 'temporary PMIx v6 plugin still exists'
systemctl restart slurmd || fail 'Ubuntu slurmd restart failed'

attempt=0
while [ "$attempt" -lt 60 ]; do
	if systemctl is-active --quiet slurmd && [ "$(node_state ubuntu)" = IDLE ]; then
		break
	fi
	sleep 1
	attempt=$((attempt + 1))
done
[ "$attempt" -lt 60 ] || fail 'Ubuntu slurmd did not return IDLE'
slurmd_pid_after=$(systemctl show slurmd -p MainPID --value)
[ "$slurmd_pid_after" -gt 1 ] || fail 'invalid Ubuntu slurmd PID after rollback'
[ "$slurmd_pid_after" != "$slurmd_pid_before" ] || \
	fail 'Ubuntu slurmd PID did not change during rollback'
[ "$(systemctl show slurmctld -p MainPID --value)" = "$ctld_pid_before" ] || \
	fail 'slurmctld PID changed'
[ "$(systemctl show slurmdbd -p MainPID --value)" = "$dbd_pid_before" ] || \
	fail 'slurmdbd PID changed'
"$srun" --mpi=list >"${run_dir}/mpi-list-final.txt" \
	2>"${run_dir}/mpi-list-final.err"
if grep -q 'pmix_v6' "${run_dir}/mpi-list-final.txt"; then
	fail 'production client still lists pmix_v6'
fi
[ ! -s "${run_dir}/mpi-list-final.err" ] || fail 'final mpi list emitted stderr'
[ "$(node_state PC-210)" = IDLE ] || fail 'Mac node is not IDLE'
[ -z "$("$squeue" -h -w ubuntu,PC-210)" ] || fail 'final target queue is not empty'
sha256sum "${prefix}/etc/slurm.conf" "${prefix}/sbin/slurmd" \
	"${prefix}/sbin/slurmctld" >"${run_dir}/production-after.sha256"
cmp -s "${run_dir}/production-before.sha256" \
	"${run_dir}/production-after.sha256" || fail 'production input changed'
chmod -R a+rX "$run_dir"

printf '%s%s%s%s\n' \
	'SMD401_PMIX6_UBUNTU_ROLLBACK_COMPLETE' \
	" removed=$target sha256=$expected_target" \
	" slurmd_pid=${slurmd_pid_before}->${slurmd_pid_after}" \
	" production_restored=PASS run_dir=$run_dir"
