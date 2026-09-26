#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_PRIMARY_CONFIG_INSTALL_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_PRIMARY_CONFIG_INSTALL_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/local/slurm/26.11.0/bin:/usr/local/slurm/26.11.0/sbin:/usr/sbin:/usr/bin:/sbin:/bin
LD_LIBRARY_PATH=/usr/local/slurm/26.11.0/lib
export PATH LD_LIBRARY_PATH

config=/usr/local/slurm/26.11.0/etc/slurm.conf
state_dir=/var/tmp/slurm-smd405-controller-sync-active
expected_before=1e6c257b82aa82e507eb710a3e37690ffcfd7b402cb2b33fde53ed9bb1651c68
expected_after=80789e4deb3d946587a7d9c659a6e50d1f32aa400668b333578a36c8352b2b9b
mutated=0
success=0

fail()
{
	printf 'SMD405_PRIMARY_CONFIG_INSTALL_FAILED error=%s state_dir=%s\n' \
		"$1" "$state_dir" >&2
	exit 1
}

file_hash()
{
	sha256sum "$1" | awk '{print $1}'
}

node_is_idle()
{
	node=$1
	out=${state_dir}/before-node-${node}.txt
	scontrol show node "$node" >"$out" 2>&1 || return 1
	grep -Eq '(^|[[:space:]])State=IDLE([[:space:]]|$)' "$out" || return 1
	grep -Eq '(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' "$out"
}

atomic_install()
{
	source_file=$1
	target_file=$2
	tmp_file=${target_file}.smd405.$$
	install -o slurm -g slurm -m 0755 "$source_file" "$tmp_file" || {
		rm -f -- "$tmp_file"
		return 1
	}
	mv -f -- "$tmp_file" "$target_file"
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$mutated" -eq 1 ] && \
		[ -f "${state_dir}/slurm.conf.before" ]; then
		if atomic_install "${state_dir}/slurm.conf.before" "$config" && \
			[ "$(file_hash "$config")" = "$expected_before" ]; then
			printf '%s\n' 'recovery: original primary config restored' >&2
		else
			printf '%s\n' 'fatal recovery: primary config restore failed' >&2
		fi
	fi
	[ -d "$state_dir" ] && chmod -R a+rX "$state_dir" >/dev/null 2>&1 || true
	exit "$rc"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(hostname -s)" = ubuntu2504 ] || fail 'unexpected primary hostname'
[ ! -e "$state_dir" ] || fail 'active state directory already exists'
[ "$(file_hash "$config")" = "$expected_before" ] || fail 'production config hash mismatch'
[ "$(stat -c '%u:%g:%a' "$config")" = 1002:1002:755 ] || \
	fail 'production config metadata mismatch'
[ "$(systemctl is-active slurmctld slurmdbd slurmd | paste -sd, -)" = \
	active,active,active ] || fail 'production service is not fully active'

install -d -o root -g root -m 0700 "$state_dir"
trap cleanup EXIT HUP INT TERM
scontrol ping >"${state_dir}/before-controller.txt" 2>&1 || \
	fail 'primary controller is not reachable'
grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
	"${state_dir}/before-controller.txt" || fail 'primary identity mismatch'
squeue -h >"${state_dir}/before-queue.txt" 2>&1 || fail 'queue probe failed'
[ ! -s "${state_dir}/before-queue.txt" ] || fail 'queue is not empty'
node_is_idle ubuntu || fail 'ubuntu node is not idle'
node_is_idle PC-210 || fail 'PC-210 node is not idle'

ctld_pid=$(systemctl show -p MainPID --value slurmctld)
dbd_pid=$(systemctl show -p MainPID --value slurmdbd)
slurmd_pid=$(systemctl show -p MainPID --value slurmd)
cp -p -- "$config" "${state_dir}/slurm.conf.before"
[ "$(file_hash "${state_dir}/slurm.conf.before")" = "$expected_before" ] || \
	fail 'backup hash mismatch'
awk '
	/^SlurmctldHost=/ {
		if (!written) {
			print "SlurmctldHost=ubuntu2504(192.168.10.180)"
			print "SlurmctldHost=slurmctld-bak(192.168.10.118)"
			written=1
		}
		next
	}
	{ print }
	END { if (!written) exit 42 }
' "${state_dir}/slurm.conf.before" >"${state_dir}/slurm.conf.candidate" || \
	fail 'candidate generation failed'
[ "$(file_hash "${state_dir}/slurm.conf.candidate")" = "$expected_after" ] || \
	fail 'candidate hash mismatch'
[ "$(grep -c '^SlurmctldHost=' "${state_dir}/slurm.conf.candidate")" -eq 2 ] || \
	fail 'candidate controller count mismatch'
diff -u "${state_dir}/slurm.conf.before" "${state_dir}/slurm.conf.candidate" \
	>"${state_dir}/config.diff" || [ "$?" -eq 1 ] || fail 'candidate diff failed'

atomic_install "${state_dir}/slurm.conf.candidate" "$config" || \
	fail 'candidate install failed'
mutated=1
[ "$(file_hash "$config")" = "$expected_after" ] || fail 'installed config hash mismatch'
[ "$(stat -c '%u:%g:%a' "$config")" = 1002:1002:755 ] || \
	fail 'installed config metadata mismatch'
[ "$(systemctl show -p MainPID --value slurmctld)" = "$ctld_pid" ] || \
	fail 'slurmctld PID changed before reconfigure'
[ "$(systemctl show -p MainPID --value slurmdbd)" = "$dbd_pid" ] || \
	fail 'slurmdbd PID changed'
[ "$(systemctl show -p MainPID --value slurmd)" = "$slurmd_pid" ] || \
	fail 'slurmd PID changed'
{
	printf 'phase=PRIMARY_CONFIG_INSTALLED_NOT_RECONFIGURED\n'
	printf 'before_sha256=%s\n' "$expected_before"
	printf 'after_sha256=%s\n' "$expected_after"
	printf 'slurmctld_pid=%s\n' "$ctld_pid"
	printf 'slurmdbd_pid=%s\n' "$dbd_pid"
	printf 'slurmd_pid=%s\n' "$slurmd_pid"
} >"${state_dir}/state.env"
chmod 0600 "${state_dir}/state.env"

success=1
trap - EXIT HUP INT TERM
chmod -R a+rX "$state_dir"
printf 'SMD405_PRIMARY_CONFIG_INSTALL_PASS before=%s after=%s pids=%s,%s,%s state_dir=%s reconfigured=NO\n' \
	"$expected_before" "$expected_after" "$ctld_pid" "$dbd_pid" "$slurmd_pid" "$state_dir"
