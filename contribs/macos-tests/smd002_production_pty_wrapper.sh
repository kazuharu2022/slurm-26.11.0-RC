#!/bin/sh

set -u

slurm_prefix=/opt/slurm/26.11.0
slurm_conf=${slurm_prefix}/etc/slurm.conf
srun=${slurm_prefix}/bin/srun

durable_tty_state()
{
	raw_state=$(/bin/stty -g) || return 1
	state_prefix=${raw_state%%lflag=*}
	state_tail=${raw_state#*lflag=}
	lflag_hex=${state_tail%%:*}
	state_suffix=${state_tail#*:}
	# macOS PENDIN (0x20000000) is a transient input-queue state bit.
	lflag_masked=$((0x${lflag_hex} & ~0x20000000))
	lflag_normalized=$(/usr/bin/printf '%x' "$lflag_masked") || return 1
	/usr/bin/printf '%slflag=%s:%s\n' \
		"$state_prefix" "$lflag_normalized" "$state_suffix"
}

cd /tmp || exit 1
printf 'SMD002_WRAPPER_READY\n'
IFS= read -r handshake || exit 1
[ "$handshake" = GO ] || exit 1
before_tty_state=$(durable_tty_state) || exit 1
SLURM_CONF="$slurm_conf" "$srun" \
	--partition=debug \
	--nodes=1 \
	--ntasks=1 \
	--cpus-per-task=1 \
	--mem=1G \
	--time=00:02:00 \
	--chdir=/tmp \
	--job-name=smd002-production-pty \
	--pty /bin/bash --noprofile --norc
srun_rc=$?
after_tty_state=$(durable_tty_state) || exit 1

printf 'SMD002_SRUN_RC=%s\n' "$srun_rc"
if [ "$before_tty_state" = "$after_tty_state" ]; then
	printf 'SMD002_TTY_RESTORE=PASS\n'
else
	printf 'SMD002_TTY_RESTORE=FAIL\n'
	printf 'SMD002_TTY_BEFORE=%s\nSMD002_TTY_AFTER=%s\n' \
		"$before_tty_state" "$after_tty_state"
	exit 1
fi

exit "$srun_rc"
