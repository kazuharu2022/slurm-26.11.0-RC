#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -u

if [ "${SMD405_FIRST_BOOT_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_FIRST_BOOT_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

source_domain=ubuntu24
clone_domain=smd405-backup
clone_uuid=67757283-8233-42d2-80e2-0c7cdc1fc3eb
clone_disk=/home/virtimages/node03/smd405-backup.qcow2
source_disk=/home/virtimages/node03/ubuntu24.04
clone_mac=52:54:00:40:05:01
expected_ctld_pid=197928
expected_dbd_pid=189104
expected_slurmd_pid=1136933
success=0

fail()
{
	printf 'SMD405_FIRST_BOOT_START_FAILED error=%s\n' "$1" >&2
	exit 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$success" -ne 1 ]; then
		state=$(virsh domstate "$clone_domain" 2>/dev/null | tr -d '\r' || true)
		if [ "$state" = running ]; then
			virsh domif-setlink "$clone_domain" "$clone_mac" down >/dev/null 2>&1 || true
			virsh destroy "$clone_domain" >/dev/null 2>&1 || true
		fi
		printf '%s\n' 'recovery=live_link_down_clone_stopped_if_running' >&2
	fi
	exit "$rc"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(uname -s)" = Linux ] || fail 'run on Ubuntu Linux'
for command in virsh qemu-img xmllint systemctl nc; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command=$command"
done

[ "$(virsh domstate "$source_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'source VM is not shut off'
[ "$(virsh domstate "$clone_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'clone VM is not shut off'
[ "$(virsh domuuid "$clone_domain")" = "$clone_uuid" ] || \
	fail 'clone UUID mismatch'
virsh dominfo "$clone_domain" | grep -Eq '^Autostart:[[:space:]]+disable$' || \
	fail 'clone autostart is not disabled'
[ "$(virsh dumpxml --inactive "$clone_domain" | xmllint --xpath \
	"string(/domain/devices/interface[mac/@address='$clone_mac']/link/@state)" -)" = down ] || \
	fail 'persistent clone interface is not down'
virsh domblklist "$clone_domain" --details | \
	awk -v disk="$clone_disk" '$1 == "file" && $2 == "disk" && $4 == disk {
		found = 1
	} END { exit !found }' || fail 'clone disk definition mismatch'
qemu-img info --output=json "$clone_disk" | \
	grep -Fq "\"backing-filename\": \"$source_disk\"" || \
	fail 'clone overlay backing file mismatch'
if fuser "$clone_disk" "$source_disk" >/dev/null 2>&1; then
	fail 'source or clone disk is already in use'
fi

[ "$(systemctl show -p MainPID --value slurmctld)" = "$expected_ctld_pid" ] || \
	fail 'production slurmctld PID changed'
[ "$(systemctl show -p MainPID --value slurmdbd)" = "$expected_dbd_pid" ] || \
	fail 'production slurmdbd PID changed'
[ "$(systemctl show -p MainPID --value slurmd)" = "$expected_slurmd_pid" ] || \
	fail 'production slurmd PID changed'
for service in slurmctld slurmdbd slurmd; do
	[ "$(systemctl is-active "$service")" = active ] || \
		fail "production service is not active: $service"
done

trap cleanup EXIT HUP INT TERM
virsh start "$clone_domain" || fail 'cannot start clone VM'
attempt=0
while [ "$(virsh domstate "$clone_domain" | tr -d '\r')" != running ]; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 15 ] || fail 'clone did not reach running state'
	sleep 1
done
virsh domif-setlink "$clone_domain" "$clone_mac" up || \
	fail 'cannot set live clone interface up'
live_link_state=$(virsh domif-getlink "$clone_domain" "$clone_mac" | \
	awk 'NF { print $NF; exit }')
case "$live_link_state" in
	up|default) ;;
	*) fail "unexpected live clone interface state=$live_link_state" ;;
esac
[ "$(virsh dumpxml --inactive "$clone_domain" | xmllint --xpath \
	"string(/domain/devices/interface[mac/@address='$clone_mac']/link/@state)" -)" = down ] || \
	fail 'persistent clone interface changed from down'

ip_address=
attempt=0
while [ -z "$ip_address" ]; do
	ip_address=$(virsh domifaddr "$clone_domain" --source arp 2>/dev/null | \
		awk -v mac="$clone_mac" '
			tolower($2) == tolower(mac) && $3 == "ipv4" {
				sub(/\/.*/, "", $4)
				print $4
				exit
			}')
	if [ -z "$ip_address" ]; then
		ip_address=$(ip neigh show dev br0 | awk -v mac="$clone_mac" '
			tolower($5) == tolower(mac) && $1 ~ /^[0-9]+\./ {
				print $1
				exit
			}')
	fi
	if [ -n "$ip_address" ] && ! nc -z -w 1 "$ip_address" 22; then
		ip_address=
	fi
	[ -n "$ip_address" ] && break
	attempt=$((attempt + 1))
	[ "$attempt" -lt 45 ] || fail 'DHCP/ARP address was not discovered'
	sleep 2
done
case "$ip_address" in
	192.168.10.180|192.168.10.128)
		fail "unsafe DHCP address collision=$ip_address"
		;;
esac

success=1
trap - EXIT HUP INT TERM
printf '%s%s%s\n' \
	'SMD405_FIRST_BOOT_START_COMPLETE' \
	" domain=$clone_domain state=running live_link=$live_link_state persistent_link=down" \
	" ip=$ip_address ssh_port=READY"
