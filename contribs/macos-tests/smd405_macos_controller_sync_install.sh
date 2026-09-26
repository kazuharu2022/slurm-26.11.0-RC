#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -eu

if [ "${SMD405_MAC_CONFIG_INSTALL_CONFIRMED:-}" != YES ]; then
	/usr/bin/printf '%s\n' \
		'error: set SMD405_MAC_CONFIG_INSTALL_CONFIRMED=YES after approval' >&2
	exit 64
fi

prefix=/opt/slurm/26.11.0
config=${prefix}/etc/slurm.conf
scontrol=${prefix}/bin/scontrol
squeue=${prefix}/bin/squeue
pid_file=/var/run/slurmd.pid
service_target=system/org.schedmd.slurmd
state_dir=/private/tmp/slurm-smd405-controller-sync-active
expected_before=62bcea15398de5f373132a1a3ef21c005c184c20f483da076b44eb5af284f157
expected_after=33f1bb4ef72ee0fe750df473c2b8afb103b40e95443740418408ed488325ffdb
mutated=0
success=0
initial_pid=
preexisting_failure_archive=NONE

fail()
{
	/usr/bin/printf 'SMD405_MAC_CONFIG_INSTALL_FAILED error=%s state_dir=%s\n' \
		"$1" "$state_dir" >&2
	exit 1
}

file_hash()
{
	/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

managed_slurmd_pid()
{
	[ -f "$pid_file" ] || return 1
	pid=$(/bin/cat "$pid_file")
	case "$pid" in ''|*[!0-9]*) return 1 ;; esac
	/bin/kill -0 "$pid" >/dev/null 2>&1 || return 1
	/bin/launchctl procinfo "$pid" 2>/dev/null | \
		/usr/bin/grep -Fq "$service_target = {" || return 1
	/usr/bin/printf '%s\n' "$pid"
}

node_is_idle()
{
	node=$1
	label=$2
	out=${state_dir}/${label}-node-${node}.txt
	"$scontrol" show node "$node" >"$out" 2>&1 || return 1
	/usr/bin/grep -Eq '(^|[[:space:]])State=IDLE([[:space:]]|$)' "$out" || return 1
	/usr/bin/grep -Eq '(^|[[:space:]])CPUAlloc=0([[:space:]]|$)' "$out"
}

verify_cluster()
{
	label=$1
	"$scontrol" ping >"${state_dir}/${label}-controller.txt" 2>&1 || return 1
	/usr/bin/grep -Fq 'Slurmctld(primary) at ubuntu2504 is UP' \
		"${state_dir}/${label}-controller.txt" || return 1
	"$squeue" -h >"${state_dir}/${label}-queue.txt" 2>&1 || return 1
	[ ! -s "${state_dir}/${label}-queue.txt" ] || return 1
	node_is_idle ubuntu "$label" || return 1
	node_is_idle PC-210 "$label"
}

atomic_install()
{
	source_file=$1
	target_file=$2
	tmp_file=${target_file}.smd405.$$
	/usr/bin/install -o root -g wheel -m 0644 "$source_file" "$tmp_file" || {
		/bin/rm -f -- "$tmp_file"
		return 1
	}
	/bin/mv -f -- "$tmp_file" "$target_file"
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ] && [ "$mutated" -eq 1 ] && \
		[ -f "${state_dir}/slurm.conf.before" ]; then
		if atomic_install "${state_dir}/slurm.conf.before" "$config" && \
			[ "$(file_hash "$config")" = "$expected_before" ]; then
			if [ -n "$initial_pid" ] && /bin/kill -0 "$initial_pid" >/dev/null 2>&1; then
				/bin/kill -HUP "$initial_pid" >/dev/null 2>&1 || true
			fi
			/usr/bin/printf '%s\n' 'recovery: original Mac config restored and HUP sent' >&2
		else
			/usr/bin/printf '%s\n' 'fatal recovery: Mac config restore failed' >&2
		fi
	fi
	if [ "$success" -ne 1 ] && [ -d "$state_dir" ]; then
		failed_archive=/private/tmp/slurm-smd405-controller-sync-failed-$(/bin/date '+%Y%m%dT%H%M%S')
		/bin/mv "$state_dir" "$failed_archive" >/dev/null 2>&1 || true
		[ -d "$failed_archive" ] && /bin/chmod -R a+rX "$failed_archive" >/dev/null 2>&1 || true
		/usr/bin/printf 'failure_evidence=%s\n' "$failed_archive" >&2
	fi
	exit "$rc"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run as root'
[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'this installer is for macOS'
[ "$(/bin/hostname -s)" = PC-210 ] || fail 'unexpected Mac hostname'
[ "$(file_hash "$config")" = "$expected_before" ] || fail 'production config hash mismatch'
[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$config")" = root:wheel:644 ] || \
	fail 'production config metadata mismatch'
if [ -d "$state_dir" ] && [ -z "$(/bin/ls -A "$state_dir")" ]; then
	preexisting_failure_archive=/private/tmp/slurm-smd405-controller-sync-failed-preflight-$(/bin/date '+%Y%m%dT%H%M%S')
	/bin/mv "$state_dir" "$preexisting_failure_archive" || \
		fail 'cannot archive empty preflight failure state'
	/bin/chmod 0755 "$preexisting_failure_archive" || \
		fail 'cannot make preflight failure evidence readable'
elif [ -e "$state_dir" ]; then
	fail 'active state directory already exists and is not empty'
fi

/bin/mkdir -m 0700 "$state_dir"
trap cleanup EXIT HUP INT TERM
initial_pid=$(managed_slurmd_pid) || fail 'launchd slurmd identity mismatch'
verify_cluster before || fail 'cluster preflight failed'
/bin/cp -p "$config" "${state_dir}/slurm.conf.before" || fail 'config backup failed'
[ "$(file_hash "${state_dir}/slurm.conf.before")" = "$expected_before" ] || \
	fail 'backup hash mismatch'
/usr/bin/awk '
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
[ "$(/usr/bin/grep -c '^SlurmctldHost=' "${state_dir}/slurm.conf.candidate")" -eq 2 ] || \
	fail 'candidate controller count mismatch'
/usr/bin/diff -u "${state_dir}/slurm.conf.before" "${state_dir}/slurm.conf.candidate" \
	>"${state_dir}/config.diff" || [ "$?" -eq 1 ] || fail 'candidate diff failed'

atomic_install "${state_dir}/slurm.conf.candidate" "$config" || fail 'candidate install failed'
mutated=1
[ "$(file_hash "$config")" = "$expected_after" ] || fail 'installed config hash mismatch'
[ "$(/usr/bin/stat -f '%Su:%Sg:%Lp' "$config")" = root:wheel:644 ] || \
	fail 'installed config metadata mismatch'
/bin/kill -HUP "$initial_pid" || fail 'slurmd HUP failed'
/bin/sleep 2
[ "$(managed_slurmd_pid)" = "$initial_pid" ] || fail 'launchd slurmd PID changed'
verify_cluster after || fail 'cluster verification after HUP failed'
{
	/usr/bin/printf 'phase=MAC_CONFIG_INSTALLED_AND_HUP_RELOADED\n'
	/usr/bin/printf 'before_sha256=%s\n' "$expected_before"
	/usr/bin/printf 'after_sha256=%s\n' "$expected_after"
	/usr/bin/printf 'slurmd_pid=%s\n' "$initial_pid"
	/usr/bin/printf 'preexisting_failure_archive=%s\n' "$preexisting_failure_archive"
} >"${state_dir}/state.env"
/bin/chmod 0600 "${state_dir}/state.env"

success=1
trap - EXIT HUP INT TERM
/bin/chmod -R a+rX "$state_dir"
/usr/bin/printf 'SMD405_MAC_CONFIG_INSTALL_PASS before=%s after=%s slurmd_pid_unchanged=%s nodes=IDLE queue=EMPTY state_dir=%s\n' \
	"$expected_before" "$expected_after" "$initial_pid" "$state_dir"
