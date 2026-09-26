#!/bin/sh

# SECURITY: Historical evidence only. Execution is permanently disabled.
printf '%s\n' 'SMD405_RETIRED_SECURITY_GUARD: historical evidence only; execution disabled' >&2
exit 64


set -u

if [ "${SMD405_OFFLINE_PREFLIGHT_CONFIRMED:-}" != YES ]; then
	printf '%s\n' \
		'error: set SMD405_OFFLINE_PREFLIGHT_CONFIRMED=YES after approval' >&2
	exit 64
fi

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

domain=ubuntu24
expected_uuid=81cca873-2c1b-4225-83db-1f1deef925cd
disk=/home/virtimages/node03/ubuntu24.04
mount_dir=
fs_list=
nbd_dev=
module_added=0
connected=0
mounted=0
success=0

fail()
{
	printf 'SMD405_OFFLINE_PREFLIGHT_FAILED error=%s\n' "$1" >&2
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
	if [ -n "$fs_list" ]; then
		rm -f -- "$fs_list" >/dev/null 2>&1 || true
	fi
	if [ -n "$mount_dir" ]; then
		rmdir "$mount_dir" >/dev/null 2>&1 || true
	fi
	if [ "$module_added" -eq 1 ]; then
		rmmod nbd >/dev/null 2>&1 || true
	fi
	if [ "$success" -ne 1 ]; then
		printf '%s\n' 'recovery=read_only_mount_unmounted_nbd_disconnected' >&2
	fi
	exit "$rc"
}

mount_read_only()
{
	device=$1
	fstype=$2
	case "$fstype" in
	ext2|ext3|ext4)
		mount -t "$fstype" -o ro,noload "$device" "$mount_dir"
		;;
	xfs)
		mount -t xfs -o ro,norecovery,nouuid "$device" "$mount_dir"
		;;
	btrfs)
		mount -t btrfs -o ro "$device" "$mount_dir"
		;;
	*)
		return 2
		;;
	esac
}

[ "$(id -u)" -eq 0 ] || fail 'run as root'
[ "$(uname -s)" = Linux ] || fail 'run on Ubuntu Linux'
for command in virsh qemu-img qemu-nbd modprobe rmmod udevadm lsblk \
	blkid mount umount; do
	command -v "$command" >/dev/null 2>&1 || fail "missing command=$command"
done
[ -f "$disk" ] || fail 'candidate qcow2 is absent'
[ "$(virsh domstate "$domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'candidate VM is not shut off'
[ "$(virsh domuuid "$domain")" = "$expected_uuid" ] || \
	fail 'candidate VM UUID mismatch'
virsh domblklist "$domain" --details | \
	awk -v disk="$disk" '$1 == "file" && $2 == "disk" && $4 == disk { found = 1 }
		END { exit !found }' || fail 'candidate disk is not attached to expected VM'
qemu-img info "$disk" | grep -Fqx 'file format: qcow2' || \
	fail 'candidate disk is not qcow2'
if fuser "$disk" >/dev/null 2>&1; then
	fail 'candidate disk is already in use'
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

qemu-nbd --read-only --connect="$nbd_dev" "$disk" || \
	fail 'cannot connect qcow2 read-only'
connected=1
base=${nbd_dev##*/}
attempt=0
while [ "$(cat "/sys/class/block/${base}/size" 2>/dev/null || printf 0)" -eq 0 ]; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 10 ] || \
		fail 'nbd device did not expose nonzero size'
	sleep 1
done
udevadm settle || fail 'udev did not settle'
[ "$(virsh domstate "$domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'candidate VM state changed during inspection'

printf '%s\n' '--- block inventory ---'
lsblk -o NAME,PATH,TYPE,FSTYPE,SIZE,RO,MOUNTPOINTS "$nbd_dev"
printf '%s\n' '--- filesystem signatures ---'
blkid "${nbd_dev}"* 2>/dev/null || true

mount_dir=$(mktemp -d /tmp/smd405-offline.XXXXXX) || \
	fail 'cannot create mount directory'
fs_list="${mount_dir}.filesystems"
lsblk -rpn -o PATH,FSTYPE "$nbd_dev" >"$fs_list" || \
	fail 'cannot list candidate filesystems'
root_device=
root_fstype=
while read -r device fstype; do
	case "$device" in "$nbd_dev") continue ;; esac
	case "$fstype" in ext2|ext3|ext4|xfs|btrfs) ;; *) continue ;; esac
	if mount_read_only "$device" "$fstype" 2>/dev/null; then
		mounted=1
		if [ -f "${mount_dir}/etc/os-release" ]; then
			root_device=$device
			root_fstype=$fstype
			umount "$mount_dir" || fail 'cannot unmount discovered Linux root'
			mounted=0
			break
		fi
		umount "$mount_dir" || fail 'cannot unmount non-root filesystem'
		mounted=0
	fi
done <"$fs_list"
rm -f -- "$fs_list"
fs_list=

[ -n "$root_device" ] || fail 'no directly mountable Linux root filesystem'
mount_read_only "$root_device" "$root_fstype" || \
	fail 'cannot remount Linux root read-only'
mounted=1

printf '%s\n' '--- guest identity ---'
printf 'root_device=%s root_fstype=%s\n' "$root_device" "$root_fstype"
sed -n -E '/^(NAME|VERSION|VERSION_ID|VERSION_CODENAME|ID)=/p' \
	"${mount_dir}/etc/os-release"
printf 'hostname='
cat "${mount_dir}/etc/hostname" 2>/dev/null || printf '%s\n' MISSING
printf '%s\n' '--- guest network metadata ---'
if [ -d "${mount_dir}/etc/netplan" ]; then
	find "${mount_dir}/etc/netplan" -maxdepth 1 -type f -print
	find "${mount_dir}/etc/netplan" -maxdepth 1 -type f -exec \
		grep -EH '^[[:space:]]*(version:|renderer:|ethernets:|dhcp4:|dhcp6:|addresses:|gateway4:|gateway6:|nameservers:|search:|routes:|to:|via:|match:|macaddress:|set-name:)' {} \; || true
else
	printf '%s\n' 'netplan=ABSENT'
fi

printf '%s\n' '--- guest Slurm metadata ---'
grep '^slurm:' "${mount_dir}/etc/passwd" 2>/dev/null || \
	printf '%s\n' 'slurm_user=ABSENT'
for path in \
	"${mount_dir}/usr/local/slurm/26.11.0/sbin/slurmctld" \
	"${mount_dir}/usr/local/slurm/26.11.0/etc/slurm.conf" \
	"${mount_dir}/usr/local/slurm/26.11.0/etc/slurm.key" \
	"${mount_dir}/etc/slurm/slurm.conf" \
	"${mount_dir}/etc/slurm/slurm.key"; do
	if [ -e "$path" ]; then
		stat -c '%A %U:%G %a %s %n' "$path"
	else
		printf 'ABSENT %s\n' "${path#${mount_dir}}"
	fi
done

printf '%s\n' '--- guest access readiness ---'
for login_user in REDACTED_USER ubuntu; do
	login_record=$(awk -F: -v user="$login_user" '$1 == user {
		print "uid=" $3 " gid=" $4 " home=" $6 " shell=" $7
	}' "${mount_dir}/etc/passwd")
	if [ -n "$login_record" ]; then
		printf 'login_user=%s %s\n' "$login_user" "$login_record"
	else
		printf 'login_user=%s ABSENT\n' "$login_user"
	fi
done
if [ -x "${mount_dir}/usr/sbin/sshd" ]; then
	printf '%s\n' 'sshd_binary=PRESENT'
else
	printf '%s\n' 'sshd_binary=ABSENT'
fi
if [ -x "${mount_dir}/usr/sbin/qemu-ga" ]; then
	printf '%s\n' 'qemu_guest_agent_binary=PRESENT'
else
	printf '%s\n' 'qemu_guest_agent_binary=ABSENT'
fi
for unit in ssh.service ssh.socket qemu-guest-agent.service \
	serial-getty@ttyS0.service; do
	unit_state=DISABLED_OR_NOT_LINKED
	for wants in multi-user.target.wants getty.target.wants; do
		if [ -e "${mount_dir}/etc/systemd/system/${wants}/${unit}" ] || \
			[ -L "${mount_dir}/etc/systemd/system/${wants}/${unit}" ]; then
			unit_state=ENABLED
			break
		fi
	done
	printf 'unit=%s state=%s\n' "$unit" "$unit_state"
done
if grep -Eq '^sudo:[^:]*:[^:]*:([^,]*,)*REDACTED_USER(,|$)' \
	"${mount_dir}/etc/group"; then
	printf '%s\n' 'tera_sudo_group=PRESENT'
else
	printf '%s\n' 'tera_sudo_group=ABSENT'
fi
if grep -ERqs '(^|[[:space:]])(REDACTED_USER|%sudo)[[:space:]].*NOPASSWD:' \
	"${mount_dir}/etc/sudoers" "${mount_dir}/etc/sudoers.d" 2>/dev/null; then
	printf '%s\n' 'tera_or_sudo_group_nopasswd_rule=PRESENT'
else
	printf '%s\n' 'tera_or_sudo_group_nopasswd_rule=ABSENT'
fi
if [ -e "${mount_dir}/etc/cloud/cloud-init.disabled" ]; then
	printf '%s\n' 'cloud_init=DISABLED'
elif [ -x "${mount_dir}/usr/bin/cloud-init" ]; then
	printf '%s\n' 'cloud_init=PRESENT_NOT_DISABLED'
else
	printf '%s\n' 'cloud_init=ABSENT'
fi
if [ -e "${mount_dir}/var/lib/cloud/instance/boot-finished" ]; then
	printf '%s\n' 'cloud_init_previous_boot=FINISHED'
else
	printf '%s\n' 'cloud_init_previous_boot=NOT_CONFIRMED'
fi
if grep -HsE '^CONFIG_VIRTIO_FS=(y|m)$' "${mount_dir}"/boot/config-* \
	2>/dev/null; then
	printf '%s\n' 'guest_virtiofs_kernel_support=PRESENT'
elif find "${mount_dir}/lib/modules" -type f -name 'virtiofs.ko*' -print \
	2>/dev/null | grep -q .; then
	printf '%s\n' 'guest_virtiofs_kernel_module=PRESENT'
else
	printf '%s\n' 'guest_virtiofs_support=NOT_CONFIRMED'
fi
for login_user in REDACTED_USER ubuntu; do
	home=$(awk -F: -v user="$login_user" '$1 == user { print $6 }' \
		"${mount_dir}/etc/passwd")
	[ -n "$home" ] || continue
	keys="${mount_dir}${home}/.ssh/authorized_keys"
	if [ -f "$keys" ]; then
		stat -c "authorized_keys user=${login_user} mode=%a owner=%U:%G size=%s" \
			"$keys"
		if command -v ssh-keygen >/dev/null 2>&1; then
			ssh-keygen -lf "$keys" 2>/dev/null | \
				sed "s/^/authorized_key_fingerprint user=${login_user} /" || true
		fi
	else
		printf 'authorized_keys user=%s ABSENT\n' "$login_user"
	fi
done

umount "$mount_dir" || fail 'cannot unmount Linux root'
mounted=0
qemu-nbd --disconnect "$nbd_dev" || fail 'cannot disconnect nbd device'
connected=0
udevadm settle || fail 'udev did not settle after disconnect'
[ "$(virsh domstate "$domain" | tr -d '\r')" = 'shut off' ] || \
	fail 'candidate VM is no longer shut off'
if [ "$module_added" -eq 1 ]; then
	rmmod nbd || fail 'cannot unload nbd module'
	module_added=0
fi

success=1
trap - EXIT HUP INT TERM
rmdir "$mount_dir" >/dev/null 2>&1 || true
printf '%s%s%s\n' \
	'SMD405_OFFLINE_PREFLIGHT_COMPLETE' \
	" domain=$domain uuid=$expected_uuid" \
	' disk_mode=read_only vm_state=shut_off nbd_disconnected=PASS'
