#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -u

if [ "$#" -ne 1 ]; then
	printf 'usage: %s IP_ADDRESS\n' "$0" >&2
	exit 64
fi

ip_address=$1
identity_file=${SMD405_IDENTITY_FILE:-/Users/REDACTED_USER/.ssh/id_ed25519}
expected_key_fingerprint='SHA256:Va4B52U2du/kpndyUhPAAlKPcCYCvTu+Vl/9T3S740M'
known_hosts=

fail()
{
	printf 'SMD405_VERIFY_CONTROLLER_FAILED error=%s\n' "$1" >&2
	exit 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	[ -n "$known_hosts" ] && rm -f -- "$known_hosts" >/dev/null 2>&1 || true
	exit "$rc"
}

case "$ip_address" in
	192.168.10.*) ;;
	*) fail 'guest address is outside approved LAN' ;;
esac
[ -f "$identity_file" ] || fail 'SSH identity file is absent'
[ "$(ssh-keygen -lf "$identity_file" | awk '{print $2}')" = \
	"$expected_key_fingerprint" ] || fail 'SSH identity fingerprint mismatch'
known_hosts=$(mktemp /private/tmp/smd405-controller-known-hosts.XXXXXX) || \
	fail 'cannot create temporary known-hosts file'
trap cleanup EXIT HUP INT TERM

ssh -i "$identity_file" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
	-o "UserKnownHostsFile=$known_hosts" \
	-o ConnectTimeout=10 "REDACTED_USER@${ip_address}" '
		set -eu
		[ "$(hostname)" = slurmctld-bak ]
		grep -Fqx "ID=ubuntu" /etc/os-release
		grep -Fqx "VERSION_ID=\"24.04\"" /etc/os-release
		[ "$(nproc)" -eq 4 ]
		awk "/MemTotal:/ { exit !(\$2 >= 7800000) }" /proc/meminfo
		sudo -n true
		sudo sshd -T | grep -Fqx "passwordauthentication no"
		sudo sshd -T | grep -Fqx "kbdinteractiveauthentication no"
		systemctl is-active --quiet ssh
		printf "guest_hostname=%s\n" "$(hostname)"
		printf "guest_kernel=%s\n" "$(uname -r)"
		printf "guest_boot_id=%s\n" "$(cat /proc/sys/kernel/random/boot_id)"
		printf "guest_ipv4=%s\n" "$(hostname -I | awk "{print \$1}")"
		printf "guest_cloud_init=%s\n" "$(cloud-init status --wait 2>/dev/null | tail -n 1)"
	' || fail 'guest SSH or configuration verification failed'

trap - EXIT HUP INT TERM
rm -f -- "$known_hosts"
known_hosts=
printf '%s%s%s\n' \
	'SMD405_VERIFY_CONTROLLER_COMPLETE' \
	" ip=$ip_address hostname=slurmctld-bak os=ubuntu-24.04" \
	' ssh_key_auth=PASS ssh_password_auth=DISABLED passwordless_sudo=PASS'
