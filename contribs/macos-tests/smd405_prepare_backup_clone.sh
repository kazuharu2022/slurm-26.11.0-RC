#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -u

if [ "${SMD405_PREPARE_CLONE_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_PREPARE_CLONE_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

source_domain=ubuntu24
source_uuid=81cca873-2c1b-4225-83db-1f1deef925cd
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
overlay_created=0
clone_defined=0
success=0

fail()
{
	printf 'SMD405_PREPARE_CLONE_FAILED error=%s\n' "$1" >&2
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
		if [ "$clone_defined" -eq 1 ] &&
			[ "$(virsh domstate "$clone_domain" 2>/dev/null | tr -d '\r')" = 'shut off' ]; then
			virsh undefine "$clone_domain" >/dev/null 2>&1 || true
			clone_defined=0
		fi
		if [ "$overlay_created" -eq 1 ] &&
			! virsh dominfo "$clone_domain" >/dev/null 2>&1; then
			rm -f -- "$clone_disk" >/dev/null 2>&1 || true
		fi
		printf '%s\n' \
			'recovery=nbd_disconnected_partial_clone_removed_if_safe' >&2
	fi
	exit "$rc"
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(uname -s)" = Linux ] || fail 'run on Ubuntu Linux'
for command in virsh virt-clone qemu-img qemu-nbd modprobe rmmod udevadm \
	lsblk mount umount ssh-keygen systemctl systemd-machine-id-setup visudo \
	xmllint; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command=$command"
done

[ -f "$source_disk" ] || fail 'source qcow2 is absent'
[ "$(virsh domstate "$source_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'source VM is not shut off'
[ "$(virsh domuuid "$source_domain")" = "$source_uuid" ] || \
	fail 'source VM UUID mismatch'
virsh domblklist "$source_domain" --details | \
	awk -v disk="$source_disk" '$1 == "file" && $2 == "disk" && $4 == disk {
		found = 1
	} END { exit !found }' || fail 'source disk does not match source VM'
qemu-img info "$source_disk" | grep -Fqx 'file format: qcow2' || \
	fail 'source disk is not qcow2'
if fuser "$source_disk" >/dev/null 2>&1; then
	fail 'source disk is already in use'
fi
if virsh dominfo "$clone_domain" >/dev/null 2>&1; then
	fail 'clone domain already exists'
fi
[ ! -e "$clone_disk" ] || fail 'clone overlay already exists'

mac_conflict=0
virsh list --all --name | while IFS= read -r domain; do
	[ -n "$domain" ] || continue
	virsh domiflist "$domain" | awk 'NR > 2 && NF >= 5 { print $5 }'
done | grep -Fqi "$clone_mac" && mac_conflict=1
[ "$mac_conflict" -eq 0 ] || fail 'clone MAC address is already in use'

source_stat_before=$(stat -c '%s|%Y' "$source_disk") || \
	fail 'cannot stat source disk'

trap cleanup EXIT HUP INT TERM
qemu-img create -f qcow2 -F qcow2 -b "$source_disk" "$clone_disk" || \
	fail 'cannot create clone overlay'
overlay_created=1
chown root:root "$clone_disk" || fail 'cannot set clone overlay owner'
chmod 0600 "$clone_disk" || fail 'cannot set clone overlay mode'
qemu-img info --output=json "$clone_disk" | \
	grep -Fq "\"backing-filename\": \"$source_disk\"" || \
	fail 'clone overlay backing file mismatch'

virt-clone --connect qemu:///system --original "$source_domain" \
	--name "$clone_domain" --file "$clone_disk" --preserve-data \
	--mac "$clone_mac" || fail 'cannot define clone domain'
clone_defined=1
[ "$(virsh domstate "$clone_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'clone domain is not shut off after definition'
virsh dominfo "$clone_domain" | grep -Eq '^Autostart:[[:space:]]+disable$' || \
	fail 'clone domain autostart is not disabled'
virsh domblklist "$clone_domain" --details | \
	awk -v disk="$clone_disk" '$1 == "file" && $2 == "disk" && $4 == disk {
		found = 1
	} END { exit !found }' || fail 'clone disk definition mismatch'
virsh domiflist "$clone_domain" | \
	awk -v mac="$clone_mac" 'tolower($5) == tolower(mac) { found = 1 }
		END { exit !found }' || fail 'clone MAC definition mismatch'
virsh domif-setlink "$clone_domain" "$clone_mac" down --config || \
	fail 'cannot set clone interface link down'
[ "$(virsh dumpxml --inactive "$clone_domain" | xmllint --xpath \
	"string(/domain/devices/interface[mac/@address='$clone_mac']/link/@state)" -)" = down ] || \
	fail 'clone interface link is not down'

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

qemu-nbd --connect="$nbd_dev" "$clone_disk" || \
	fail 'cannot connect clone overlay'
connected=1
base=${nbd_dev##*/}
attempt=0
while [ "$(cat "/sys/class/block/${base}/size" 2>/dev/null || printf 0)" -eq 0 ]; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 10 ] || fail 'nbd device did not expose nonzero size'
	sleep 1
done
udevadm settle || fail 'udev did not settle'

mount_dir=$(mktemp -d /tmp/smd405-prepare.XXXXXX) || \
	fail 'cannot create mount directory'
fs_list="${mount_dir}.filesystems"
lsblk -rpn -o PATH,FSTYPE "$nbd_dev" >"$fs_list" || \
	fail 'cannot list clone filesystems'
root_device=
while read -r device fstype; do
	case "$device" in "$nbd_dev") continue ;; esac
	[ "$fstype" = ext4 ] || continue
	if mount -t ext4 -o rw "$device" "$mount_dir" 2>/dev/null; then
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

grep -Fqx 'ID=ubuntu' "${mount_dir}/etc/os-release" || \
	fail 'clone root is not Ubuntu'
grep -q '^REDACTED_USER:x:1000:1000:' "${mount_dir}/etc/passwd" || \
	fail 'expected REDACTED_USER login user is absent'
keys="${mount_dir}/home/REDACTED_USER/.ssh/authorized_keys"
[ -f "$keys" ] || fail 'REDACTED_USER authorized_keys is absent'
ssh-keygen -lf "$keys" | grep -Fq "$expected_key_fingerprint" || \
	fail 'approved SSH key fingerprint is absent'
[ -x "${mount_dir}/usr/sbin/sshd" ] || fail 'sshd binary is absent'
[ -f "${mount_dir}/lib/systemd/system/ssh.service" ] || \
	[ -f "${mount_dir}/usr/lib/systemd/system/ssh.service" ] || \
	fail 'ssh.service unit is absent'

printf '%s\n' "$guest_hostname" >"${mount_dir}/etc/hostname.smd405-new" || \
	fail 'cannot create guest hostname candidate'
chown --reference="${mount_dir}/etc/hostname" \
	"${mount_dir}/etc/hostname.smd405-new" || fail 'cannot set hostname owner'
chmod --reference="${mount_dir}/etc/hostname" \
	"${mount_dir}/etc/hostname.smd405-new" || fail 'cannot set hostname mode'
mv "${mount_dir}/etc/hostname.smd405-new" "${mount_dir}/etc/hostname" || \
	fail 'cannot install guest hostname'

awk -v hostname="$guest_hostname" '
	$1 == "127.0.1.1" {
		print "127.0.1.1\t" hostname
		seen = 1
		next
	}
	{ print }
	END { if (!seen) print "127.0.1.1\t" hostname }
' "${mount_dir}/etc/hosts" >"${mount_dir}/etc/hosts.smd405-new" || \
	fail 'cannot create guest hosts candidate'
chown --reference="${mount_dir}/etc/hosts" \
	"${mount_dir}/etc/hosts.smd405-new" || fail 'cannot set hosts owner'
chmod --reference="${mount_dir}/etc/hosts" \
	"${mount_dir}/etc/hosts.smd405-new" || fail 'cannot set hosts mode'
mv "${mount_dir}/etc/hosts.smd405-new" "${mount_dir}/etc/hosts" || \
	fail 'cannot install guest hosts file'

old_machine_id=$(cat "${mount_dir}/etc/machine-id" 2>/dev/null || true)
: >"${mount_dir}/etc/machine-id" || fail 'cannot clear clone machine-id'
systemd-machine-id-setup --root="$mount_dir" >/dev/null || \
	fail 'cannot create unique clone machine-id'
new_machine_id=$(cat "${mount_dir}/etc/machine-id" 2>/dev/null || true)
[ -n "$new_machine_id" ] || fail 'new clone machine-id is empty'
[ "$new_machine_id" != "$old_machine_id" ] || \
	fail 'clone machine-id did not change'

systemctl --root="$mount_dir" enable ssh.service >/dev/null || \
	fail 'cannot enable clone ssh.service'
mkdir -p "${mount_dir}/etc/sudoers.d" || fail 'cannot create sudoers.d'
sudoers_file="${mount_dir}/etc/sudoers.d/99-smd405-provision"
printf '%s\n' 'REDACTED_USER ALL=(root) NOPASSWD: ALL' >"$sudoers_file" || \
	fail 'cannot create temporary provisioning sudo rule'
chown root:root "$sudoers_file" || fail 'cannot set sudo rule owner'
chmod 0440 "$sudoers_file" || fail 'cannot set sudo rule mode'
visudo -cf "$sudoers_file" >/dev/null || fail 'temporary sudo rule is invalid'

sync
umount "$mount_dir" || fail 'cannot unmount clone root'
mounted=0
qemu-nbd --disconnect "$nbd_dev" || fail 'cannot disconnect nbd device'
connected=0
udevadm settle || fail 'udev did not settle after disconnect'
if [ "$module_added" -eq 1 ]; then
	rmmod nbd || fail 'cannot unload nbd module'
	module_added=0
fi

qemu-img check "$clone_disk" >/dev/null || fail 'clone overlay check failed'
[ "$(stat -c '%s|%Y' "$source_disk")" = "$source_stat_before" ] || \
	fail 'source disk size or mtime changed'
[ "$(virsh domstate "$source_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'source VM state changed'
[ "$(virsh domstate "$clone_domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'clone VM state changed'
[ "$(virsh dumpxml --inactive "$clone_domain" | xmllint --xpath \
	"string(/domain/devices/interface[mac/@address='$clone_mac']/link/@state)" -)" = down ] || \
	fail 'clone interface link changed'

success=1
trap - EXIT HUP INT TERM
rmdir "$mount_dir" >/dev/null 2>&1 || true
printf '%s%s%s%s\n' \
	'SMD405_PREPARE_CLONE_COMPLETE' \
	" domain=$clone_domain hostname=$guest_hostname" \
	" mac=$clone_mac interface=down state=shut_off" \
	' source_vm_unchanged=PASS temporary_sudo_rule=PRESENT'
