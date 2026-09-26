#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -u

if [ "${SMD405_VERIFY_CLONE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_VERIFY_CLONE_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

source_domain=ubuntu24
source_disk=/home/virtimages/node03/ubuntu24.04
clone_domain=smd405-backup
clone_disk=/home/virtimages/node03/smd405-backup.qcow2
clone_mac=52:54:00:40:05:01
guest_hostname=slurmctld-bak
expected_key_fingerprint='SHA256:Va4B52U2du/kpndyUhPAAlKPcCYCvTu+Vl/9T3S740M'

mount_dir=
fs_list=
nbd_dev=
module_added=0
connected=0
mounted=0
success=0

fail()
{
	printf 'SMD405_VERIFY_CLONE_FAILED error=%s\n' "$1" >&2
	exit 1
}

cleanup()
{
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$mounted" -eq 1 ] && [ -n "$mount_dir" ]; then
		umount "$mount_dir" >/dev/null 2>&1 || true
	fi
	if [ "$connected" -eq 1 ] && [ -n "$nbd_dev" ]; then
		qemu-nbd --disconnect "$nbd_dev" >/dev/null 2>&1 || true
		udevadm settle >/dev/null 2>&1 || true
	fi
	[ -n "$fs_list" ] && rm -f -- "$fs_list" >/dev/null 2>&1 || true
	[ -n "$mount_dir" ] && rmdir "$mount_dir" >/dev/null 2>&1 || true
	if [ "$module_added" -eq 1 ]; then
		rmmod nbd >/dev/null 2>&1 || true
	fi
	if [ "$success" -ne 1 ]; then
		printf '%s\n' 'recovery=read_only_mount_unmounted_nbd_disconnected' >&2
	fi
	exit "$rc"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(uname -s)" = Linux ] || fail 'run on Ubuntu Linux'
for command in virsh qemu-img qemu-nbd modprobe rmmod udevadm lsblk \
	mount umount ssh-keygen xmllint; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command=$command"
done

[ "$(virsh domstate "$source_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'source VM is not shut off'
[ "$(virsh domstate "$clone_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'clone VM is not shut off'
virsh dominfo "$clone_domain" | grep -Eq '^Autostart:[[:space:]]+disable$' || \
	fail 'clone autostart is not disabled'
virsh domblklist "$clone_domain" --details | \
	awk -v disk="$clone_disk" '$1 == "file" && $2 == "disk" && $4 == disk {
		found = 1
	} END { exit !found }' || fail 'clone disk definition mismatch'
virsh domiflist "$clone_domain" | \
	awk -v mac="$clone_mac" 'tolower($5) == tolower(mac) { found = 1 }
		END { exit !found }' || fail 'clone MAC definition mismatch'
[ "$(virsh dumpxml --inactive "$clone_domain" | xmllint --xpath \
	"string(/domain/devices/interface[mac/@address='$clone_mac']/link/@state)" -)" = down ] || \
	fail 'clone interface is not down'
[ -f "$clone_disk" ] || fail 'clone overlay is absent'
qemu-img info --output=json "$clone_disk" | \
	grep -Fq "\"backing-filename\": \"$source_disk\"" || \
	fail 'clone overlay backing file mismatch'
qemu-img check "$clone_disk" >/dev/null || fail 'clone overlay check failed'
if fuser "$clone_disk" "$source_disk" >/dev/null 2>&1; then
	fail 'source or clone disk is already in use'
fi

trap cleanup EXIT HUP INT TERM
if ! grep -q '^nbd ' /proc/modules; then
	modprobe nbd max_part=16 || fail 'cannot load nbd module'
	module_added=1
fi
for candidate in /dev/nbd0 /dev/nbd1 /dev/nbd2 /dev/nbd3 \
	/dev/nbd4 /dev/nbd5 /dev/nbd6 /dev/nbd7; do
	[ -b "$candidate" ] || continue
	base=${candidate##*/}
	if [ ! -s "/sys/class/block/${base}/pid" ]; then
		nbd_dev=$candidate
		break
	fi
done
[ -n "$nbd_dev" ] || fail 'no unused nbd device'

qemu-nbd --read-only --connect="$nbd_dev" "$clone_disk" || \
	fail 'cannot connect clone overlay read-only'
connected=1
base=${nbd_dev##*/}
attempt=0
while [ "$(cat "/sys/class/block/${base}/size" 2>/dev/null || printf 0)" -eq 0 ]; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 10 ] || fail 'nbd device did not expose nonzero size'
	sleep 1
done
udevadm settle || fail 'udev did not settle'
lsblk -rpn -o PATH,FSTYPE,RO,SIZE "$nbd_dev"

mount_dir=$(mktemp -d /tmp/smd405-verify.XXXXXX) || \
	fail 'cannot create mount directory'
fs_list="${mount_dir}.filesystems"
lsblk -rpn -o PATH,FSTYPE "$nbd_dev" >"$fs_list" || \
	fail 'cannot list clone filesystems'
root_device=
while read -r device fstype; do
	case "$device" in "$nbd_dev") continue ;; esac
	[ "$fstype" = ext4 ] || continue
	if mount -t ext4 -o ro,noload "$device" "$mount_dir" 2>/dev/null; then
		mounted=1
		if [ -f "${mount_dir}/etc/os-release" ]; then
			root_device=$device
			break
		fi
		umount "$mount_dir" || fail 'cannot unmount non-root filesystem'
		mounted=0
	fi
done <"$fs_list"
rm -f -- "$fs_list"
fs_list=
[ -n "$root_device" ] || fail 'no ext4 Linux root filesystem in clone'

[ "$(cat "${mount_dir}/etc/hostname")" = "$guest_hostname" ] || \
	fail 'guest hostname mismatch'
awk -v hostname="$guest_hostname" \
	'$1 == "127.0.1.1" && $2 == hostname { found = 1 }
	END { exit !found }' "${mount_dir}/etc/hosts" || \
	fail 'guest hosts mapping mismatch'
machine_id=$(cat "${mount_dir}/etc/machine-id" 2>/dev/null || true)
printf '%s\n' "$machine_id" | grep -Eq '^[0-9a-f]{32}$' || \
	fail 'guest machine-id is invalid'
keys="${mount_dir}/home/REDACTED_USER/.ssh/authorized_keys"
[ -f "$keys" ] || fail 'REDACTED_USER authorized_keys is absent'
ssh-keygen -lf "$keys" | grep -Fq "$expected_key_fingerprint" || \
	fail 'approved SSH key fingerprint is absent'
[ -L "${mount_dir}/etc/systemd/system/multi-user.target.wants/ssh.service" ] || \
	fail 'ssh.service enable link is absent'
[ "$(readlink "${mount_dir}/etc/systemd/system/multi-user.target.wants/ssh.service")" = \
	'/usr/lib/systemd/system/ssh.service' ] || fail 'ssh.service enable target mismatch'
sudoers_file="${mount_dir}/etc/sudoers.d/99-smd405-provision"
[ "$(stat -c '%u:%g:%a' "$sudoers_file" 2>/dev/null || true)" = '0:0:440' ] || \
	fail 'temporary sudo rule metadata mismatch'
grep -Fqx 'REDACTED_USER ALL=(root) NOPASSWD: ALL' "$sudoers_file" || \
	fail 'temporary sudo rule content mismatch'
[ -e "${mount_dir}/etc/cloud/cloud-init.disabled" ] || \
	fail 'cloud-init disabled marker changed'

printf '%s\n' '--- verified clone guest state ---'
printf 'domain=%s uuid=%s state=shut_off autostart=disabled interface=down\n' \
	"$clone_domain" "$(virsh domuuid "$clone_domain")"
printf 'hostname=%s machine_id_format=PASS ssh_enabled=PASS approved_key=PASS temporary_sudo=PASS\n' \
	"$guest_hostname"

umount "$mount_dir" || fail 'cannot unmount clone root'
mounted=0
qemu-nbd --disconnect "$nbd_dev" || fail 'cannot disconnect nbd device'
connected=0
udevadm settle || fail 'udev did not settle after disconnect'
if [ "$module_added" -eq 1 ]; then
	rmmod nbd || fail 'cannot unload nbd module'
	module_added=0
fi
[ "$(virsh domstate "$clone_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'clone VM state changed during verification'

success=1
trap - EXIT HUP INT TERM
rmdir "$mount_dir" >/dev/null 2>&1 || true
printf '%s\n' \
	'SMD405_VERIFY_CLONE_COMPLETE disk_mode=read_only vm_state=shut_off nbd_disconnected=PASS'
