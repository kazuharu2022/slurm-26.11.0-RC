#!/bin/zsh

set -euo pipefail

readonly source_dir="/Users/REDACTED_USER/dev/slurm.26-05"
readonly prefix="/opt/slurm/26.11.0"
readonly config_dir="${prefix}/etc"
readonly runtime_dir="/var/run/slurm"
readonly log_dir="/var/log/slurm"
readonly slurmd_spool_dir="/var/spool/slurmd"
readonly plist_source="${source_dir}/etc/launchd/org.schedmd.slurmd.plist"
readonly plist_target="/Library/LaunchDaemons/org.schedmd.slurmd.plist"
readonly service_target="system/org.schedmd.slurmd"
readonly pid_file="/var/run/slurmd.pid"

if [[ "$(id -u)" -ne 0 ]]; then
	print -u2 "This installer must run as root."
	exit 77
fi

if ! /usr/bin/id slurm >/dev/null 2>&1; then
	print -u2 "The SlurmUser 'slurm' does not exist."
	exit 67
fi

for required_file in \
	"${prefix}/sbin/slurmd" \
	"${prefix}/lib/slurm/libslurmfull.dylib" \
	"${config_dir}/slurm.conf" \
	"${config_dir}/slurm.key" \
	"${config_dir}/gres.conf" \
	"${plist_source}"; do
	if [[ ! -f "${required_file}" ]]; then
		print -u2 "Missing ${required_file}"
		exit 66
	fi
done

/usr/bin/plutil -lint "${plist_source}"

if ! /bin/launchctl print "${service_target}" >/dev/null 2>&1 && \
	[[ -f "${pid_file}" ]]; then
	current_pid="$(/bin/cat "${pid_file}" 2>/dev/null || true)"
	if [[ "${current_pid}" == <-> ]] && \
		/bin/kill -0 "${current_pid}" >/dev/null 2>&1; then
		print -u2 \
			"Refusing to install over unmanaged slurmd pid=${current_pid}." \
			"Stop it through the validated SMD-014 takeover procedure first."
		exit 75
	fi
fi

/usr/bin/install -d -o root -g daemon -m 0755 "${runtime_dir}"
/usr/bin/install -d -o slurm -g slurm -m 0755 "${log_dir}"
/usr/bin/install -d -o slurm -g slurm -m 0755 "${slurmd_spool_dir}"

/usr/bin/install -o root -g wheel -m 0644 \
	"${plist_source}" "${plist_target}"

if /bin/launchctl print "${service_target}" >/dev/null 2>&1; then
	/bin/launchctl bootout "${service_target}"
fi

/bin/launchctl enable "${service_target}"
/bin/launchctl bootstrap system "${plist_target}"

print "Installed and started ${service_target}"
